## Script function and purpose: Evidence that the server does not serialize, and
## that saturating one route class does not starve another.
##
## Two distinct properties are measured, because they fail for different reasons:
##
## * **Phase 1/2 — an established stream is not stalled by blocking work.** This
##   is the Lua proxy's symptom: one thread served everyone, so a slow query
##   froze every open stream.
## * **Phase 3 — a saturated class does not take the server down with it.** This
##   is the bug a single shared pool has even when it never blocks: completion
##   streams are long-lived by design, so enough of them occupy every worker and
##   health checks and assets stop being served.
##
## Phase 3 is the one that justifies per-class pools. A server that passes 1 and
## 2 can still fail 3, and would look healthy right up until it went dark.

import std/[net, strformat, strutils, os, monotimes]
import ./server
import ./routes
import ./db

const
  TestPort = 18642
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

var streamResult: ClientResult
var loadResults: array[16, ClientResult]
var loadRunning: bool

proc nowMs(): float = getMonoTime().ticks.float / 1_000_000.0

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
    var last = 0.0
    var gaps: seq[float]
    var sawHead = false
    while true:
      let n = s.recv(addr chunk[0], chunk.len)
      if n <= 0: break
      let t = nowMs()
      buf.add chunk[0 ..< n]
      if not sawHead:
        let i = buf.find("\r\n\r\n")
        if i < 0: continue
        buf = buf[i + 4 .. ^1]
        sawHead = true
        last = t
      while true:
        let i = buf.find("\r\n\r\n")
        if i < 0: break
        let rec = buf[0 ..< i]
        buf = buf[i + 4 .. ^1]
        if rec.startsWith("data:"):
          if r.events > 0: gaps.add(t - last)
          last = t
          r.events.inc
    for g in gaps:
      r.avgGapMs += g
      if g > r.maxGapMs: r.maxGapMs = g
    if gaps.len > 0: r.avgGapMs /= gaps.len.float
  except CatchableError:
    r.failed = true
  streamResult = r

proc loadClient(arg: ClientArg) {.thread.} =
  var r = ClientResult()
  try:
    while loadRunning:
      discard httpGet(&"/api/_selftest/slow-query?rows={SlowRows}")
      r.ops.inc
  except CatchableError:
    r.failed = true
  loadResults[arg.id] = r

proc holdClient(arg: ClientArg) {.thread.} =
  var r = ClientResult()
  try:
    discard httpGet(&"/debug/hold?ms={HoldMs}")
    r.ops.inc
  except CatchableError:
    r.failed = true
  loadResults[arg.id] = r

proc run*(dbPath, staticRoot: string): int =
  echo "jenova-core serve-selftest"
  db.initDb(dbPath)
  discard server.start("127.0.0.1", TestPort, staticRoot, enableDebug = true)
  echo "  ", server.describe()
  sleep(200)

  if not httpGet("/health").contains("\"status\":\"ok\""):
    echo "  FAIL: /health did not respond"
    server.stop(); return 1
  echo "  /health: ok"
  echo ""

  result = 0

  # ---- Phase 1: baseline -------------------------------------------------
  var st: Thread[ClientArg]
  createThread(st, streamClient,
               ClientArg(id: 0, events: StreamEvents, interval: StreamInterval))
  joinThread(st)
  let idle = streamResult
  echo &"  phase 1  stream, idle        events={idle.events:<3} " &
       &"max gap {idle.maxGapMs:6.1f} ms   avg {idle.avgGapMs:5.1f} ms"

  # ---- Phase 2: stream under blocking database load ----------------------
  loadRunning = true
  var lt: array[LoadClients, Thread[ClientArg]]
  createThread(st, streamClient,
               ClientArg(id: 0, events: StreamEvents, interval: StreamInterval))
  sleep(60)
  for i in 0 ..< LoadClients:
    createThread(lt[i], loadClient, ClientArg(id: i))
  joinThread(st)
  loadRunning = false
  for i in 0 ..< LoadClients: joinThread(lt[i])
  let loaded = streamResult
  var totalOps = 0
  for i in 0 ..< LoadClients: totalOps += loadResults[i].ops
  echo &"  phase 2  stream, under load  events={loaded.events:<3} " &
       &"max gap {loaded.maxGapMs:6.1f} ms   avg {loaded.avgGapMs:5.1f} ms"
  echo &"           {LoadClients} clients ran {totalOps} slow queries " &
       &"({SlowRows} rows each) during that stream"

  # ---- Phase 3: class isolation ------------------------------------------
  # Over-subscribe the debug class, then time a health check. Health has its own
  # threads; if classes shared a pool this is where the server would go dark.
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
    elif not health.contains("\"status\":\"ok\"") or not index.contains("<"):
      echo "  FAIL: health or static did not answer while the debug class was saturated"
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
