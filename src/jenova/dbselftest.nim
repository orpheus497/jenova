## Script function and purpose: Evidence that the database layer is genuinely
## concurrent, not merely described as concurrent.
##
## The claim under test is the one that sank `lib/proxy.lua`: that database work
## serializes behind a single execution context, so one slow query stalls
## everything else. This runs a writer and several readers simultaneously and
## reports what actually happened — distinct connection handles per thread, and
## reader activity whose time window overlaps the writer's.
##
## Overlap is the load-bearing measurement. Completion alone proves nothing: work
## that ran strictly one-after-another also completes.

import std/[monotimes, strformat, strutils]
import ./db

const
  MaxWorkers = 16
  ReaderThreads = 4
  ReaderOps = 400
  WriterOps = 400
  ## The measurement this whole self-test exists for. It was printed and never
  ## checked, so a fully serialized layer — every reader running strictly before
  ## or after the writer, which is 0% overlap — still reported PASS. A serialized
  ## run cannot clear this; a genuinely concurrent one clears it comfortably.
  ##
  ## Action purpose: **the percentage is of the overlap that was *possible*, not
  ## of the reader's own run, and that correction is what makes this assertion
  ## trustworthy (D-12).** Measured against its own span, a reader is penalised
  ## for outliving the writer: on a loaded or single-core host the writer
  ## finishes early, a reader drags on, and a reader that overlapped the writer
  ## for *every microsecond the writer existed* still scored ~30% and failed —
  ## with nothing wrong with the database layer. Observed at 23.3% and 23.6% on
  ## a busy container, passing on re-runs of the same binary.
  ##
  ## Two intervals of length `a` and `b` can overlap by at most `min(a, b)`, so
  ## that is the denominator. Full concurrency now scores 100% whatever the
  ## relative durations, and a serialized run still scores 0.
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

proc nowNs(): int64 = getMonoTime().ticks

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

## Function purpose: compute how much of the readers' wall-clock time ran while
## the writer was also running. Zero overlap would mean the layer serialized.
proc overlapNs(a, b: WorkerResult): int64 =
  let lo = max(a.startNs, b.startNs)
  let hi = min(a.endNs, b.endNs)
  result = max(0'i64, hi - lo)

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
    # A writer or reader that took no measurable time cannot be judged — there
    # is no window to have overlapped. Reported rather than scored, so a
    # degenerate timing does not read as a serialized layer.
    if possible > 0 and pct < worstOverlapPct: worstOverlapPct = pct
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
  if worstOverlapPct < MinOverlapPct:
    echo &"  FAIL: a reader overlapped the writer for only {worstOverlapPct:.1f}% " &
         &"of the time the two could have overlapped, below the " &
         &"{MinOverlapPct:.1f}% floor — the layer serialized"
    result = 1
  if result == 0:
    echo "  PASS: distinct handles per thread, readers overlapped the writer"
