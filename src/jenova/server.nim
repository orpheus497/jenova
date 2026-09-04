## Script function and purpose: the HTTP server, built on threads rather than an
## event loop. Multiplexing every client onto one thread means a single blocking
## call — a query, a filesystem walk, a subprocess — freezes routing and token
## streaming for everyone, and an async dispatcher is the same shape of machine.
##
## Two stages. Acceptor threads block in `accept(2)`, peek at the request line
## without consuming it, classify the route, and push the descriptor onto that
## class's queue; they never run a handler, so a handler cannot block them. Each
## route class then has its own queue and its own threads, which is what makes
## one saturated class survivable by the rest.
##
## Only integers cross a thread boundary: the acceptor passes a socket handle
## and the owning worker parses on its own thread, so nothing refcounted is
## shared.

import std/[net, nativesockets, posix, os, strutils, strformat, times, monotimes]
import ./http
import ./db
import ./routes
import ./upstream
import ./api

import ./pipeline
# For the one intent value that is not worth a header.
import ./prompts
import ./inspect
import std/json

type
  AcceptorArg = object
    id: int
    listenFd: SocketHandle

  ClassWorkerArg = object
    id: int
    class: RouteClass

const
  MaxThreads = 128
  MaxAcceptors = 4
  PeekBytes = 2048
  ClientTimeoutSec = 30

# Action purpose: values shared with threads are plain buffers and integers,
# never `string` globals — a shared refcounted string read by every worker is
# itself a data race.
type SharedStr = object
  buf: array[1024, char]
  len: int

## Function purpose: truncates rather than overflowing — these hold a host and a
## path, and a value longer than the buffer is a configuration error.
proc set(s: var SharedStr, v: string) =
  let n = min(v.len, s.buf.high)
  if n > 0: copyMem(addr s.buf[0], v.cstring, n)
  s.len = n

## Function purpose: copies out, so each worker holds its own string rather than
## a view onto memory the others read.
proc get(s: SharedStr): string =
  result = newString(s.len)
  if s.len > 0: copyMem(addr result[0], addr s.buf[0], s.len)

var
  staticRootS: SharedStr
  llamaHostS: SharedStr
  embedHostS: SharedStr
  llamaPort: int
  embedPort: int
  debugEndpoints: bool
  # When false the completion classes proxy to the backend, so the server still
  # works on a host where the model cannot be loaded in-process.
  running: bool

  queues: array[RouteClass, Channel[SocketHandle]]
  classThreads: array[MaxThreads, Thread[ClassWorkerArg]]
  acceptorThreads: array[MaxAcceptors, Thread[AcceptorArg]]
  acceptorCount: int
  listenFd: SocketHandle

## Function purpose: these responses are built by concatenation rather than
## through a JSON library, so the escaping has to be here.
proc jsonEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      # Action purpose: every other byte below 0x20 is illegal raw in a JSON
      # string, so a request path carrying one yields a body no client can
      # parse. The named escapes above cover only three of them.
      if c < ' ': result.add "\\u" & toHex(ord(c), 4)
      else: result.add c

## Function purpose: bounds how long a connection may hold a worker waiting on a
## client that has stopped sending. A timeout checked after a successful read
## never fires for a client that connects and sends nothing; a socket-level one
## cannot be bypassed that way.
proc setTimeouts(fd: SocketHandle) =
  var tv = Timeval(tv_sec: posix.Time(ClientTimeoutSec), tv_usec: 0)
  discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, SockLen(sizeof(tv)))
  discard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, SockLen(sizeof(tv)))

## Function purpose: peeks rather than reads, so the worker that ends up owning
## the connection still parses the request from its first byte.
proc peekPath(fd: SocketHandle): string =
  var buf = newString(PeekBytes)
  for attempt in 0 ..< 8:
    let n = posix.recv(fd, addr buf[0], PeekBytes, MSG_PEEK)
    if n <= 0:
      return ""
    let path = routes.pathFromHead(buf[0 ..< n])
    if path.len > 0:
      return path
    # Request line not complete yet: the client is still sending.
    sleep(5)
  ""

## Function purpose: deliberate database load for the concurrency self-test, and
## reachable only when the debug endpoints are enabled.
proc slowQuery(rows: int): (int, float) =
  let t0 = getMonoTime()
  let sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < " &
            $rows & ") SELECT count(*), sum(x) FROM c;"
  let res = db.query(sql)
  let ms = (getMonoTime().ticks - t0.ticks).float / 1_000_000.0
  let n = if res.len > 0 and res[0].len > 0: parseInt(res[0][0]) else: 0
  (n, ms)

