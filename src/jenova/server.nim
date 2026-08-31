## Script function and purpose: The HTTP server for the Nim core, replacing
## `lib/proxy.lua`. This module is where ruling D-R is honoured or lost.
##
## `proxy.lua` multiplexed every client onto one thread with a custom
## `ffi.C.select` loop, so one blocking call — a SQLite query, a filesystem
## walk, an `io.popen` — froze routing and token streaming for everyone. Nim's
## `asyncdispatch` is the same shape of machine, so porting to async would have
## relocated the defect rather than removed it (D-S).
##
## ## Structure
##
## Two stages, and every service surface owns its own threads:
##
## 1. **Acceptor threads** block in `accept(2)` on the listening socket. They
##    peek at the request line *without consuming it* (`MSG_PEEK`), classify the
##    route, and push the descriptor onto that class's queue. They never run a
##    handler, so they cannot be blocked by one.
## 2. **A dedicated pool per route class** — static, health, api, completion,
##    embed, debug — each with its own queue and its own threads
##    (`routes.nim`).
##
## ## Why classes, and not one pool
##
## A single shared pool has a starvation bug that normal operation triggers:
## completion streams are held open for the length of a generation, so N
## concurrent generations occupy all N workers and the server stops answering
## health checks and serving assets. Isolation makes saturation of one class
## survivable by every other. Health has its own threads for exactly this reason
## — a liveness endpoint that stops answering under load is worse than none.
##
## Only integers cross thread boundaries: the acceptor passes a `SocketHandle`,
## and the owning worker performs the full parse on its own thread. Nothing
## reference-counted is shared.

import std/[net, nativesockets, posix, os, strutils, strformat, times, monotimes]
import ./http
import ./db
import ./routes
import ./upstream
import ./api

import ./pipeline
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
# never `string` globals. A shared refcounted string read by every worker is
# itself a data race — the trap that had to be removed from db.nim.
type SharedStr = object
  buf: array[1024, char]
  len: int

proc set(s: var SharedStr, v: string) =
  let n = min(v.len, s.buf.high)
  if n > 0: copyMem(addr s.buf[0], v.cstring, n)
  s.len = n

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
  # When false the completion classes proxy to llama-server as before, so the
  # server still works on a host where the model cannot be loaded in-process.
  running: bool

  queues: array[RouteClass, Channel[SocketHandle]]
  classThreads: array[MaxThreads, Thread[ClassWorkerArg]]
  acceptorThreads: array[MaxAcceptors, Thread[AcceptorArg]]
  acceptorCount: int
  listenFd: SocketHandle

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
      # Every other byte below 0x20 is illegal raw in a JSON string, so a request
      # path carrying one produced a body no client could parse. The named
      # escapes above cover only three of them.
      if c < ' ': result.add "\\u" & toHex(ord(c), 4)
      else: result.add c

## Action purpose: bound how long a connection may keep a worker waiting on a
## client that has stopped sending. `lib/proxy.lua` had a header timeout that
## could never fire (B-19) because the check sat after a successful read, so a
## client that connected and sent nothing held a slot until the 600 s coroutine
## timeout. A socket-level timeout cannot be bypassed that way.
proc setTimeouts(fd: SocketHandle) =
  var tv = Timeval(tv_sec: posix.Time(ClientTimeoutSec), tv_usec: 0)
  discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, SockLen(sizeof(tv)))
  discard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, SockLen(sizeof(tv)))

## Function purpose: read the request line without consuming it, so the worker
## that ultimately owns the connection can parse the request from the beginning.
## Returns an empty string if the line never arrives within the socket timeout.
proc peekPath(fd: SocketHandle): string =
  var buf = newString(PeekBytes)
  for attempt in 0 ..< 8:
    let n = posix.recv(fd, addr buf[0], PeekBytes, MSG_PEEK)
    if n <= 0:
      return ""
    let path = routes.pathFromHead(buf[0 ..< n])
    if path.len > 0:
      return path
    # Request line not complete yet; the client is still sending.
    sleep(5)
  ""

proc slowQuery(rows: int): (int, float) =
  let t0 = getMonoTime()
  let sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < " &
            $rows & ") SELECT count(*), sum(x) FROM c;"
  let res = db.query(sql)
  let ms = (getMonoTime().ticks - t0.ticks).float / 1_000_000.0
  let n = if res.len > 0 and res[0].len > 0: parseInt(res[0][0]) else: 0
  (n, ms)

