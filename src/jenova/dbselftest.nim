## Script function and purpose: evidence that the database layer is concurrent
## rather than merely described as concurrent. A writer and several readers run
## at once and the overlap of their time windows is measured. Overlap is the
## load-bearing part: completion alone proves nothing, because work that ran
## strictly one after another also completes.

import std/[monotimes, strformat, strutils]
import ./db

const
  MaxWorkers = 16
  ReaderThreads = 4
  ReaderOps = 400
  WriterOps = 400
  ## The floor a serialized layer cannot clear and a concurrent one clears
  ## comfortably. Scored against the overlap that was *possible* — two intervals
  ## of length `a` and `b` can overlap by at most `min(a, b)` — rather than
  ## against the reader's own span, which would penalise a reader for merely
  ## outliving the writer on a loaded host.
  MinOverlapPct = 25.0

type
  WorkerArg = object
    id: int
    isWriter: bool
    ops: int

  WorkerResult = object
    connAddr: uint
    done: int
    startNs, endNs: int64
    failed: bool

# Plain value types only: shared across threads by design, and free of
# reference-counted memory so concurrent writes to distinct indices are safe.
var results: array[MaxWorkers, WorkerResult]

## Function purpose: a monotonic clock, so a wall-clock adjustment mid-run
## cannot produce a negative or inflated overlap.
proc nowNs(): int64 = getMonoTime().ticks

## Function purpose: one thread's share of the load. Writer and reader are the
## same proc so the two paths cannot drift in how they time or report.
proc worker(arg: WorkerArg) {.thread.} =
  var r = WorkerResult(startNs: nowNs())
  try:
    r.connAddr = db.connAddr()
    for i in 0 ..< arg.ops:
      if arg.isWriter:
        db.exec("INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) VALUES (?, ?, ?)",
                "selftest-" & $i, "payload-" & $i, $i)
      else:
        discard db.query("SELECT cache_key, response FROM llm_cache LIMIT 50;")
      r.done.inc
  except CatchableError:
    r.failed = true
  r.endNs = nowNs()
  results[arg.id] = r
  db.closeConn()

## Function purpose: zero overlap is the signature of a serialized layer, which
## is the thing this file exists to rule out.
proc overlapNs(a, b: WorkerResult): int64 =
  let lo = max(a.startNs, b.startNs)
  let hi = min(a.endNs, b.endNs)
  result = max(0'i64, hi - lo)

## Function purpose: the entry point behind `jenova-core db-selftest`; returns a
## process exit status so the suite can be run from a script.
proc run*(dbPath: string): int =
  echo "jenova-core db-selftest"
  echo "  database: ", dbPath

  db.initDb(dbPath)
  echo "  sqlite3_threadsafe(): ", db.threadsafeMode(),
       "  (0 would mean no thread support)"
  echo "  journal_mode: ", db.journalMode(), "   (WAL lets readers run during a write)"
  echo "  main-thread connection: 0x", toHex(db.connAddr().int64, 12)
  echo ""

  var threads: array[MaxWorkers, Thread[WorkerArg]]
  let total = ReaderThreads + 1

  let t0 = nowNs()
  createThread(threads[0], worker, WorkerArg(id: 0, isWriter: true, ops: WriterOps))
  for i in 1 ..< total:
    createThread(threads[i], worker, WorkerArg(id: i, isWriter: false, ops: ReaderOps))
  for i in 0 ..< total:
    joinThread(threads[i])
  let elapsedMs = (nowNs() - t0).float / 1_000_000.0

  let w = results[0]
  var distinct_ok = true
  var totalOps = w.done
  var anyFailed = w.failed
  var worstOverlapPct = 100.0
  ## How many readers actually had a window to be scored against. `possible`
  ## can be zero, and `worstOverlapPct` starts at 100 — so with every reader too
  ## short to judge, nothing ever lowered it and the run printed
  ## "readers overlapped the writer" having measured no overlap at all. That is
  ## the one wrong answer this file must not give: it exists to rule out a
  ## serialized layer, and a serialized layer is exactly what a degenerate
  ## timing would be mistaken for.
  var judged = 0

  echo &"  writer   ops={w.done:<5} conn=0x{toHex(w.connAddr.int64, 12)}"
  for i in 1 ..< total:
    let r = results[i]
    totalOps += r.done
    if r.failed: anyFailed = true
    if r.connAddr == w.connAddr: distinct_ok = false
    let ov = overlapNs(r, w).float / 1_000_000.0
    let span = (r.endNs - r.startNs).float / 1_000_000.0
    let writerSpan = (w.endNs - w.startNs).float / 1_000_000.0
    # The most these two intervals could possibly overlap. See `MinOverlapPct`.
    let possible = min(span, writerSpan)
    let pct = if possible > 0: ov / possible * 100.0 else: 0.0
    # Action purpose: a worker that took no measurable time has no window to
    # have overlapped, so it is reported rather than scored — otherwise a
    # degenerate timing reads as a serialized layer.
    if possible > 0:
      inc judged
      if pct < worstOverlapPct: worstOverlapPct = pct
    echo &"  reader {i} ops={r.done:<5} conn=0x{toHex(r.connAddr.int64, 12)}" &
         &"  ran {span:6.1f} ms, overlapped the writer for {ov:5.1f} ms" &
         (if possible > 0: &" ({pct:5.1f}% of the {possible:.1f} ms possible)"
          else: " (too short to judge)")

  echo ""
  echo &"  {totalOps} operations across {total} threads in {elapsedMs:.1f} ms"

  result = 0
  if anyFailed:
    echo "  FAIL: at least one worker raised"
    result = 1
  if not distinct_ok:
    echo "  FAIL: threads shared a connection handle — the layer is not per-thread"
    result = 1
  if judged == 0:
    # Not "pass with a caveat": the overlap is the whole assertion, so a run
    # that scored none of it has proved nothing and must not read as evidence.
    # Reaching this means the timings are degenerate — 400 SQLite operations
    # measuring no elapsed time at all — which is a broken measurement rather
    # than a fast machine, and worth failing on so it is fixed rather than
    # trusted.
    echo &"  FAIL: none of the {total - 1} readers had a window that could be " &
         "judged against the writer's, so no overlap was measured — this run " &
         "is not evidence either way"
    result = 1
  elif worstOverlapPct < MinOverlapPct:
    echo &"  FAIL: a reader overlapped the writer for only {worstOverlapPct:.1f}% " &
         &"of the time the two could have overlapped, below the " &
         &"{MinOverlapPct:.1f}% floor — the layer serialized"
    result = 1
  if result == 0:
    echo &"  PASS: distinct handles per thread, {judged} of {total - 1} readers " &
         "judged and every one overlapped the writer"
