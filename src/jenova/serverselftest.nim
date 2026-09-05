## Script function and purpose: evidence that the server neither serializes nor
## lets one saturated route class starve another, and that the relay under it
## does not damage what it carries. Those are separate failures: a shared pool
## that never blocks still goes dark once enough long-lived streams occupy every
## worker, so a server can hold a stream's cadence under load and still fail to
## answer a health check. The third phase is what justifies per-class pools, and
## it is the one that fails silently; the fourth is the only thing in the tree
## that executes `upstream.forward`.

import std/[net, nativesockets, posix, strformat, strutils, os, monotimes,
            atomics, tables]
import ./server
import ./routes
import ./db
import ./http
import ./upstream

const
  StreamEvents = 24
  StreamInterval = 40
  LoadClients = 4
  SlowRows = 400_000
  HoldMs = 800
  SaturationClients = 3     # debug class has 1 thread, so this over-subscribes it 3:1

type
  ClientArg = object
    id: int
    events: int
    interval: int

  ClientResult = object
    events: int
    maxGapMs: float
    avgGapMs: float
    ops: int
    failed: bool

## The port phases 1 to 3 talk to. Not a constant, and that is the point: a
## fixed 18642 meant two `nimble suites` runs on one host bound the same socket,
## and the loser reported a server defect it did not have. `freePort` is asked
## once, before anything binds, and every client below reads the answer.
var TestPort = 0

var streamResult: ClientResult
var loadResults: array[16, ClientResult]
# Action purpose: the worker threads poll this flag while the main thread flips
# it. A plain `bool` is a non-atomic cross-thread read that the compiler is free
# to hoist out of the loop, so phase 2's workers could miss the transition to
# false and never terminate. `Atomic[bool]` makes the write visible.
var loadRunning: Atomic[bool]

## Function purpose: a monotonic clock, so a wall-clock adjustment mid-run
## cannot forge a gap between stream events.
proc nowMs(): float = getMonoTime().ticks.float / 1_000_000.0