## Function purpose: every failure answers a status rather than raising, because
## a missing asset is an ordinary request and not a server fault.
proc serveStatic(client: Socket, req: Request) =
  # A HEAD gets the identical headers a GET would produce with the body
  # withheld, which is both the protocol's requirement and the only way HEAD is
  # cheaper on the wire than GET.
  let headOnly = req.meth == "HEAD"
  let root = staticRootS.get()
  if root.len == 0:
    client.sendResponse(404, "text/plain", "no static root configured",
                        headOnly = headOnly)
    return
  var full: string
  try:
    full = http.resolveStatic(root, req.path)
  except HttpError:
    client.sendResponse(403, "text/plain", "forbidden", headOnly = headOnly)
    return
  if not fileExists(full):
    client.sendResponse(404, "text/plain", "not found: " & req.path,
                        headOnly = headOnly)
    return
  client.sendResponse(200, http.contentTypeFor(full), readFile(full),
                      headOnly = headOnly)

## Function purpose: what the pipeline did to one request, as the header lines
## its response head is spliced with. Below the handler so a self-test reads the
## real bytes rather than a rebuilt copy of them.
##
## Action purpose: `trimmed` is why these are worth reporting at all — it counts
## the oldest turns dropped to fit the context budget, which is silent
## conversation loss no client can otherwise discover. Nothing is emitted when
## there is nothing to say, so an ordinary turn's head is unchanged.
##
## Action purpose: the counts are integers and the intent and block names fixed
## enums, so none can carry the CRLF that would make this response splitting. A
## retrieval path can, and `inspect.encodeHit` escapes it — which is what keeps
## that argument true rather than nearly true.
##
## Action purpose: the rewritten prompt is not here and does not travel. The
## relay files the captured stream verbatim for replay, so a field carrying it
## would be stored in the cache and served to whoever asks the same question
## next.
proc diagnosticHeaders*(prepared: pipeline.Prepared): string =
  if prepared.trimmed > 0:
    result.add "X-Jenova-Trimmed: " & $prepared.trimmed & "\r\n"
    result.add "X-Jenova-Trimmed-Bytes: " & $prepared.trimmedBytes & "\r\n"
  if prepared.ragHits > 0:
    result.add "X-Jenova-Rag-Hits: " & $prepared.ragHits & "\r\n"
  if prepared.webHits > 0:
    result.add "X-Jenova-Web-Hits: " & $prepared.webHits & "\r\n"
  if prepared.intent != prompts.inNone:
    result.add "X-Jenova-Intent: " & $prepared.intent & "\r\n"
  if prepared.editorDoc:
    result.add "X-Jenova-Editor-Doc: 1\r\n"
  if prepared.msgCount > 0:
    result.add "X-Jenova-Msg-Count: " & $prepared.msgCount & "\r\n"
    result.add "X-Jenova-Body-Bytes: " & $prepared.bodyBytes & "\r\n"
  if prepared.sysBytes > 0:
    result.add "X-Jenova-Sys-Bytes: " & $prepared.sysBytes & "\r\n"
  if prepared.injected.len > 0:
    result.add "X-Jenova-Injected: " &
                inspect.encodeInjected(prepared.injected) & "\r\n"

  # Action purpose: one header per hit, so a single unparseable value costs the
  # reader that hit and not the list.
  #
  # **The value is a retrieval-index path and not a filesystem one**, which is
  # what settles the disclosure question rather than the argument that used to
  # stand here. Everything `rag.indexContent` is ever called with comes from
  # `chatPath`, `notePath` or `fileAssetPath` — `chat/<convId>/<role>/<id>`,
  # `note/<id>`, `file/<id>` — so the header carries database ids, which a LAN
  # client can already list through the unauthenticated `/api/db/*` routes, and
  # never a location on disk. The chunk's own text is a different question and
  # stays off.
  for i, h in prepared.hits:
    if i >= inspect.MaxHits: break
    result.add "X-Jenova-Hit: " & inspect.encodeHit(h) & "\r\n"