proc serveStatic(client: Socket, req: Request) =
  # A HEAD gets the identical response headers a GET would produce, body
  # withheld. It was previously served the body as well, which is a protocol
  # violation and makes a HEAD as expensive on the wire as a GET.
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

## Function purpose: serve one request. The bool result is retained because
## `upstream.forward` reports whether it took ownership of the socket.
proc handle(client: Socket, class: RouteClass, workerId: int): bool =
  result = false
  let req = http.parseRequest(client)

  case class
  of rcHealth:
    client.sendResponse(200, "application/json",
      &"""{{"status":"ok","class":"health","worker":{workerId},""" &
      &""""journal_mode":"{jsonEscape(db.journalMode())}"}}""")

  of rcCompletion:
    # Action purpose: **this is where the core stops being a reverse proxy and
    # becomes Jenova** (N-30). The request is rewritten before it reaches
    # `llama-server`: intent detected and stripped, RAG retrieved and injected,
    # web search run for the websearch intent, a persona chosen, tools stripped
    # where they do not apply. `pipeline.prepare` owns all of it.
    #
    # `/infill` and `/completion` carry a raw prompt with no messages to inject
    # into, so `prepare` returns them untouched — the check is inside it rather
    # than duplicated here.
    var outbound = req
    if req.body.len > 0:
      let prepared = pipeline.prepare(req.body)

      # The cache is consulted on the *rewritten* body's key, which is why this
      # sits after prepare and not before it. proxy.lua:1385.
      if prepared.cacheKey.len > 0:
        let hit = pipeline.cacheLookup(prepared.cacheKey)
        if hit.len > 0:
          client.sendResponse(200, "application/json", hit,
                              extraHeaders = "X-Cache: HIT\r\n")
          return false

      # Only the body changes. `upstream.buildRequest` recomputes Content-Length
      # from it and drops the client's, so setting the header here would be a
      # no-op — checked rather than assumed, because a stale length silently
      # truncates the request llama-server reads.
      outbound.body = prepared.body

    discard upstream.forward(client, outbound, llamaHostS.get(), llamaPort)

  of rcEmbed:
    discard upstream.forward(client, req, embedHostS.get(), embedPort)

  of rcApi:
    # Action purpose: the self-test's database load must run in a *different*
    # class from the stream it is testing, or the two queue behind each other and
    # the measurement becomes meaningless. It lives here rather than under
    # /debug because the api class is where real database work belongs, which
    # also makes the test representative: a completion streaming while API calls
    # hit the database is exactly normal operation.
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
      # A storage download returns file bytes, not JSON, and says so itself.
      # `proxy.lua:1150` serves these as application/octet-stream.
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
      # Occupies a worker in this class for a fixed time, to demonstrate that
      # saturating one class does not starve the others.
      sleep(min(req.queryParam("ms", 1000), 60_000))
      client.sendResponse(200, "application/json", """{"held":true}""")
    else:
      client.sendResponse(404, "text/plain", "not found: " & req.path)

  of rcStatic:
    if req.meth != "GET" and req.meth != "HEAD":
      # Static is the fallback class, so a stray method lands here rather than
      # in a handler that understands it.
      client.sendResponse(405, "text/plain", "method not allowed")
      return
    serveStatic(client, req)

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
    except CatchableError:
      # The message goes to the log, not to the client: it carries filesystem
      # paths, SQL and internal state, and the caller that triggered the fault is
      # the last party that should be handed them.
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

## Function purpose: accept and classify only. Handlers never run here, so no
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
      # Client never sent a usable request line within the timeout.
      nativesockets.close(cfd)
      continue
    queues[routes.classify(path)].send(cfd)

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

proc describe*(): string =
  var parts: seq[string]
  for c in RouteClass:
    parts.add &"{ClassTable[c].name}:{ClassTable[c].threads}"
  &"{acceptorCount} acceptors, " & parts.join(" ") &
    &" ({routes.totalThreads()} handler threads)"

proc stop*() =
  running = false
  if listenFd != osInvalidSocket:
    nativesockets.close(listenFd)
    listenFd = osInvalidSocket
  # Sentinel per worker so each blocking recv() returns and the thread exits.
  for c in RouteClass:
    for _ in 0 ..< ClassTable[c].threads:
      queues[c].send(osInvalidSocket)

proc joinAll*() =
  for i in 0 ..< routes.totalThreads():
    joinThread(classThreads[i])