## Function purpose: a raw socket rather than `std/httpclient`, so a stalled
## server shows up as a measured delay instead of a client-side retry.
proc httpGet(path: string): string =
  let s = newSocket(buffered = false)
  defer: s.close()
  s.connect("127.0.0.1", TestPort.Port)
  s.send(&"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
  var data = ""
  var chunk = newString(4096)
  while true:
    let n = s.recv(addr chunk[0], chunk.len)
    if n <= 0: break
    data.add chunk[0 ..< n]
  data

## Function purpose: measures the spacing of server-sent events, which is the
## quantity that distinguishes a stalled stream from a slow one.
##
## Action purpose: the spacing is taken from the SERVER's own timestamps, not
## from when the client saw the bytes. `/debug/stream` already stamps every
## record with `epochTime()` at the moment it sends it, so the quantity this
## phase is actually about is on the wire and does not have to be inferred.
proc streamClient(arg: ClientArg) {.thread.} =
  var r = ClientResult()
  try:
    let s = newSocket(buffered = false)
    defer: s.close()
    s.connect("127.0.0.1", TestPort.Port)
    s.send(&"GET /debug/stream?n={arg.events}&interval={arg.interval} HTTP/1.1\r\n" &
           "Host: 127.0.0.1\r\nConnection: close\r\n\r\n")
    var buf = ""
    var chunk = newString(4096)
    ## The previous record's SERVER send time, in ms. Negative until the first
    ## record arrives, which is what makes "no predecessor" a state rather than
    ## a special case at index zero.
    var lastSent = -1.0
    var gaps: seq[float]
    var sawHead = false
    while true:
      let n = s.recv(addr chunk[0], chunk.len)
      if n <= 0: break
      buf.add chunk[0 ..< n]
      if not sawHead:
        let i = buf.find("\r\n\r\n")
        if i < 0: continue
        buf = buf[i + 4 .. ^1]
        sawHead = true
      # Action purpose: one `recv` can carry several records, so a timestamp
      # taken per `recv` cannot say when each of them was sent. Sharing the
      # elapsed time evenly across the batch — what this replaces — is not a
      # conservative approximation, it is a smoothing one: a server that sent
      # three records 40 ms apart and then stalled 400 ms reports four gaps of
      # 130 ms instead of one of 400, and a stall is exactly what this phase
      # exists to catch. Averaging hides it in proportion to how well the
      # network coalesced, which is the opposite of what a measurement should do.
      #
      # Every gap is a difference of two SERVER send times, so nothing about
      # this measurement depends on when the client happened to wake up.
      while true:
        let i = buf.find("\r\n\r\n")
        if i < 0: break
        let rec = buf[0 ..< i]
        buf = buf[i + 4 .. ^1]
        if not rec.startsWith("data:"): continue
        # The stamp is seconds as a float; the marker is matched rather than the
        # body parsed, because a JSON parser here would be a dependency of the
        # measurement on the thing being measured.
        var sent = -1.0
        let k = rec.find("\"t\":")
        # Action purpose: counted only once the record is known to carry a
        # stamp, which is what separates a generated event from the terminal
        # `data: {"done":true}` the handler sends after the loop
        # (`server.nim:339`). Counting that one made the total `n + 1`, so the
        # truncation test below — `events < StreamEvents` — passed on a stream
        # that had dropped exactly one event, which is the smallest truncation
        # it exists to catch.
        if k >= 0:
          r.events.inc
          var stop = k + 4
          while stop < rec.len and rec[stop] in {'0' .. '9', '.', '-', '+', 'e', 'E'}:
            inc stop
          sent = try: parseFloat(rec[k + 4 ..< stop]) * 1000.0
                 except ValueError: -1.0
        # Action purpose: a record with no readable stamp is counted and then
        # left out of the spacing, rather than falling back to its arrival time.
        # The two are different clocks — the server stamps with `epochTime`,
        # arrival is `getMonoTime` — so substituting one for the other does not
        # degrade the measurement, it fabricates a gap of whatever the offset
        # between the two clocks happens to be. `/debug/stream` stamps every
        # record it sends, so this is unreachable short of a malformed one.
        if sent < 0: continue
        # The first record has no predecessor to be spaced from.
        if lastSent >= 0: gaps.add sent - lastSent
        lastSent = sent
    for g in gaps:
      r.avgGapMs += g
      if g > r.maxGapMs: r.maxGapMs = g
    if gaps.len > 0: r.avgGapMs /= gaps.len.float
  except CatchableError:
    r.failed = true
  streamResult = r

## Function purpose: the blocking database load phase 2 runs a stream against.
proc loadClient(arg: ClientArg) {.thread.} =
  var r = ClientResult()
  try:
    while loadRunning.load():
      discard httpGet(&"/api/_selftest/slow-query?rows={SlowRows}")
      r.ops.inc
  except CatchableError:
    r.failed = true
  loadResults[arg.id] = r

## Function purpose: occupies a debug worker for a fixed time, so phase 3 can
## over-subscribe that class deliberately rather than by timing luck.
proc holdClient(arg: ClientArg) {.thread.} =
  var r = ClientResult()
  try:
    discard httpGet(&"/debug/hold?ms={HoldMs}")
    r.ops.inc
  except CatchableError:
    r.failed = true
  loadResults[arg.id] = r

## Function purpose: a port nothing on this host holds at the moment it is
## asked for. The kernel picks it rather than this file naming one, because a
## named one is free only until a second copy of the suite names the same.
proc freePort(): int =
  let s = newSocket(buffered = false)
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  s.getLocalAddr()[1].int

# ---------------------------------------------------------------------------
# Phase 4: the relay, against a fake upstream
# ---------------------------------------------------------------------------
# Action purpose: `upstream.forward` carries every generated token, and until
# this existed nothing executed it. `relay-selftest` asserts `spliceHeaders`,
# which is the pure half; the half that can damage a conversation is the loop
# around it — the accumulation that holds bytes back while a status line is
# incomplete, the short-`send` retry, the tail that flushes a reply too short to
# hold a status line, and the tee the response cache is filed from. None of
# those is reachable without two sockets and something on the other end, so
# there is a fake upstream here and the relay is driven end to end.
#
# The head is fed in seven-byte packets because that is the case that finds
# splice defects: a head that always arrives whole never exercises the
# accumulation, and every one of the failures above is a boundary error.

const
  ## Small enough that no response head can arrive in one `recv`.
  RelayPacket = 7
  ## Waited between two head packets. The relay is blocked in `recv` on a
  ## loopback socket with Nagle disabled, so the packet written before the pause
  ## has been delivered by the time the next one is written — which makes the
  ## split across `recv` calls a property of this script rather than of the
  ## scheduler.
  RelayPauseMs = 4
  ## Well past `upstream.RelayChunk` (16 KB), so the steady-state path runs a
  ## dozen times and a partial `send` has room to be mishandled.
  RelayBodyBytes = 200 * 1024
  RelayStatus = "HTTP/1.1 200 OK\r\n"
  RelayHeadRest = "Content-Type: text/event-stream\r\n" &
                  "Cache-Control: no-cache\r\n" &
                  "X-Upstream-Own: kept\r\n\r\n"
  RelayExtra = "X-Jenova-Trimmed: 3\r\nX-Jenova-Rag-Hits: 5\r\n"

type
  FakeUpstreamArg = object
    ## The listener crosses the thread boundary as a descriptor and the strings
    ## as `ptr`, for the reason `server.acceptor` takes a `SocketHandle`: a
    ## `{.thread.}` proc may not touch a global holding garbage-collected
    ## memory, and neither an integer nor a pointer is one.
    listenFd: SocketHandle
    slow: int            ## how many leading bytes go out a packet at a time
    reply: ptr string    ## exactly what this upstream puts on the wire
    request: ptr string  ## what it read back, which is the rebuilt request
    failed: ptr bool

  RelayReaderArg = object
    fd: SocketHandle
    sink: ptr string     ## every byte the relay wrote to the client
    failed: ptr bool

  RelayRun = object
    outcome: upstream.RelayOutcome
    client: string
    captured: string
    request: string
    failed: bool

## Function purpose: the upstream half — accepts one connection, reads the
## request the relay rebuilt, and answers with a scripted reply whose first
## `slow` bytes are dribbled out `RelayPacket` at a time.
proc fakeUpstream(arg: FakeUpstreamArg) {.thread.} =
  try:
    let lis = newSocket(arg.listenFd, Domain.AF_INET, SockType.SOCK_STREAM,
                        Protocol.IPPROTO_TCP, buffered = false)
    var c: Socket
    lis.accept(c)
    # Action purpose: Nagle would coalesce the seven-byte writes below into one
    # segment, and a fragmented head is the whole subject of this phase.
    setSockOptInt(c.getFd, posix.IPPROTO_TCP, posix.TCP_NODELAY, 1)
    var chunk = newString(4096)
    # Action purpose: read to the end of the *body*, not the head. `buildRequest`
    # emits head and body in one string, so stopping at the blank line usually
    # takes the body with it and sometimes does not — and the assertion below
    # is that the body arrived, which cannot rest on usually.
    var want = -1
    while true:
      if want < 0:
        let e = arg.request[].find("\r\n\r\n")
        if e >= 0:
          var clen = 0
          let head = arg.request[][0 ..< e].toLowerAscii
          let k = head.find("content-length:")
          if k >= 0:
            var stop = k + len("content-length:")
            while stop < head.len and head[stop] == ' ': inc stop
            let start = stop
            while stop < head.len and head[stop] in {'0' .. '9'}: inc stop
            clen = try: parseInt(head[start ..< stop]) except ValueError: 0
          want = e + 4 + clen
      if want >= 0 and arg.request[].len >= want: break
      let n = c.recv(addr chunk[0], chunk.len)
      if n <= 0: break
      arg.request[].add chunk[0 ..< n]
    var i = 0
    while i < arg.reply[].len:
      let n = if i < arg.slow: min(RelayPacket, arg.slow - i)
              else: arg.reply[].len - i
      c.send((arg.reply[])[i ..< i + n])
      i += n
      if i < arg.slow: sleep(RelayPauseMs)
    # The relay ends on the upstream closing; without this it waits out its
    # receive timeout instead.
    c.close()
  except CatchableError:
    arg.failed[] = true

## Function purpose: the client half — drains what the relay writes, so a
## 200 KB body cannot fill the socket buffer and deadlock the relay against a
## reader that is not running yet.
proc relayReader(arg: RelayReaderArg) {.thread.} =
  try:
    let s = newSocket(arg.fd, Domain.AF_INET, SockType.SOCK_STREAM,
                      Protocol.IPPROTO_TCP, buffered = false)
    var chunk = newString(16384)
    while true:
      let n = s.recv(addr chunk[0], chunk.len)
      if n <= 0: break
      arg.sink[].add chunk[0 ..< n]
  except CatchableError:
    arg.failed[] = true

## Function purpose: one request through `upstream.forward` against a fake
## upstream that answers `reply`, returning everything the three parties saw.
##
## Action purpose: both listeners bind port 0 and are asked what they got. A
## fixed port here would make two `nimble suites` runs on one host fight over
## it and report the collision as a relay defect.
proc driveRelay(reply, extraHeaders: string, slow: int, body = ""): RelayRun =
  var replyBuf = reply
  var request = ""
  var upFailed = false
  var readerFailed = false
  var sink = ""

  let upLis = newSocket(buffered = false)
  upLis.setSockOpt(OptReuseAddr, true)
  upLis.bindAddr(Port(0), "127.0.0.1")
  upLis.listen()
  let upPort = upLis.getLocalAddr()[1]

  # Action purpose: `forward` writes the response into a socket it is handed, so
  # the "client" has to be one end of a real connection this proc holds the
  # other end of. A loopback pair is the only way to read back exactly the bytes
  # a client would have seen.
  let cLis = newSocket(buffered = false)
  cLis.setSockOpt(OptReuseAddr, true)
  cLis.bindAddr(Port(0), "127.0.0.1")
  cLis.listen()
  let cRead = newSocket(buffered = false)
  cRead.connect("127.0.0.1", cLis.getLocalAddr()[1])
  var cWrite: Socket
  cLis.accept(cWrite)
  cLis.close()

  var ut: Thread[FakeUpstreamArg]
  var rt: Thread[RelayReaderArg]
  createThread(ut, fakeUpstream, FakeUpstreamArg(
    listenFd: upLis.getFd, slow: slow, reply: addr replyBuf,
    request: addr request, failed: addr upFailed))
  createThread(rt, relayReader, RelayReaderArg(
    fd: cRead.getFd, sink: addr sink, failed: addr readerFailed))

  var req = Request(meth: "POST", path: "/v1/chat/completions",
                    query: "stream=true", body: body)
  req.headers["Content-Type"] = "application/json"

  var captured = ""
  result.outcome = upstream.forward(cWrite, req, "127.0.0.1", upPort.int,
                                    addr captured, extraHeaders)
  # The reader ends on this close, so it is the close and not a timeout that
  # decides how long this phase takes.
  cWrite.close()
  joinThread(rt)
  joinThread(ut)
  cRead.close()
  upLis.close()

  result.client = sink
  result.captured = captured
  result.request = request
  result.failed = upFailed or readerFailed

## Function purpose: a body large enough to exercise the steady-state relay,
## shaped like the event stream the real upstream sends so a defect that
## depends on the framing has something to trip over.
proc relayBody(): string =
  result = ""
  var i = 0
  while result.len < RelayBodyBytes:
    result.add &"data: {{\"i\":{i},\"text\":\"token {i} of a long generation\"}}\r\n\r\n"
    inc i

## Function purpose: phase 4's assertions; returns the number that failed so the
## caller can fold it into the run's exit status.
proc relayPhase(): int =
  result = 0
  var bad = 0
  proc check(label: string, cond: bool, detail = "") =
    if cond: echo "           ok   ", label
    else:
      echo "           FAIL ", label,
           (if detail.len > 0: "\n                " & detail else: "")
      inc bad

  let body = relayBody()
  let head = RelayStatus & RelayHeadRest
  echo &"  phase 4  relay: a {head.len}-byte head in {RelayPacket}-byte packets, " &
       &"a {body.len div 1024} KB body"

  block splicedHead:
    let run = driveRelay(head & body, RelayExtra, head.len,
                         """{"messages":[{"role":"user","content":"hi"}]}""")
    check("the fake upstream and the reader both ran", not run.failed)
    check("a complete relay reports roComplete", run.outcome == upstream.roComplete,
          $run.outcome)
    # Written out rather than computed with `spliceHeaders`, so this is an
    # independent statement of what the client must see and not the function
    # under test agreeing with itself.
    let wanted = RelayStatus & RelayExtra & RelayHeadRest & body
    check("the client's bytes are the status line, then the diagnostics, " &
          "then the upstream's own head, then the body — exactly",
          run.client == wanted,
          &"client {run.client.len} bytes, wanted {wanted.len}")
    check("a 200 KB body relays whole and unaltered",
          run.client.len >= body.len and run.client.endsWith(body))
    # Action purpose: **the tee is the upstream's bytes, and deliberately not
    # the client's.** This block used to assert the two were byte-identical,
    # which is what filed one request's diagnostics in the response cache to be
    # replayed to the next: a conversation that trimmed nothing could be served
    # a cached head saying it had dropped forty turns. `extraHeaders` describes
    # the request being served, so it must not be stored; the caller splices its
    # own on a hit. Asserted from both ends — the tee carries none of them, and
    # the tee plus this request's headers is exactly what the client got.
    check("the response-cache tee is the upstream's own bytes, without the " &
          "request's diagnostics",
          run.captured == RelayStatus & RelayHeadRest & body,
          &"tee {run.captured.len} bytes")
    check("...so no diagnostic header is filed in the cache",
          not run.captured.contains("X-Jenova-"), run.captured[0 ..< min(200, run.captured.len)])
    # Action purpose: the length is checked before the slice. A tee shorter
    # than a status line is a failure the two checks above have already
    # reported, and slicing it raises an `IndexDefect` out of the phase — which
    # ends the process, loses the four blocks below and turns a legible red run
    # into a traceback. A harness must be able to report the failure it is
    # looking for.
    check("...and the tee spliced with this request's headers is what the " &
          "client received",
          run.captured.len >= RelayStatus.len and
          RelayStatus & RelayExtra & run.captured[RelayStatus.len .. ^1] ==
            run.client,
          &"tee {run.captured.len} bytes")
    check("the request the upstream read carries the body and closes the " &
          "connection",
          run.request.contains("""{"messages":""") and
          run.request.contains("Connection: close") and
          run.request.contains("/v1/chat/completions?stream=true"),
          run.request)

  block noHeadersIsByteIdentical:
    # The path every request without diagnostics takes, and the one a mistake in
    # the splice is most likely to damage invisibly: with nothing to insert, the
    # client must receive the upstream's bytes exactly.
    #
    # **Not the same as "buffers nothing".** The status-line probe runs for
    # every response now — that is what stops a fragment being forwarded as a
    # reply — so the head is accumulated here as well and `spliceHeaders`
    # hands it back untouched. What is asserted is the output, which is the
    # property that matters; the note that used to claim no byte was buffered
    # described the gating that had to go.
    let reply = head & body
    let run = driveRelay(reply, "", head.len)
    check("with no headers to add the client gets the upstream's bytes " &
          "unchanged", run.client == reply,
          &"client {run.client.len} bytes, upstream {reply.len}")
    check("and the tee matches those bytes too", run.captured == reply)

  block shorterThanAStatusLine:
    # An upstream that dies mid-status-line leaves those bytes in the
    # accumulation, and `forward` discards them rather than forwarding them.
    #
    # **This block used to assert the opposite** — that the bytes reach the
    # client and the run counts as `roComplete` — which is the contract
    # `upstream.nim:204-213` deliberately does not implement. Bytes surviving to
    # the tail mean no status line was ever completed, so forwarding them sends
    # the client a fragment that is not an HTTP response, counts it as relayed,
    # and reports success over it — an answer the response cache is then
    # entitled to store. Less than a status line is no reply, not a short one.
    # The assertion follows the implementation because the implementation is the
    # one with the argument; asserting the discard is what stops it being undone
    # by accident.
    const Stub = "HTTP/1.1 200 O"
    let run = driveRelay(Stub, RelayExtra, Stub.len)
    check("a reply too short to hold a status line is not forwarded",
          not run.client.contains(Stub), run.client)
    check("the client is told the upstream is unavailable instead",
          run.client.contains("502"), run.client)
    check("nothing is teed, so the cache cannot store a fragment",
          run.captured.len == 0, run.captured)
    check("and it counts as an unavailable upstream, not a relay",
          run.outcome == upstream.roUnavailable, $run.outcome)

  block shorterThanAStatusLineWithNoHeadersToAdd:
    # Action purpose: **the same contract, on the path that had no probe at
    # all.** `splicing` was initialised from `extraHeaders.len > 0`, so a relay
    # with nothing to splice skipped the status-line accumulation entirely and
    # sent a fragment straight through, reporting `roComplete` over it. That is
    # the commoner path, not the rarer one: `/embed` passes no headers and a
    # completion with nothing to report passes an empty string. Asserted
    # separately from the block above because the two differ only in the
    # argument that used to decide whether the rule applied.
    const Stub = "HTTP/1.1 200 O"
    let run = driveRelay(Stub, "", Stub.len)
    check("with no headers to add, a reply too short to hold a status line " &
          "is still not forwarded",
          not run.client.contains(Stub), run.client)
    check("...the client is still told the upstream is unavailable",
          run.client.contains("502"), run.client)
    check("...and nothing is teed",
          run.captured.len == 0, run.captured)
    check("...and it still counts as an unavailable upstream",
          run.outcome == upstream.roUnavailable, $run.outcome)

  block theProbeIsBounded:
    # The one direction the splice is allowed to fail in: an upstream that sends
    # no CRLF for longer than `MaxStatusLineProbe` costs the caller its
    # diagnostic header and must cost the stream nothing.
    let reply = repeat("X", upstream.MaxStatusLineProbe + 64) & "\r\nbody\r\n"
    let run = driveRelay(reply, RelayExtra, reply.len)
    check("past the probe bound the stream is relayed undamaged",
          run.client == reply,
          &"client {run.client.len} bytes, upstream {reply.len}")
    check("...having lost only the header it could not place",
          not run.client.contains("X-Jenova-Trimmed"))

  block silentUpstream:
    # An upstream that accepts and then says nothing is the same operational
    # state as one that is not running, and the client has to be told so rather
    # than left holding an empty 200.
    let run = driveRelay("", RelayExtra, 0)
    check("an upstream that answers nothing becomes a 502",
          run.outcome == upstream.roUnavailable and
          run.client.startsWith("HTTP/1.1 502") and
          run.client.contains("upstream unavailable"), run.client)
    check("and nothing is filed in the response cache", run.captured.len == 0)

  if bad == 0:
    echo &"           PASS: the relay spliced, streamed and teed a " &
         &"{body.len div 1024} KB reply whose head arrived {RelayPacket} " &
         &"bytes at a time"
  else:
    echo &"           FAIL: {bad} relay properties do not hold"
  echo ""
  result = bad

## Function purpose: the entry point behind `jenova-core serve-selftest`;
## returns a process exit status so the suite can be run from a script.
proc run*(dbPath, staticRoot: string): int =
  echo "jenova-core serve-selftest"
  # Action purpose: checked here, before a server exists, because phase 3 asks
  # `/` for a body containing markup and `serveStatic` answers that out of
  # `staticRoot/index.html`. Without one the request returns `404 not found: /`
  # in a fraction of a millisecond and phase 3 reports a saturation failure that
  # did not happen — the request answered, and fast. `nimble web` is what builds
  # the directory; no other task does, which is why `suites` runs it first.
  if not fileExists(staticRoot / "index.html"):
    echo "  FAIL: no Web UI at " & staticRoot & " — phase 3 serves `/` from it."
    echo "        Run `nimble web` first, or `nimble suites`, which does."
    return 1
  db.initDb(dbPath)
  # Asked before the server starts and before any client is created, so all
  # four phases and every worker thread below read one answer.
  TestPort = freePort()
  discard server.start("127.0.0.1", TestPort, staticRoot, enableDebug = true)
  echo "  ", server.describe()
  sleep(200)

  if not httpGet("/health").contains("\"status\":\"ok\""):
    echo "  FAIL: /health did not respond"
    server.stop(); return 1
  echo "  /health: ok"
  echo ""

  result = 0

  # ---- The accept path cannot be occupied by clients that send nothing ----
  # Action purpose: an acceptor classifies a connection by peeking at its
  # request line, and that peek used to block in `recv` under the socket's own
  # thirty-second receive timeout. There are two acceptor threads and nothing
  # else accepts connections, so two clients that connected and said nothing —
  # a pair of speculative pre-connects, or a deliberate pair — stopped the
  # server accepting anything at all for half a minute without sending a byte.
  #
  # Four of them against two acceptors, so the count cannot be met by luck, and
  # the assertion is the one a user would make: does the server still answer.
  block silentClientsCannotStopAccepting:
    var idlers: seq[Socket] = @[]
    for i in 0 ..< 4:
      let s = newSocket(buffered = false)
      try:
        s.connect("127.0.0.1", TestPort.Port)
        idlers.add s
      except CatchableError:
        try: s.close() except CatchableError: discard
    sleep(100)
    let t0 = nowMs()
    let answered = httpGet("/health").contains("\"status\":\"ok\"")
    let ms = nowMs() - t0
    for s in idlers:
      try: s.close() except CatchableError: discard
    # Two seconds is not a measurement of the budget — that is 40 ms per
    # connection — it is a bound far below the thirty seconds the defect cost
    # and far above anything a loaded machine adds to a loopback health check.
    if answered and ms < 2000.0:
      echo &"  silent clients: {idlers.len} sent nothing, /health still " &
           &"answered in {ms:.1f} ms"
    else:
      echo &"  FAIL: {idlers.len} clients that sent nothing held the accept " &
           &"path ({ms:.1f} ms, answered={answered})"
      result = 1
  echo ""

  # ---- Phase 1: the stream's cadence with nothing else running -----------
  var st: Thread[ClientArg]
  createThread(st, streamClient,
               ClientArg(id: 0, events: StreamEvents, interval: StreamInterval))
  joinThread(st)
  let idle = streamResult
  echo &"  phase 1  stream, idle        events={idle.events:<3} " &
       &"max gap {idle.maxGapMs:6.1f} ms   avg {idle.avgGapMs:5.1f} ms"

  # ---- Phase 2: the same cadence with blocking database work alongside ---
  loadRunning.store(true)
  var lt: array[LoadClients, Thread[ClientArg]]
  createThread(st, streamClient,
               ClientArg(id: 0, events: StreamEvents, interval: StreamInterval))
  sleep(60)
  for i in 0 ..< LoadClients:
    createThread(lt[i], loadClient, ClientArg(id: i))
  joinThread(st)
  loadRunning.store(false)
  for i in 0 ..< LoadClients: joinThread(lt[i])
  let loaded = streamResult
  var totalOps = 0
  for i in 0 ..< LoadClients: totalOps += loadResults[i].ops
  echo &"  phase 2  stream, under load  events={loaded.events:<3} " &
       &"max gap {loaded.maxGapMs:6.1f} ms   avg {loaded.avgGapMs:5.1f} ms"
  echo &"           {LoadClients} clients ran {totalOps} slow queries " &
       &"({SlowRows} rows each) during that stream"

  # ---- Phase 3: class isolation ------------------------------------------
  # Action purpose: the debug class is over-subscribed and a health check timed
  # against it. Health has its own threads, so a slow answer here means the
  # classes share a pool — the failure that looks healthy until it goes dark.
  echo ""
  let debugThreads = ClassTable[rcDebug].threads
  var ht: array[SaturationClients, Thread[ClientArg]]
  for i in 0 ..< SaturationClients:
    createThread(ht[i], holdClient, ClientArg(id: i))
  sleep(250)

  let t0 = nowMs()
  let health = httpGet("/health")
  let healthMs = nowMs() - t0
  let t1 = nowMs()
  let index = httpGet("/")
  let staticMs = nowMs() - t1

  for i in 0 ..< SaturationClients: joinThread(ht[i])

  echo &"  phase 3  debug class saturated: {SaturationClients} holds of " &
       &"{HoldMs} ms against {debugThreads} debug threads"
  echo &"           /health answered in {healthMs:6.1f} ms"
  echo &"           /        answered in {staticMs:6.1f} ms"
  echo ""

  server.stop()

  # Phase 4 needs no server: it is two loopback sockets and the relay between
  # them, so it runs after this one is down and cannot be blamed for its load.
  let relayBad = relayPhase()

  if idle.failed or loaded.failed:
    echo "  FAIL: a client raised"; result = 1
  elif loaded.events < StreamEvents:
    echo &"  FAIL: stream truncated under load ({loaded.events}/{StreamEvents})"
    result = 1
  else:
    let budget = StreamInterval.float * 2.5
    if loaded.maxGapMs > budget:
      echo &"  FAIL: stream stalled under load — max gap {loaded.maxGapMs:.1f} ms " &
           &"exceeds {budget:.1f} ms"
      result = 1
    # Action purpose: one condition each, because "health or static" named two
    # classes at once and the reader could not tell which had gone quiet.
    elif not health.contains("\"status\":\"ok\""):
      echo "  FAIL: /health did not answer while the debug class was saturated"
      result = 1
    elif not index.contains("<"):
      echo "  FAIL: / did not answer while the debug class was saturated — " &
           "the Web UI was present at start, so this is the static class"
      result = 1
    elif healthMs > HoldMs.float / 2:
      echo &"  FAIL: /health took {healthMs:.1f} ms while another class was " &
           &"saturated — classes are sharing threads"
      result = 1
    else:
      echo &"  PASS: stream held cadence under load " &
           &"(max gap {loaded.maxGapMs:.1f} ms vs {idle.maxGapMs:.1f} ms idle)"
      echo &"  PASS: health and static stayed responsive while another class " &
           &"was saturated ({healthMs:.1f} ms, {staticMs:.1f} ms)"
  # Folded in last rather than short-circuiting the chain above: the pool
  # verdict and the relay verdict are independent, and a reader who has one
  # failure in hand still wants to know about the other.
  if relayBad > 0: result = 1