## Function purpose: the bool result exists because a relay may take ownership
## of the socket, and the caller must not close one it no longer owns.
proc handle(client: Socket, class: RouteClass, workerId: int): bool =
  result = false
  let req = http.parseRequest(client)

  case class
  of rcHealth:
    client.sendResponse(200, "application/json",
      &"""{{"status":"ok","class":"health","worker":{workerId},""" &
      &""""journal_mode":"{jsonEscape(db.journalMode())}"}}""")

  of rcCompletion:
    # Action purpose: the one point at which this stops being a reverse proxy.
    # The request is rewritten before it reaches the backend — intent detected
    # and stripped, retrieval injected, web search run, a persona chosen, tools
    # stripped where they do not apply — and `prepare` owns all of it.
    #
    # The raw-prompt endpoints have no messages to inject into, so `prepare`
    # returns them untouched; that check is inside it rather than duplicated.
    var outbound = req
    var cacheKey = ""
    # What the pipeline did to this request, as response headers. Built below
    # once it has run; empty means the relay is untouched.
    var diagHeaders = ""
    if req.body.len > 0:
      let prepared = pipeline.prepare(req.body)
      cacheKey = prepared.cacheKey
      # Built before the cache is consulted, because a hit needs them too: they
      # describe *this* request, and a cached reply that carried the previous
      # request's would be reporting another conversation's trimming as this
      # one's.
      diagHeaders = diagnosticHeaders(prepared)

      # Keyed on the rewritten body, which is why this sits after `prepare` and
      # not before it — the same question with different retrieval is a
      # different request.
      if cacheKey.len > 0:
        let hit = pipeline.cacheLookup(cacheKey)
        if hit.len > 0:
          # Action purpose: the stored value is the upstream response as it
          # went down the wire, head included, so it is replayed verbatim rather
          # than re-framed. Wrapping it in a fresh JSON head makes a hit
          # unreadable to a streaming client, which renders an empty reply and
          # saves a blank turn. Byte-identical replay keeps chunked and SSE
          # framing intact, so no reader has to know the difference.
          #
          # The cache header is inserted immediately after the status line: one
          # insertion at a known offset, never a parse of the head.
          #
          # Action purpose: **this request's diagnostics go in beside it, and
          # the stored bytes carry none.** The tee files the upstream's own head
          # (`upstream.forward` says why), so a hit is replayed with the
          # trimming and retrieval of the request being served rather than of
          # the one that happened to fill the entry. Spliced at the same known
          # offset and in the same insertion, so a hit and a miss put the same
          # headers in the same place.
          let cut = hit.find("\r\n")
          if cut >= 0:
            client.send(hit[0 ..< cut + 2] & diagHeaders & "X-Cache: HIT\r\n" &
                        hit[cut + 2 .. ^1])
          else:
            client.send(hit)
          return false

      # Only the body changes: the request builder recomputes `Content-Length`
      # from it and drops the client's, so setting the header here is a no-op.
      # Checked rather than assumed, because a stale length silently truncates
      # the request the backend reads.
      outbound.body = prepared.body

    # Action purpose: the relay tees only when there is a key to file it under,
    # so an uncacheable request pays nothing for the cache existing.
    #
    # Action purpose: and the tee is bounded, because it was not. `capture[].add`
    # grew with the whole reply, so a long generation was held in memory in full
    # and then handed to `cacheStore`, which discards anything over
    # `MaxCacheEntryBytes` — the buffer was unbounded to produce a value that was
    # already certain to be thrown away. The cap is one byte past what the cache
    # will take, so every reply that *can* be stored is still captured whole, and
    # one that cannot is short by construction and refused below rather than
    # filed as if it were complete. Only the copy is bounded; the client's stream
    # is untouched.
    var captured = ""
    var capturePtr: ptr string = nil
    if cacheKey.len > 0: capturePtr = addr captured
    let outcome = upstream.forward(client, outbound, llamaHostS.get(), llamaPort,
                                   capturePtr, diagHeaders,
                                   captureMax = pipeline.MaxCacheEntryBytes + 1)
    # Action purpose: only a complete relay is stored, and only if it can be
    # replayed. A truncated one means the client went away mid-stream, and
    # filing a fragment to serve later as a whole answer is confidently wrong;
    # a body with no event lines would come back as a blank turn.
    if cacheKey.len > 0 and outcome == upstream.roComplete and
       pipeline.isReplayableStream(captured):
      pipeline.cacheStore(cacheKey, captured)

  of rcEmbed:
    discard upstream.forward(client, req, embedHostS.get(), embedPort)

  of rcApi:
    # Action purpose: the self-test's database load has to run in a different
    # class from the stream it measures, or the two queue behind each other and
    # the measurement means nothing. Under the api class rather than debug
    # because that is where real database work belongs, which also makes the
    # test representative of normal operation.
    if debugEndpoints and req.path == "/api/_selftest/slow-query":
      let rows = min(req.queryParam("rows", 400_000), 5_000_000)
      let (n, ms) = slowQuery(rows)
      client.sendResponse(200, "application/json",
        &"""{{"rows":{n},"elapsed_ms":{ms:.1f},"worker":{workerId}}}""")
      return
    if req.path.startsWith("/api/db/"):
      let r = api.handleDb(req)
      client.sendResponse(r.status, "application/json", r.body)
      return
    if req.path.startsWith("/api/fs/"):
      let r = api.handleFs(req)
      client.sendResponse(r.status, "application/json", r.body)
      return
    if req.path.startsWith("/api/storage"):
      let r = api.handleStorage(req)
      # A storage download returns file bytes rather than JSON and carries its
      # own content type.
      client.sendResponse(r.status,
        (if r.contentType.len > 0: r.contentType else: "application/json"),
        r.body)
      return
    client.sendResponse(404, "application/json",
      &"""{{"error":"not found","path":"{jsonEscape(req.path)}"}}""")

  of rcDebug:
    if not debugEndpoints:
      client.sendResponse(404, "text/plain", "not found: " & req.path)
      return
    case req.path
    of "/debug/slow-query":
      let rows = min(req.queryParam("rows", 400_000), 5_000_000)
      let (n, ms) = slowQuery(rows)
      client.sendResponse(200, "application/json",
        &"""{{"rows":{n},"elapsed_ms":{ms:.1f},"worker":{workerId}}}""")
    of "/debug/stream":
      let n = min(req.queryParam("n", 20), 10_000)
      let interval = min(req.queryParam("interval", 50), 5_000)
      client.beginSSE()
      for i in 0 ..< n:
        client.sendEvent(&"""{{"seq":{i},"worker":{workerId},"t":{epochTime():.6f}}}""")
        sleep(interval)
      client.sendEvent("""{"done":true}""")
    of "/debug/hold":
      # Occupies a worker in this class for a fixed time, so a test can
      # saturate one class and watch the others keep answering.
      sleep(min(req.queryParam("ms", 1000), 60_000))
      client.sendResponse(200, "application/json", """{"held":true}""")
    else:
      client.sendResponse(404, "text/plain", "not found: " & req.path)

  of rcStatic:
    if req.meth != "GET" and req.meth != "HEAD":
      # Static is the fallback class, so a stray method lands here rather than
      # in a handler that would understand it.
      client.sendResponse(405, "text/plain", "method not allowed")
      return
    serveStatic(client, req)

## Function purpose: one thread's loop over its class's queue. The socket is
## closed here unless the handler took ownership of it.
proc classWorker(arg: ClassWorkerArg) {.thread.} =
  while true:
    let fd = queues[arg.class].recv()
    if fd == osInvalidSocket:
      break
    let client = newSocket(fd, Domain.AF_INET, SockType.SOCK_STREAM,
                           Protocol.IPPROTO_TCP, buffered = false)
    var handedOff = false
    try:
      handedOff = handle(client, arg.class, arg.id)
    except BodyTooLargeError:
      # Action purpose: the one exception whose message is given to the caller,
      # because the caller is the sender of the oversized body and it tells them
      # nothing they did not already know. Without it they get an undiagnosable
      # failure.
      #
      # Shaped as the backend's own error envelope rather than a new one, so the
      # existing error classifier reads it and no second parser is needed.
      let detail = getCurrentExceptionMsg()
      try:
        client.sendResponse(413, "application/json",
          $(%*{"error": {"type": "request_too_large", "message": detail}}))
      except CatchableError:
        discard
    except CatchableError:
      # Action purpose: the message goes to the log and not the client. It
      # carries filesystem paths, SQL and internal state, and the caller that
      # triggered the fault is the last party that should be handed them.
      let msg = getCurrentExceptionMsg()
      try:
        stderr.writeLine "[server] " & $ClassTable[arg.class].name &
                         " worker " & $arg.id & ": " & msg
      except CatchableError:
        discard
      try:
        client.sendResponse(500, "text/plain", "internal server error")
      except CatchableError:
        discard
    if not handedOff:
      try: client.close() except CatchableError: discard
  db.closeConn()

## Function purpose: accept and classify only. A handler never runs here, so no
## handler can stall the accept path — the failure that makes a single-pool
## server stop accepting once its workers are busy.
proc acceptor(arg: AcceptorArg) {.thread.} =
  while running:
    var sa: Sockaddr_storage
    var sl = SockLen(sizeof(sa))
    let cfd = accept(arg.listenFd, cast[ptr SockAddr](addr sa), addr sl)
    if cfd == osInvalidSocket:
      if not running: break
      continue
    setTimeouts(cfd)
    let path = peekPath(cfd)
    if path.len == 0:
      # The client never sent a usable request line within the timeout.
      nativesockets.close(cfd)
      continue
    queues[routes.classify(path)].send(cfd)

## Function purpose: binds, spawns every pool and returns the listening
## descriptor, so a caller holds one handle rather than a thread inventory.
proc start*(host: string, port: int, root: string,
            llamaHost = "127.0.0.1", llamaPortArg = 8081,
            embedHost = "127.0.0.1", embedPortArg = 8082,
            acceptors = 2, enableDebug = false,
            ): SocketHandle =
  staticRootS.set(root)
  llamaHostS.set(llamaHost)
  embedHostS.set(embedHost)
  llamaPort = llamaPortArg
  embedPort = embedPortArg
  debugEndpoints = enableDebug
  acceptorCount = min(acceptors, MaxAcceptors)
  running = true

  listenFd = createNativeSocket(Domain.AF_INET, SockType.SOCK_STREAM,
                                Protocol.IPPROTO_TCP)
  if listenFd == osInvalidSocket:
    raiseOSError(osLastError())
  setSockOptInt(listenFd, SOL_SOCKET, SO_REUSEADDR, 1)
  var ai = getAddrInfo(host, port.Port, Domain.AF_INET)
  if bindAddr(listenFd, ai.ai_addr, ai.ai_addrlen.SockLen) < 0'i32:
    freeAddrInfo(ai)
    raiseOSError(osLastError())
  freeAddrInfo(ai)
  if nativesockets.listen(listenFd, 128) < 0'i32:
    raiseOSError(osLastError())

  var t = 0
  for c in RouteClass:
    queues[c].open()
    for i in 0 ..< ClassTable[c].threads:
      createThread(classThreads[t], classWorker, ClassWorkerArg(id: i, class: c))
      t.inc
  for i in 0 ..< acceptorCount:
    createThread(acceptorThreads[i], acceptor, AcceptorArg(id: i, listenFd: listenFd))
  listenFd

## Function purpose: the thread layout as one line, so a self-test and a start-up
## log report the same thing.
proc describe*(): string =
  var parts: seq[string]
  for c in RouteClass:
    parts.add &"{ClassTable[c].name}:{ClassTable[c].threads}"
  &"{acceptorCount} acceptors, " & parts.join(" ") &
    &" ({routes.totalThreads()} handler threads)"

## Function purpose: signals shutdown and closes the listener, which is what
## breaks the acceptors out of `accept`. The threads are joined separately.
proc stop*() =
  running = false
  if listenFd != osInvalidSocket:
    nativesockets.close(listenFd)
    listenFd = osInvalidSocket

  # Action purpose: **the acceptors are deliberately not joined here, and this
  # was measured rather than assumed.** An acceptor blocked in `accept` or
  # mid-`peekPath` when the listener closes can still reach its
  # `queues[...].send(cfd)` below, so joining them first — before any sentinel
  # is queued — is the ordering that would close the race properly.
  #
  # It does not work on this platform. Closing a listening descriptor while
  # another thread blocks in `accept(2)` on it is unspecified by POSIX, and on
  # FreeBSD it does not wake that thread: `joinThread` here never returned, and
  # `serve-selftest` hung on every one of three runs. `shutdown(2)` is no help
  # either — it answers `ENOTCONN` on a listening socket. Waking them would take
  # a self-connect to the bound address, which needs the address kept for
  # shutdown and fails in its own ways on a LAN bind; that is a larger change
  # than the leak it closes.
  #
  # So the race stays, and its consequence is handled where it can be: a
  # descriptor queued after its class's workers have gone is closed by the drain
  # in `joinAll` rather than left open. See there.

  # One sentinel per worker, so each blocking receive returns and its thread
  # exits rather than being killed mid-request.
  for c in RouteClass:
    for _ in 0 ..< ClassTable[c].threads:
      queues[c].send(osInvalidSocket)

## Function purpose: separate from `stop` so a caller can signal shutdown and do
## other work before blocking on the threads.
proc joinAll*() =
  for i in 0 ..< routes.totalThreads():
    joinThread(classThreads[i])

  # Action purpose: every worker has exited by here, so anything still in a
  # queue is a descriptor no thread will ever take. An acceptor can enqueue one
  # after the sentinels — `stop` says why that race cannot be closed on this
  # platform — and a connection that is neither served nor closed holds its
  # descriptor and leaves the peer waiting on a socket that will never answer.
  # Closing it is not a substitute for serving it, but it is the difference
  # between a client seeing a closed connection and one hanging until it times
  # out.
  #
  # `tryRecv` and not `recv`: the queue is expected to be empty, and a blocking
  # receive on an empty channel here would hang the shutdown this proc exists to
  # complete.
  for c in RouteClass:
    while true:
      let (got, fd) = queues[c].tryRecv()
      if not got: break
      if fd != osInvalidSocket:
        try: nativesockets.close(fd) except CatchableError: discard
