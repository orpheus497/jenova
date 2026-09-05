# Report 03 — Error Handling, Memory, and Wiring

**Status:** open tracker
**Scope:** `src/jenova/**`, and the client↔server wiring on both surfaces.
**Method:** every finding cites the source line that produces it and states the concrete
sequence that reaches the failure. Where a mechanism is *correct*, that is recorded too —
this is an audit, not a defect list, and knowing which invariants hold is what makes it
safe to change the ones that do not.
**Audited at commit:** `c5111ce`

---

## 0. What is already correct

Recorded first so remediation does not break it.

| # | Invariant that holds | Where |
|---|---|---|
| 1 | Route classes have isolated thread pools; a saturated class cannot starve another | `src/jenova/routes.nim:47-56` |
| 2 | Only a `SocketHandle` (an `int`) crosses a thread boundary; each worker parses on its own thread | `src/jenova/server.nim:317-322` |
| 3 | One SQLite connection per thread, in a `threadvar` — no shared handle, no cross-thread use | `src/jenova/db.nim:101` |
| 4 | Prepared-statement cache is **bounded** and flushes before preparing, never after | `src/jenova/db.nim:51-53`, `:191-198` |
| 5 | Response cache is bounded: 256 entries, 1 MiB per entry, oldest-first eviction with a `rowid` tiebreak | `src/jenova/pipeline.nim:439-496` |
| 6 | Request bodies are capped at 32 MiB with an honest refusal, never truncated | `src/jenova/http.nim:36,92,116` |
| 7 | Attachments are refused above the cap, never shortened | `src/jenova/pipeline.nim:873-883` |
| 8 | Upstream relay sets `SO_RCVTIMEO`, so a silent upstream cannot own a worker forever | `src/jenova/upstream.nim:101-106` |
| 9 | Stream cancellation uses an atomic fd plus `shutdown(2)`, never a `Socket` ref across threads; the fd is initialised to `-1`, not `0` | `src/jenova/gui.nim:243-271` |
| 10 | A cancelled read is not reported as an error | `src/jenova/gui.nim:379-383` |
| 11 | `quitting` is set before window destruction and every timeout checks it | `src/jenova/gui.nim:228-232` |
| 12 | `--mm:arc` on the GUI only, with the ORC cycle-collector SIGBUS documented and the leak bounded | `jenova_core.nimble`, `GuiFlags` |
| 13 | Backends are started with `fork`/`dup2`/`exec` to a **file**, not a pipe — the 64 KiB pipe stall is designed out | `src/jenova/lifecycle.nim:221-229` |
| 14 | The watchdog probes **health (the port)**, not liveness (the pid) | `src/jenova/lifecycle.nim:312-327`, `:361-390` |
| 15 | Backend restart has a failure counter (3) and a cooldown (60 s), so a broken config cannot become a fork bomb | `src/jenova/lifecycle.nim:340-348` |
| 16 | The tray shares the GTK main loop via a timeout — it is **not** a thread, so no cross-thread widget access exists | `src/jenova/tray.nim:14-18` |
| 17 | Error classification produces actionable text, including prompt-vs-context token counts pulled out of llama.cpp's own message | `src/jenova/pipeline.nim:591-660` |
| 18 | Retry is offered only where retrying can honestly succeed; a context overflow is explicitly non-retryable | `src/jenova/pipeline.nim:644` |
| 19 | `importData` runs in one transaction with rollback on any row failure | `src/jenova/api.nim:646-661` |
| 20 | Static path resolution rejects sibling-prefix escapes (`public-old` for root `public`) | `src/jenova/http.nim:226-231` |

---

## 1. Error handling

### E-01 — Zombie backend processes are never reaped, and the consequences cascade · severity: **high**

`src/jenova/lifecycle.nim:236` forks a child for each backend. **Nothing in `src/` ever
calls `waitpid`, `wait`, or installs a `SIGCHLD` handler** — verified by
`grep -rn 'waitpid\|SIGCHLD\|SIG_IGN' src/ --include=*.nim`, which returns no matches
(the only `sig` hits are D-Bus `dbus_message_new_signal` in `tray.nim`).

`setsid()` at `src/jenova/lifecycle.nim:242` detaches the controlling terminal; it does
**not** reparent. `llama-server` therefore remains a child of the Jenova process, and when
it exits on its own it becomes a zombie that is never collected.

The consequences follow mechanically from `isAlive`:

```nim
proc isAlive*(pid: int): bool =
  pid > 0 and kill(pid.Pid, 0) == 0     # src/jenova/lifecycle.nim:148-149
```

`kill(pid, 0)` **succeeds for a zombie**. So:

1. `state()` (`:151-153`) reports `running: true` for a dead backend.
2. `stop()` (`:280-301`) SIGTERMs the zombie, spins the **full 2 s grace period** polling
   `isAlive` — which never goes false — then SIGKILLs (a no-op on a zombie) and returns
   `not isAlive(st.pid)`, i.e. **`false`**. `stopAll` therefore returns `false`.
3. `start()` (`:187-190`) sees `existing.running == true` and returns the zombie's pid
   **without starting anything**.
4. `watchOnce` (`:381-390`) discards `stop`'s result, calls `start`, receives a
   positive pid, and reports `"restarted (pid N)"` while resetting `failures = 0`.

**Net effect: once a backend exits on its own, the watchdog reports a successful restart
on every tick, forever, and no backend ever comes back.** The health probe correctly keeps
returning false, but the failure counter is reset by the fake restart before it can reach
`maxFailures` again in a useful way, and the user sees "restarted" in the log while the
port stays dead.

The GUI's poll has a related symptom: `src/jenova/gui.nim:825-830` reports `bsStarting`
whenever `ps.running` is true, so the window sits on *"starting — loading model"*
indefinitely for a backend that is a zombie.

**Fix (small, and it fixes all four consequences at once):**
* Reap explicitly: a non-blocking `waitpid(pid, WNOHANG)` inside `isAlive` before the
  `kill(pid,0)` test, or
* Set `SIGCHLD` to `SIG_IGN` (or `SA_NOCLDWAIT`) once at startup so FreeBSD auto-reaps.
  **Caution:** this changes the semantics of `osproc.waitForExit`, which
  `src/jenova/gui.nim:495` (`runCapture`), `src/jenova/fssync.nim:127` (`gitRun`),
  `src/jenova/hardware.nim` and `src/jenova/websearch.nim` all rely on. The `WNOHANG`
  option is the safer one.

Either way, add a regression assertion to `lifecycle`'s suite: start a backend, kill it,
assert `state().running == false` and that `stop()` returns true.

### E-02 — `fork()` in a multithreaded process, with non-async-signal-safe work before `exec` · severity: medium

`src/jenova/lifecycle.nim:236-265`. Between `fork()` and `execv()` the child calls
`setsid`, `posix.open`, `dup2`, `dirExists`, `getEnv`, `putEnv` (twice) and
`allocCStringArray`. `getEnv`/`putEnv` reach libc `getenv`/`setenv`, which allocate through
the **process-wide libc malloc**; `allocCStringArray` allocates through Nim's allocator.

POSIX permits only async-signal-safe calls between `fork` and `exec` in a threaded process.
`lifecycle.start` is called from the GUI's control worker thread
(`src/jenova/gui.nim:788`, `:797`) while the GTK thread and the stream thread are running.
If any other thread holds the libc malloc lock at the instant of the fork, the child
deadlocks before `execv` — a hang, not a crash, presenting as "the backend never starts".

Not observed, and the window is narrow. It is listed because the cost of closing it is
near zero: hoist `getEnv`, build the `LD_LIBRARY_PATH` string and `allocCStringArray` into
the **parent** before `fork`, and have the child call only `setsid`, `open`, `dup2`,
`close`, `execve` (passing the prepared environment rather than mutating it).

### E-03 — 32 exception handlers discard silently, 17 of them in `gui.nim` · severity: medium

`grep -rn 'except.*: discard' src/ --include=*.nim` → 32 sites:

| File | Count |
|---|---|
| `src/jenova/gui.nim` | 17 |
| `src/jenova/api.nim` | 7 |
| `src/jenova/hardware.nim` | 6 |
| `src/jenova/server.nim`, `src/jenova/pipeline.nim` | 5 each |
| `src/jenova/settings.nim`, `src/jenova/lifecycle.nim` | 4 each |
| others | 1–3 each |

Many are correct and documented (a failed socket close during teardown; a thumbnail that
is not a decodable image, `src/jenova/gui.nim:1914-1916`). Others swallow real faults:

* `src/jenova/pipeline.nim:495-496` — a failed `cacheStore` INSERT or eviction DELETE is
  invisible. A cache that has silently stopped storing is indistinguishable from a cache
  with no hits.
* `src/jenova/api.nim` — several `try: parseInt(...) except: discard` inside
  `cascadeCount` (`src/jenova/api.nim:107`) mean a malformed count silently
  **under-reports** what a delete will take. The header at `src/jenova/api.nim:93-95`
  states the reason this must not happen: *"a confirmation that under-reports what it is
  about to delete is worse than no confirmation at all, because it is trusted."*
* `src/jenova/gui.nim:495-506` (`runCapture`) — a missing `route(8)`/`ifconfig(8)` is
  reported as an empty LAN address, which the title bar then renders as `0.0.0.0`
  (`src/jenova/gui.nim:4529`), telling the user their LAN address is a wildcard.

**Fix:** classify the 32 sites into *"genuinely nothing to do"* (keep, with a one-line
reason) and *"a fault a user could act on"* (route to `app.notice` or a log line). No
handler should be silent without a comment saying why.

### E-04 — WITHDRAWN. The error-body reader is correct · severity: none

The original finding claimed two defects. **Both were wrong, and a fix was written and then
reverted rather than shipped.**

1. *"An empty line inside the body ends the read."* No. Nim's `net.recvLine` is documented at
   `lib/pure/net.nim:1628-1634`: *"if solely `\r\L` is read then the result will be set to it …
   If the socket is disconnected, the result will be set to `""`."* A blank line comes back as a
   two-character string and a disconnect as an empty one, so `if chunk.len == 0: break` detects
   exactly the disconnect it was written to detect.
2. *"Lines are joined with no separator, so a pretty-printed JSON body is concatenated away."*
   The joining is real; the consequence is not. JSON tokens do not span lines — a JSON string
   cannot contain a raw newline — so concatenating lines without a separator yields the same
   parse. The only content affected is a non-JSON body, which reaches `ChatError.detail`, and
   `detail` is displayed nowhere in the window.

Reading the standard library's own documented contract, rather than assuming the common
convention, is what settles this. Recorded rather than deleted: the next reader will have the same
suspicion.


### E-05 — The pipeline's own diagnostics are computed and thrown away · severity: medium (wiring)

`pipeline.Prepared` (`src/jenova/pipeline.nim:44-52`) carries `intent`, `ragHits`,
`webHits`, `hadTools`, `editorDoc` and `trimmed`. `src/jenova/server.nim` reads exactly two
fields — `prepared.cacheKey` (`:193`) and `prepared.body` (`:225`). Everything else is
discarded on every request. Outside the self-tests, **nothing in the product reads any of
them**.

Concretely, this means:
* A user cannot tell whether retrieval returned anything.
* `trimmed > 0` — the pipeline silently dropping the oldest turns of a conversation to fit
  the budget (`src/jenova/pipeline.nim:422`) — is **invisible on both surfaces**. Silent
  history loss with no indication is the most user-hostile failure in this list.
* A web search that returned zero results is indistinguishable from one that was not run.

**Fix:** emit these as response headers on the completion path (the relay already inserts
`X-Cache: HIT` at a known offset, `src/jenova/server.nim:210-215`, so the mechanism exists),
then surface them. This is also parity proposal P-E5 in report 02.

### E-06 — `lanAddress()` spawns three shells on the GTK thread, contradicting the module's own contract · severity: medium

`src/jenova/gui.nim:26` states: *"The GUI spawns no shell at all."*
`src/jenova/gui.nim:513-522` (`lanAddress`) calls `runCapture("sh", ["-c", …])` up to three
times, and it is invoked from the GTK thread at `src/jenova/gui.nim:1124`, `:1191` and
`:5112`. `runCapture` (`:495-506`) is fully synchronous: `startProcess`, `readAll`,
`waitForExit`.

Two problems, one claim and one behaviour:
1. The header comment is false. (Also tracked in report 01 as a stale-claim class.)
2. Toggling LAN mode blocks the UI thread for the duration of `route -n get default` plus
   `ifconfig`. On a host with a slow or wedged routing lookup, the window freezes.

**Fix:** move `lanAddress` to the control worker and deliver the result over `uiChan` (the
pattern `hwWorker` already establishes for `llama-server --list-devices`,
`src/jenova/gui.nim:878-887`); correct the header comment to say what the GUI actually
spawns and why.

---

## 2. Memory

### M-01 — Three unbounded, process-lifetime caches in the GUI, none ever cleared · severity: **high**

| Cache | Declared | Holds | Keyed by | Evicted |
|---|---|---|---|---|
| `thumbCache` | `src/jenova/gui.nim:1883` | decoded `Pixbuf` per (size, attachment) | `$size & ":" & key` | **never** |
| `attachMemo` (`pipeline.ParseMemo`) | `src/jenova/gui.nim:1772` | **both** the parsed `JsonNode` of `messages.extra` **and** the `seq[Attachment]` derived from it | message id | **never** |
| `mdMemo` (`markdown.BlockMemo`) | `src/jenova/gui.nim:1429` | parsed markdown blocks per message/note | message or note id | only `invalidate(id)` for **notes** (`:1450`, `:1497`) |

`ParseMemo` is the expensive one. `nodes: Table[string, JsonNode]` (`src/jenova/pipeline.nim:993`)
retains the whole `extra` array — **including every image's full base64 data URL** — and
`atts: Table[string, seq[Attachment]]` (`:994`) retains a *second* copy of the same
payload in `Attachment.payload`. Each viewed image is therefore held twice in the memo,
plus a third time as a decoded `Pixbuf` in `thumbCache`, plus a fourth on disk in
`p.cacheDir / "attach-<sha256>"` (`src/jenova/gui.nim:1907`).

Nothing releases any of it:
* `loadConversation` (`src/jenova/gui.nim:1393-1396`) replaces `allMessages` and does not
  touch any memo.
* `selectConversation` (`:1410-1416`) does not either.
* `deleteMessage` (`:2027`) does not.

A session that browses ten conversations holding a few megabytes of images each retains
every one of them until the process exits. Under `--mm:arc` there is no cycle collector to
help, and these are not cycles anyway — they are live references from module-level `var`s.

**Fix:**
1. Bound each memo (LRU with a modest cap — the transcript only ever draws one branch).
2. Clear all three on `selectConversation`, and evict the id on `deleteMessage`.
3. `thumbCache` additionally holds GTK objects; dropping the entry is enough, but the size
   cap should be by pixel budget rather than entry count.

The invariant the memos exist to protect — `view` must never do work proportional to a
payload (`src/jenova/pipeline.nim:976-977`) — is preserved by an LRU; `attach-selftest`
(`src/jenova_core.nim:488`) already asserts it and must keep passing.

### M-02 — The attachment disk cache grows without bound and is never swept · severity: medium

`src/jenova/gui.nim:1907-1909` writes `p.cacheDir / "attach-" & sha256(bytes)` for every
distinct image ever previewed. `src/jenova/gui.nim:5066` sets `pasteDir = p.cacheDir`, so
every clipboard paste lands there too. `grep -rn 'cacheDir' src/` shows **no reader that
deletes**, and `nimble clean` removes only `bin/` and `nimcache`.

`~/Jenova/var/cache` therefore accumulates a copy of every image the user ever attached or
pasted, forever, with no way to reclaim it short of `rm -rf`.

**Fix:** a sweep on startup (age- or size-bounded), plus a documented location. This is
also documentation gap G-06 in report 01.

### M-03 — RAG semantic search reads and scores **every chunk in the database on every query** · severity: **high** (scaling)

`src/jenova/rag.nim:476-493`:

```
SELECT path, start_line, vec FROM rag_chunks WHERE vec IS NOT NULL
```

with no `LIMIT`, no filter and no index usable for the work being done. For each row the
loop unpacks the BLOB into a `seq[float]` (`unpackVec`), computes a dot product, and then
performs a **linear scan of `best`** to deduplicate by path — an O(n·m) inner loop where
`m` grows with the number of distinct matching documents.

Contrast the keyword half four lines above (`:462-464`), which is correctly bounded:
`ORDER BY bm25(rag_fts) LIMIT 200`.

This runs on **every chat completion** (`src/jenova/pipeline.nim:389`), inside the
`rcCompletion` worker, before a single token is generated. The chunk table is populated
from every message on both surfaces (report 01, D-06) and by `backfillChats`, so it grows
with the user's entire history. Latency and peak memory both grow linearly with total
conversation volume, permanently.

**Fix, in order of cost:**
1. Bound the candidate set — restrict to chunks whose path appears in the BM25 top-200,
   plus a capped tail. This alone removes the unbounded scan and is a few lines.
2. Replace the `best` linear scan with a `Table[string, …]`.
3. Longer term: quantised vectors or an ANN index, only if (1) proves insufficient.

An assertion belongs with this: `rag-selftest` should index N chunks and assert the query
touches fewer than N rows.

### M-04 — Backend logs are appended forever with no rotation · severity: medium

`src/jenova/lifecycle.nim:243-244` opens the log `O_WRONLY|O_CREAT|O_APPEND` and dups
stdout/stderr onto it; `:269` appends a start banner. `grep -rn 'rotate\|truncate' src/`
finds no rotation anywhere, and `.gitignore` merely excludes `/var/log/**` from the
repository.

`llama-server` prints device enumeration and per-layer offload progress on every start —
the comment at `src/jenova/lifecycle.nim:224-228` says this is *"comfortably more than
64 KB"* per load. With the watchdog restarting on a 60 s cooldown, a persistently failing
backend writes that repeatedly and indefinitely.

Mitigation that already exists and should be kept: `lastBackendError`
(`src/jenova/gui.nim:725-731`) reads only the last 8 KiB, so log growth does not become a
*memory* problem — only a disk one.

**Fix:** size-capped rotation at start (rename to `.1`, keep two), or truncate above a
threshold. Document the location either way.

### M-05 — Bounded by design, recorded so it is not "fixed" by mistake · severity: none

* `--mm:arc` leaks the owlkettle `state → event → state` cycles rather than collecting
  them. This is deliberate and the reasoning is at `jenova_core.nimble` (`GuiFlags`): ORC
  collected a widget state while GTK still held its handler, producing the SIGBUS in five
  cores on 2026-08-31. The leak is *"a small state object per discarded widget in a
  fixed-size tree."* **Do not switch this back to ORC.**
* `uiChan`/`ctlReq`/`streamReq`/`hwReq` are opened unbounded
  (`src/jenova/gui.nim:5078`), but the 40 ms GTK timeout drains `uiChan` completely on each
  tick (`src/jenova/gui.nim:1200-1203`), so depth stays at one tick's tokens.
* One SQLite connection per thread is never closed, but thread counts are fixed
  (14 handler threads, `src/jenova/routes.nim:47-56`), so this is a constant.

---

## 3. Wiring

### W-01 — Three settings are wired to nothing · severity: high

`pasteLongTextToFileLen`, `copyTextAttachmentsAsPlainText`, `pdfAsImage`. Full evidence in
report 02, **P-C1**. Recorded here because it is a wiring class: the store, the widget, the
validation and the persistence all work; only the consumer is missing.

### W-02 — The Web UI calls three endpoints the server does not serve · severity: medium

`/models/load`, `/models/unload`, `/cors-proxy`. Full evidence in report 02, **P-C2**. The
`/cors-proxy` case has a live consequence: remote MCP servers requiring the proxy fail
silently for every Web UI user.

### W-03 — Retrieval indexing is wired on three paths and the coverage is uneven · severity: low

Writers: `src/jenova/api.nim:1123` and `:1161` (message create/update), `:508` and `:520`
(trash restore), `src/jenova/gui.nim:874` (`indexExchange` per completed exchange),
`src/jenova/gui.nim:865` and `src/jenova_core.nim:3622` (`backfillChats` at start).

This is *complete enough* — the API routes catch the Web UI, the GUI worker catches the
window, and both start paths backfill — but the coverage is accidental rather than
designed: the GUI indexes through a control-worker job while the Web UI indexes through the
HTTP route it happens to use. `docs/context-and-retrieval.md` still says none of it exists
(report 01, D-06).

**Fix:** consolidate indexing at the single `api.putEntity`/`patchMessage` layer both
surfaces already share, so a future third client is covered by construction.

### W-04 — Message-level `toolCalls` is written by one surface and read by neither · severity: low

The `messages.toolCalls` column exists (`src/jenova/api.nim:52`, `src/jenova/db.nim:328`).
The Web UI's agentic loop writes it; the GUI neither reads nor writes it
(`grep -n 'toolCalls' src/jenova/gui.nim` → no matches). A conversation that used tools in
the browser therefore renders in the GTK window with the tool turns' content but none of
their structure. Downstream of P-A1/P-A2; recorded so it is not rediscovered as a
rendering bug.

### W-05 — Push/Pull round-trips the server's database through the server's own file storage · severity: medium

Full evidence in report 02, **P-C3**. The wiring is: browser → `/api/db/*` (read all) →
browser → `/api/storage/jenova-snapshot.json` (write all) → and back. Two full copies of
the database cross the HTTP boundary per press, and the reverse direction upserts stale
rows over current ones.

---

## Tracker

| ID | Finding | Class | Severity | State after session 2 |
|---|---|---|---|---|
| E-01 | Zombie backends → fake restarts, stuck "starting", failed `stopAll` | error | **high** | **fixed.** `isAlive` reaps with `waitpid(WNOHANG)` first. A targeted reap rather than `SIGCHLD`/`SIG_IGN`, which would break every `osproc.waitForExit` in the program. New `lifecycle-selftest` forks a child, lets it die and asserts `isAlive` goes false — **verified red before the fix, green after** |
| E-02 | Non-async-signal-safe work between `fork` and `exec` | error | medium | **fixed.** The environment is materialised as an explicit `envp` in the parent and handed to `execve`; the child now calls only `setsid`, `open`, `dup2`, `close`, `execve` |
| E-03 | 32 silent exception handlers | error | medium | **closed.** All 32 read: thirty are correct and now say why where it was not obvious; `gui.setLanState` was the one hiding a fault a user could act on — a failed write left the LAN toggle claiming a state the next start would not have — and now reports it |
| E-04 | Error-body reader | — | none | **withdrawn — the finding was wrong** (see above). A fix was written and reverted |
| E-05 | Pipeline diagnostics discarded; silent history trimming | wiring | medium | **fixed.** Intent, RAG hits, web hits, editor-document and trimmed-turn count travel as response headers; documented in `docs/usage.md`. The splice is built to fail only by omitting the header, never by damaging the stream, and was driven end-to-end against a fake upstream. **Session 9 recorded that the driver was not in the tree (report 07, V-09); it is now.** `serverselftest.nim:16` imports `upstream` and `:191-300` is the fake upstream that drives `upstream.forward`, so the verification is re-runnable and a regression in the splice fails `serve-selftest` |
| E-06 | `lanAddress` spawns 3 shells on the GTK thread; header claim false | error | medium | **fixed, and then fixed better (session 7).** The worker job was moved off the GTK thread first. Session 7 found that the two call sites it existed for were resolving the address on a *flag flip*, which cannot change the answer — `run` binds the socket before the window exists and nothing in the process moves it. With the refetch removed, the `lan_addr` job and `umLanAddr` had no caller and are gone: the address is resolved once, at startup, in the one synchronous call this finding already blessed |
| M-01 | Three unbounded GUI caches, never cleared | memory | **high** | **fixed.** `BlockMemo` and `ParseMemo` gain caps with oldest-first batch eviction and a `clear`; `thumbCache` gains a cap; all three are emptied on a conversation switch and the two keyed ones forgotten on a delete. Asserted by overrunning the caps, not by reading the constants |
| M-02 | Attachment disk cache never swept | memory | medium | **fixed.** `paths.sweepCache` prunes oldest-first at startup and **matches only `attach-*`** — asserted, because `cacheDir` comes from an environment variable and this is exactly how B-07 happened |
| M-03 | RAG vector search full-scans every chunk per query | memory/perf | **high** | **fixed.** A generous newest-first scan ceiling, a hash index replacing the O(rows × documents) dedupe, and scoring straight off the packed blob instead of allocating a seq per row. Asserted that packed and unpacked scoring agree, including at 768 dimensions and on a mismatched width |
| M-04 | Backend logs never rotated | memory/disk | medium | **fixed.** Size-capped rotation at start, one previous generation kept. Rotation is at start and not mid-run because that is the only moment no descriptor is open on the file |
| M-05 | Deliberate bounded leaks — **do not "fix"** | memory | none | recorded, untouched |
| W-01 | Three settings wired to nothing | wiring | high | **2 of 3 fixed.** `copyTextAttachmentsAsPlainText` through `pipeline.copyTextFor`; `pasteLongTextToFileLen` through `composer.classifyInsertion`, which recovers a paste by diffing the buffer because GTK gives the window no paste signal to intercept. `pdfAsImage` needs a rasteriser and `autoMicOnEmpty` a recorder — both genuinely blocked, both saying so |
| W-02 | Three endpoints called but not served | wiring | medium | **won't fix — `jca_web` is frozen** (ruling). Recorded in report 02, P-C2 |
| W-03 | Retrieval indexing coverage is accidental | wiring | low | **closed by W-06**, which put the workspace indexing at `api.upsert` — the layer both surfaces share |
| W-04 | `toolCalls` written by one surface, read by neither | wiring | low | **parked** — downstream of MCP, which is deferred |
| W-05 | Push/Pull database round trip | wiring | medium | **parked** — ruling: out of scope for the GUI, and `jca_web` is frozen |
| W-06 | Notes and file assets were never indexed for retrieval | wiring | **high** | **fixed** (session 3, found by the wiring sweep) |
| W-07 | An indexing failure could turn a successful save into a 500 | error | **high** | **fixed** (session 3, found while testing W-06; predates it) |
| D-12 | `db-selftest`'s overlap floor failed under load | test | low | **fixed.** The metric was wrong, not the threshold: overlap was a fraction of the *reader's* span, so a reader was penalised for outliving the writer. Two intervals overlap by at most the shorter of the two, so that is the denominator now. Eight consecutive runs pass and every reader reads 100.0% — the concurrency was always there |

---

## Session 3 — a wiring sweep, and what it found

The trackers above were built by reading the code against the documentation. This pass asked a
different question — **is every part of this program actually connected to every other part it
claims to be** — by enumerating every exported proc and checking it has a caller, every setting and
checking it has a consumer, and every client call and checking it has a server route. Two of the
findings below came out of that sweep rather than out of the earlier reading.

### W-06 — the retrieval index held chats and nothing else · severity: **high** · **fixed**

`rag.indexContent` and `rag.indexFile` were exported, correct, and **called by no production code
anywhere**. Every writer into the index was the chat path. So a note the user wrote and a document
they uploaded — the two things somebody puts in a workspace *in order to find again* — were not
searchable by keyword or by vector at all.

They did reach the model, through `workspace.contextFor`. But that is **scope, not relevance**:
everything in the conversation's branch of the tree, whole, ranked by nothing. Retrieval is the
part that answers "which of these is about what I just asked", and it could not see them.

Fixed at `api.upsert` — the one layer the Web UI's `/api/db/*` route and the window's in-process
`putEntity` both pass through, so a third client is covered by construction. **That also closes
W-03**, which asked for exactly this consolidation. Forget on delete, re-index on restore, and a
backfill so a workspace that predates the wiring becomes searchable without re-saving every note.

### W-07 — an indexing failure could fail the write it was attached to · severity: **high** · **fixed**

Found while writing W-06's test, and **older than W-06**. `rag.indexContent` opens by deleting the
path's existing rows, and `db.exec` raises — so a `DbError` propagated out of `api.upsert` and
turned a **successful** note save into a 500, *after* the row had been written and mirrored to
disk. The client was told the save failed while it had in fact succeeded, which is the worst shape
a failure can take.

Never specific to the new code: the message path (`rag.indexExchange`) has had the same exposure at
three call sites since it was wired. All thirteen `rag` call sites in `api.nim` now go through one
guard. Retrieval degrading is not worth a user's note, and the backfills repair a skipped index at
the next start.

### E-03 — the 32 silent handlers, triaged · **closed**

Reading all 32 rather than counting them: **thirty are correct** and are the classes the report
predicted — a socket close during teardown, a child process being cleaned up after a probe, an
optional numeric field that has a documented fallback, a thumbnail that is not a decodable image.
Two needed work:

* **`gui.setLanState` was the only one hiding a fault a user could act on, and it made a control
  lie.** It writes the LAN flag to the file the *next* start binds from; nothing in the running
  process re-reads it. A failed write — read-only state directory, full disk — left the window
  showing "LAN enabled", the tray item flipped and the address in the title bar, with the flag on
  disk still off. The user is told the thing they asked for happened, and finds out at the restart
  the notice itself told them to perform. It now returns a bool and nothing moves unless the write
  stuck.
* **`pipeline.cacheStore` and `api.cascadeCount`** are correct to be silent and now say why.
  `cacheStore` runs after the reply has already reached the client, so there is no request left to
  fail; a cache that stopped storing is a diagnosis problem, not a correctness one, since every
  miss is answered by the model exactly as it would be with no cache. `cascadeCount`'s `parseInt`
  guards a branch `COUNT(*)` cannot reach.

### Dead code — six procs removed

Found by the sweep. Each was verified unreferenced across `src/` and `tests/` before removal, and
all seventeen self-tests pass without them.

| Removed | Why it was dead |
|---|---|
| `models.countDevices` | **A duplicate of `lifecycle.deviceCount`**, and its own comment named `lifecycle.nim` as the caller it did not have |
| `fssync.scopeDir` | Written for the GUI's document panel (G-25). **D-BW removed that panel**; the helper outlived it |
| `rag.indexFile` | Superseded by `indexContent`, which every writer now uses |
| `db.columnNames`, `tray.isRegistered`, `dbus.appendVariantInt32` | No caller, no consumer |

The three `importc` declarations in `dbus.nim` with no caller were **kept**: an FFI binding surface
is not dead logic, and removing a declaration buys nothing at runtime.

### W-08 — five profile settings that nothing could read · severity: medium · **fixed**

`hardware-profiles/CPU/generic/jenova.conf` set `JENOVA_FLASH_ATTN`, `JENOVA_MLOCK`,
`JENOVA_MMAP`, `JENOVA_LOG_LEVEL` and `JENOVA_LOG_FILE`. None reached the program.

The gate is `config.Keys`, whose own comment states the contract: *"an unlisted key is a key
nothing consumes."* All five were unlisted. `lifecycle` meanwhile passed `-fa auto`
unconditionally — so a profile declaring flash attention **off** got it **on**, and
`JENOVA_MLOCK=1` locked nothing.

The same file carries a comment describing this exact defect happening before, for a different set
of keys: *"This profile previously set JENOVA_-prefixed variants, which jenova-ca never read, so
llama-server launched with -c '' -np '' -t ''."* These five were the surviving remnant.

Fixed: the three performance keys are added to `config.Keys` and read in `llamaArgs`; the two
logging keys are removed, because `lifecycle.logFileFor` already owns the log path and a second
source of truth for it is worse than none. Profile values were set to what the program already
did, so no machine's behaviour changes until someone opts in.

**Two mistakes of mine on the way to this, both caught only by running it:**

1. The first attempt wired `llamaArgs` to keys `config` never populated — a fix that did nothing.
   Adding them to `Keys` was the missing half.
2. The second attempt then emitted `-fa` with an **empty argument** on the five profiles that do
   not declare the key. `config.get(key, default)` substitutes the default only when the key is
   *absent*, and a `Keys` entry is always present, empty when unset. That would have broken
   `llama-server` startup on five of six profiles. The default belongs at the call site.

Six assertions in `tests/test_lifecycle.sh` pin both directions: the defaults with no profile
override, and each of the three flags responding to one.

### D-11 — WITHDRAWN AS FRAMED. The labels are the defect, not an asset · **corrected**

I had this backwards, and the correction matters more than the finding did.

The original text treated the 600 dangling label references as documentation that had lost its
referent, and offered **"restore the decision record"** as the first of three options. That is
exactly wrong. The repository owner deleted `.devdocs/` — twelve files, 17,635 lines — *because*
the AI working in this codebase had been given strict commenting rules, disobeyed them, and
produced this apparatus. Removing the folder was the containment action. Restoring it would
reinstate the thing that was removed on purpose.

So the finding is not "600 references have no target". It is: **600 cross-references and the
comment style around them are the pollution**, and the owner has already decided what happens to
them.

Corrected options, with the first two now the only sensible ones:

1. **Leave them.** They are inert. Stripping 600 references across every module is a large,
   risk-bearing diff for no functional gain, and the labels still disambiguate one ruling from
   another inside the comments.
2. **Retire them opportunistically** — when a function is touched for another reason, cut its
   comment back to what the code cannot say for itself and drop the label with it. No dedicated
   pass, no churn.
3. ~~Restore the decision record.~~ **Withdrawn.** It undoes a deliberate decision.

### D-13 — this audit reproduced the pattern it was documenting · severity: medium · **acknowledged**

Measured on this branch's own diff to `src/**.nim`:

| | |
|---|---|
| Comment lines added | **939 of 2032 added lines — 46%** |
| New label references introduced (`W-06`, `E-01`, `M-03`, `P-B3` …) | **69** |

Much of it restates what the code says, and the labels point into `.devdocs/03` — a file that
exists only because this audit created it, which is the same coupling that produced the original
problem.

Standing correction for future work in this repository, from the owner:

> Cut commenting back to the bare necessity of its purpose. Do not repeat what the code already
> says. This applies as work is done, not as a separate cleanup pass.

No mass rewrite is scheduled. The rule applies to new and touched code.

---

## Review findings on PR #117 — all six were real

CodeRabbit reviewed the branch and raised six findings. **Every one was valid**, which is worth
recording as plainly as the fixes: the first of them is a defect introduced by this session's own
E-02 fix, in the same function, on the failure path.

| # | Finding | Why it was right |
|---|---|---|
| R-1 | `quit(127)` after a failed `execve` in the forked child | E-02 hoisted every allocation out of the child and then left the one call that undoes the point of it. `quit` runs `addExitProc` handlers and flushes C streams against state inherited mid-mutation from threads that do not exist in the child. Now `posix.exitnow(127)` — which the new `lifecycle-selftest` was already using two files away |
| R-2 | The sidebar fork ignored `app.streaming` | The per-message button is drawn `sensitive = not app.streaming`; the sidebar row is not. Mid-generation it created a fork and `selectConversation` then refused to open it. The guard now sits in `forkFrom`, the one place both callers pass through — two `sensitive` expressions can drift, one early return cannot |
| R-3 | The cache sweep trusted a filename | Correct, and it is the same argument M-02 makes about `cacheDir` coming from an environment variable — applied one level further than the fix went. A name is not ownership. Attachments and pasted images now live in an `attachments/` subdirectory this program creates for itself |
| R-4 | The retrieval path filter ran after the scan ceiling | `passesFilter` sees only rows the query returned, so `LIMIT` took the newest chunks globally and the filter discarded them: a scoped search whose documents were older than the ceiling found nothing while its vectors sat in the table. Pushed into SQL with `substr`, not `LIKE` — `%` and `_` are ordinary characters in a path |
| R-5 | `newChat` did not clear the render memos | The other point at which a rendered conversation is replaced, and it does not go through `selectConversation`. The caps were bounding it; nothing was releasing it |
| R-6 | `usage()` did not list the two new self-tests | Registered in `jenova_core.nimble` but undiscoverable from the binary |

**R-3 also caught a leak the original fix missed.** `gui.onPasted` writes `pasted-<epoch>.png`
into the same directory, which matched no prefix — so clipboard images had been accumulating in
the very directory the sweep was walking. Both prefixes are now swept.

Six assertions were added for R-4 (exact match, subtree match, the `proj` / `projector` boundary,
and a path containing a LIKE wildcard) and two for R-3 (an owned name outside the owned directory
survives; pasted images are in scope).

### A second pass raised two more, both against this session's own work

| # | Finding | Why it was right |
|---|---|---|
| R-7 | `pasteLongTextToFileLen` read as `0` on every fresh install | `initSettings` stores each numeric field as empty, `settings.getInt`'s own fallback is `0`, and `classifyInsertion` reads `0` as "off". So the feature W-01 wired was disabled for every new user, while the Settings screen showed `2500` as the number in force. The `appDefault` was being used for ghost text and for nothing else |
| R-8 | Emptying a note or a file asset left its old text searchable | `indexNote` and `indexFileAsset` return early on an empty body, and the call that clears the previous rows (`forgetFile`, at the top of `indexContent`) is on the other side of that return. A user who wiped a note's contents kept a retrievable copy in `rag_chunks`, `rag_fts` and `rag_documents` indefinitely |

R-7 is fixed with `settings.appInt`, which resolves an unset field to the `appDefault` the field
already declares, so the number lives in one place rather than being restated at the call site.
An explicit `0` still disables the rule, which is the Web UI's own convention. R-8 is fixed by
unfiling before the early return in both procedures.

Nine assertions were added. R-8's were **proven to fail without the fix** by reverting the two
`forgetFile` calls and re-running `rag-selftest`: three failures, including "the emptied text is
no longer retrievable". R-7's call site is in `gui.nim` and cannot be type-checked here, so
`appInt` was verified to resolve by renaming it at that call site and confirming the differential
harness reports `attempting to call undeclared routine` — and reports nothing under the real name.

### A third pass: two real races in `start`, and a privacy claim that was wrong the other way

| # | Finding | Verdict |
|---|---|---|
| R-9 | `start` reported success on a `fork` whose `execve` then failed | **Valid.** `fork` returning a positive pid says a process exists, not that it became `llama-server`. A binary present but not executable, or built for another architecture, fails inside `execve` — after the pid is known — so the parent published a pid file for a process already exiting `127`, wrote a "started" line to the log, and `watchOnce` read the positive return as a successful restart and cleared `failures`. The next call then read that pid file back as a running backend |
| R-10 | No cross-process serialisation in `start` | **Valid.** The desktop app's control worker and a separate `jenova-core serve` watchdog are different processes sharing the same ports and pid files. Both can pass the `state` and `portInUse` checks, both fork, and the later pid-file write names whichever child lost the bind |
| R-11 | `docs/privacy.md` claimed two outbound hosts while also documenting MCP as an outbound path | **Valid, but inverted.** The reviewer assumed line 83 was the wrong one. It is not: MCP is *not implemented* — `settings.OmittedFields` records it as deferred by ruling, and neither binary contains an MCP client. The defect was a privacy document inventing an egress channel that does not exist |

R-9 is fixed with the standard close-on-exec pipe handshake: the write end carries `FD_CLOEXEC`, so
a successful `execve` closes it and the parent's `read` returns 0, while a failure writes `errno`
first. `write` and `_exit` are both async-signal-safe, so the child stays inside what POSIX permits
between `fork` and `exec` — the constraint E-02 exists to honour. On failure the child is reaped, no
pid file is written, and the reason is appended to the backend log.

R-10 is fixed with `lockf` on `<pidfile>.lock`, taken before the checks and held through the pid-file
write. `lockf` rather than an `O_EXCL` lock file because the kernel releases it when the holder
exits, so a process killed mid-start leaves nothing stale behind. The critical section is a fork and
a small write, not the model load: `llama-server` binds its port long after `start` returns, and the
second caller only needs to see the pid file before it decides.

Six assertions were added, driving `start` against a real file with no execute bit — the one shape of
R-9 reproducible without a backend. **Reverting the handshake read fails four of them**, including
that a pid file is left naming a process that never ran and that the second call then reports that
dead pid as running. `F_SETFD`, `FD_CLOEXEC`, `F_LOCK` and `F_ULOCK` are imported from their headers
rather than written as numbers, since `std/posix` binds the calls but not the flags.

### A fourth pass: three valid, one declined

| # | Finding | Verdict |
|---|---|---|
| R-12 | `runCapture` read the child's output before waiting for it | **Valid.** `readAll` blocks until the pipe reaches EOF, which a child that never exits never gives — and `ctlWorker` is serial and also carries backend start and stop, so one wedged `route` call would block backend control, not just the LAN readout |
| R-13 | `backfillWorkspace` held every note and file body in memory | **Valid, and self-inflicted.** `backfillChats`, forty lines below, documents the exact rule this broke: selecting the content alongside the id list holds the whole table at once for a pass that indexes singly anyway. A file asset's content is a whole uploaded document |
| R-14 | The backfill retry assertion depended on no embedder being present | **Valid.** With an embedding server reachable, the first `backfillWorkspace` stores a vector and the retry correctly returns 0, so the assertion tests the opposite case. This is the second time this one assertion has been wrong about its own precondition |
| R-15 | A note keeping its title but losing its body stays indexed | **Declined — the proposed change is a regression.** Nothing stale survives: `indexContent` calls `forgetFile` before writing, so the cleared body's chunks are removed and the re-filed document contains only the title. The title is text the user can still see in the workspace, and unfiling on empty content would make every title-only note unfindable by the one thing it has |

R-12 is fixed by waiting before reading, with a 5 s bound and a kill on expiry. The ordering is only
sound because both callers emit a single short line: `osproc.waitForExit` warns that a child without
`poParentStreams` can fill its output buffer and deadlock, so the bound and the small output are one
argument, not two. `timeout(1)` was considered and rejected — it could not be verified against
FreeBSD's own documentation from this host, and its absence would make the LAN address read empty
rather than fail loudly.

R-13 is fixed by fetching ids and titles first and each body singly, matching `backfillChats`.
R-14 is fixed by writing the NULL rather than assuming it.

Five assertions were added. Two were proven to fail without their fix: filing the backfilled note
with an empty body fails "and files its body, not just its identity", which is what the R-13 refactor
could plausibly have broken. R-15's own assertions state the declined position as a test — the
cleared body is gone from the index, and the note is still findable by its title.

### A fifth pass: the lock I added could hang, and one of my assertions was decorative

| # | Finding | Verdict |
|---|---|---|
| R-16 | `lockStart` used blocking `F_LOCK` | **Valid, and an irony.** The lock was added to close a race and introduced a new way to hang the very worker `runCapture` had just been unblocked in: `start` holds it through `portInUse`, a fork and the handshake read, so a holder stopped or wedged partway through makes another caller's wait indefinite |
| R-17 | "the failed child is reaped, not left a zombie" asserted nothing | **Valid.** `start` returns 0 on that path, the line above already asserts `pid == 0`, and `isAlive` returns false for every pid `<= 0` — so the check was true whatever the code did |

R-16 is fixed with `F_TLOCK` in a bounded retry — 100 attempts, 10 ms apart — falling back to the
unlocked path the function already documented. Losing the race is worth a second of waiting and then
proceeding; it is not worth hanging backend control. The bound is a retry count rather than a clock
so it cannot be moved by one.

R-17 is the defect this branch exists to find, in the branch's own work: an assertion that states a
property it does not test. `start` does not hand back the child's pid, so the observable property is
that the fork left nothing behind — `waitpid(-1, WNOHANG)` answers with a pid only if a zombie is
waiting. Outstanding children are drained before the call so an earlier block's fork cannot answer
for this one.

**Both were proven by running.** Removing the reap makes the new assertion fail — and leaves the old
one passing, which is the finding demonstrated rather than conceded.

---

## The GUI became type-checkable · session 6

**`gui.nim` had never been type-checked in this environment, and the reason was wrong.** The
belief was that checking it required GTK4, libadwaita and FreeBSD. It requires none of them:
`nim check` performs semantic analysis and never invokes a C compiler, so `importc` declarations
carrying `header:` do not need the header present. The two real requirements are owlkettle's
source and **Nim 2** — Nim 1.6, which is what this host had, rejects owlkettle's `=destroy`
signatures, and that single error class was mistaken for "owlkettle needs GTK".

With Nim 2.2.11 and owlkettle 3.0.0 on the path, all 5,486 lines check clean.

**It found a compile error on the first run, in this branch's own work:**

```
gui.nim(3319, 24) Error: type mismatch
Expression: attachmentsOf(app, m)
Expected one of: proc attachmentsOf(m: Message): seq[PendingAttachment]
```

`app.attachmentsOf(m)` resolves under UFCS to `attachmentsOf(app, m)`, and the proc takes one
argument. It came from the W-01 `copyTextAttachmentsAsPlainText` wiring. **The branch would not
have built on FreeBSD.** The differential harness could not see it: every owlkettle symbol was
undefined in both the HEAD run and the working-tree run, so a genuine error inside a `gui:` block
was indistinguishable from the ~940 lines of stub noise around it.

`tests/gui_check.sh` now does this properly, on FreeBSD directly and elsewhere against a scratch
copy with the guards neutralised. The differential harness is retired: it was the best available
before, and it is strictly worse than a type check.

**What this still does not cover, corrected after it cost a build:** `nim check` runs no C
compiler, so a `header:` pragma on an `importc` can conflict with owlkettle's own header-less
prototype for the same function and this check will not notice. `shortcuts.nim` declared
`gtk_callback_action_new` with `header: "gtk/gtk.h"`, which made Nim `#include` it beside
owlkettle's bare `void*` prototypes for `gtk_box_new`, `gtk_box_append` and `gtk_box_remove`;
`bin/jenova` did not build, and this check said PASS. `sourceview.nim` and `vte.nim` carry headers
safely only because neither uses a GTK function owlkettle also binds — a distinction that has to be
checked per module, not assumed from the pattern.

It also sees no owlkettle runtime invariant: the `Button.shortcut` update assert, `Paned` refusing a
child that changes type, `--mm:arc` and the ORC cycle hazard, or a container handing its child the
wrong size — `ShortcutHost` wrapped the window in a `GtkBox` and collapsed it to natural height on
every page until `hexpand`/`vexpand` were set. **The check is a type check. `nimble gui` on FreeBSD
is the build, and running the window is the test.**

---

## Pre-existing defects the review surfaced · session 6

Four findings in code this branch did not write, raised because the comment-standard batches pulled
those files into the diff. All four were valid; one of them was valid for a different reason than
the one given.

| # | Finding | Verdict |
|---|---|---|
| R-18 | `websearch.ddgHtmlSearch` paired titles and snippets by index after filtering them separately | **Valid.** Titles were kept at `len > 0` and snippets at `len > 10`, in two passes. A result whose snippet was too short vanished from `snippets` alone, and every later snippet moved up one title — the first weak result silently mislabelled all the rest |
| R-19 | `models.switchToPath` could empty the active slot, and accepted its own slot as a source | **Valid, twice.** `isRelativeTo(modelsDir)` admits `models/agent/…`, which made `linkTarget` resolve to the entry being activated and the clearing loop remove it — a symlink pointing at its own name. Separately, the header promised that a half-failed switch "leaves the old model in place rather than an empty `models/agent`", and the order of operations did not keep that promise: entries were removed one at a time and the rename into place came last |
| R-20 | `serverselftest` timestamps once per `recv` and reuses it for every record in the buffer | **Valid, but not for the stated reason.** The claim was that coalescing keeps `maxGapMs` below its threshold and hides a stall. It cannot: a maximum is not lowered by adding zeroes. The real effect is the opposite — the whole batch's elapsed time is charged to one record, so three events coalesced at a 50 ms interval produce a 150 ms gap against a 125 ms budget and **fail a server that was never late** |
| R-21 | `convmd` drops an empty system message, so it does not round-trip | **Valid as a documentation defect.** The format writes a system message as an HTML comment, and an empty one would be `<!-- system:  -->` — a line that says nothing and that `fromMarkdown` would restore as a message no reader sees. Dropping it is the right behaviour; the module header claiming an unqualified round trip was the error |

R-18 is fixed by validating the pair rather than the halves: `pairResults` walks both lists at the
same index and discards a whole result when either side fails, so nothing shifts. R-19 moves the
atomic rename **before** the clearing loop, so the slot holds a working model from the first
mutation onward and a later failure is untidiness rather than an unusable installation — reported
in the result message rather than raised, because raising would tell the caller a switch failed
that had already succeeded. R-20 shares the elapsed time across the records a read delivered, which
is as fine as `recv` granularity allows, and says so. R-21 narrows the claim.

Ten assertions added. **Both code fixes were proven to fail without them**: restoring the
independent filters fails "the survivors keep their own snippets", and removing the slot check
fails "a model already in the active slot is refused".

### R-22 · the active model was chosen by collation order · session 8

| # | Finding | Verdict |
|---|---|---|
| R-22 | R-19's cleanup is non-fatal, so a failed clear can leave a stale `.gguf` that `discover` selects over the switched one | **Valid, and wider than stated.** The switch named the link after the model, so the slot held several plausible names and `findModel` broke the tie by sorting. A cleanup failure is one way to get a second candidate; a `.gguf` you drop in yourself is another, and needs no failure at all |

Reproduced before fixing, against a built `jenova-core`: switch to `zeta-instruct.gguf`, drop a
symlink named `alpha-thinking.gguf` beside it, and `models list` answers `alpha-thinking.gguf` — a
model the switch never selected and the user never chose.

Fixed at the root rather than at the symptom. **A switch now always writes
`models/agent/active.gguf`**, so reading the slot is a lookup and no other entry can change the
answer; `agentModel` is the one place that rule lives, and both `discover` and `activeAgentPath`
read through it. The collation scan survives as the fallback for a slot no switch has written — an
install predating the fixed name, or one the operator fills by hand — which is also what makes the
change need no migration: the next switch converts the directory.

`models list` now follows the link, so it names the model rather than answering `active.gguf`.

Three assertions added, and **the fix was proven to fail without them**: reverting `agentModel` to
a bare `findModel` fails "a second entry in the slot does not override the switch", naming the
wrong model in the failure message.
---

## The GUI became buildable and runnable · session 7

The section above was right that a type check is not a build, and it named the gap correctly. The
gap turned out to be reachable on this host after all: **GTK 4.14.5, libadwaita 1.5.0,
GtkSourceView 5.12.0, VTE 0.76 and D-Bus 1.14 are all stock Ubuntu packages**, and with Nim 2.2.11
and owlkettle 3.0.0 both binaries compile, link and run. The window maps under `Xvfb`, all
seventeen `-selftest` subcommands pass against the real `jenova-core`, and `jenova --check`
initialises GTK and builds the whole widget tree.

This is not the FreeBSD build — Phase 1 of report 05 still wants that, and the paragraph at the
end of this section states what a Linux run cannot answer. It is, however, three whole classes
further than a type check, and **each class caught a live defect in this branch on its first run:**

| Class | Defect found | Why the type check could not see it |
|---|---|---|
| C compile + link | `shortcuts.nim` declared `gtk_callback_action_new` with `header: "gtk/gtk.h"`, so Nim `#include`d the real header into a translation unit that also carried owlkettle's header-less `void*` prototypes for `gtk_box_new`, `gtk_box_append` and `gtk_box_remove`. **`bin/jenova` did not build at all** | `nim check` never runs a C compiler |
| Mapped window | `ShortcutHost` wrapped the window in a GtkBox and never set the child's expand flags, so the entire content collapsed to its natural height — canvas gone, composer a fifth of the way down an empty window, **on every page** | a property of the allocation GTK performs at runtime |
| Live input | the accelerators were confirmed by pressing them: Ctrl+B reveals the sidebar, Ctrl+comma opens and closes settings, Ctrl+N adds a conversation, F11 flips the control — and Ctrl+A still selects inside the composer | no static analysis reaches a keystroke |

`tests/gui_build.sh` is that harness. It builds both binaries with the shipped switches, runs
`--check`, then maps the window and **types into the bottom of it**, requiring those pixels to
change.

The assertion is behavioural on purpose. The first version measured the greyscale standard
deviation of the window's bottom band and called a flat band a collapsed window — and **run
against the defect it was written for, it passed**: a collapsed window still leaves its own
rounded border in that band, giving 0.009 rather than 0, separable from the healthy 0.075 only by
a threshold chosen after seeing both numbers. Typing gives a binary answer instead: 0.96 on the
fixed build, exactly 0 on the broken one, with no threshold to tune. Both numbers were produced by
reintroducing the defect and re-running, which is the only way to know a test can fail.

**What a Linux run still does not answer:** FreeBSD's `sysctl` hardware probe, `kqueue`, the
`fork`/`setsid`/`execv` backend path against FreeBSD's process semantics, the D-Bus
`StatusNotifierItem` tray (no watcher runs under Xvfb), the embedded Neovim page, and any
behaviour that differs between GTK 4.14 and the target's 4.20.4. Phase 1 of report 05 stands.

### R-23 · the harness ran against the developer's live data · session 8

`gui_build.sh` set `JENOVA_ROOT` to a scratch tree and said so:

> A scratch root, so the run cannot touch the developer's own database, notes or settings.

`paths.resolve` reads **two** variables and they mean different things. `JENOVA_ROOT` is the
install tree; `JCA_HOME` is the data tree, and it does not derive from `JENOVA_ROOT` — it defaults
to `$HOME/Jenova` (`paths.nim:66`). With only the first set:

```
JENOVA_ROOT=<scratch>
JCA_HOME=/root/Jenova
JENOVA_STATE=/root/Jenova/.system
```

So both the `--check` and the mapped window ran against the real database, notes, workspaces, logs
and cache. `--check` builds the entire widget tree, which opens the database and migrates it.

Proven by running the built binary both ways: without `JCA_HOME` it creates
`/root/Jenova/.system/jenova.db`; with it, that file does not appear and the database lands in the
scratch instead. This is the defect class `test_api_db.sh` records in its own header as having
destroyed a real conversation database, and the fix is the one that suite already uses.

### R-26 · the shortcut probe became marginal when the transcript got heavier · session 8

Not a defect in the window — a defect in the measurement, found because the transcript became a
`ListView` over a `Clamp` and the probe started failing every other run.

`composer_reachable` pressed `<Ctrl>n`, slept two seconds, and photographed once. Against the
lighter widget tree that was ample: the change measured ~0.058 against an ~0.0089 threshold, a
6.5× margin. Against the heavier one the software renderer under Xvfb had not finished the frame
at two seconds, so the shot caught the window mid-redraw: 0.0123 on one run, a clean failure on
the next.

The bar was never the problem and raising the sleep only moves the same guess. It now takes the
largest change **across several frames** and stops as soon as it is clearly past the bar. Waiting
for the window to go still is not an option — the composer's caret blinks, which is the idle noise
the same function measures.

This is a maximum over *time* of a mean over *pixels*, and the distinction from the defect this
file already records matters: that one was a maximum over *pixels*, where a single blinking caret
reaches the top of the range. A caret cannot reach a maximum over time, because it moves the same
handful of pixels in every frame.

Restored to ~0.06 against ~0.0022 idle, a 26× margin, on three consecutive runs; and still fails,
with the right diagnosis, when the `<Ctrl>n` binding is taken out.

**Two wrong diagnoses on the way, both mine.** The failure first read as a dead shortcut
controller, then as a frozen UI — a `gdb` backtrace showed the main thread inside
`gsk_renderer_render` waiting on llvmpipe. Both were artifacts of my own leftover `Xvfb` and
`jenova` processes competing for displays. With a clean process table `<Ctrl>n` created the
conversation and the view updated, on both the GL and cairo renderers. **The database was what
settled it**: the conversation count went 1 → 2, so the shortcut had fired all along and only the
photograph was wrong.

---

### R-25 · the fixed link name made a symlink cycle reachable · session 8

R-22's `active.gguf` closed one hole and opened another, which is exactly why a review pass after a
fix is worth having.

`switchToPath` refused a source under `models/agent` **by name**. A source that reaches the slot
through an indirection is not under it by name:

```
models/agent/active.gguf   -> ../instruct/real.gguf     (a previous switch)
models/instruct/aaa.gguf   -> ../agent/active.gguf      (the user's own link)
```

Switching to `aaa.gguf` passed the name test, and passed the `tmpReal == targetReal` validation too
— both resolve to `real.gguf` while the old link still stands. The rename then replaced the slot
with a link back through `aaa.gguf` to itself. Reproduced against a built binary:

```
switched to instruct model: aaa.gguf
cat models/agent/active.gguf -> Too many levels of symbolic links
```

A reported success, and no loadable model.

Fixed by building the link from the **resolved** source, so a chain is collapsed to one hop at
switch time and a cycle cannot form; plus a second refusal for the case with no chain to collapse —
a source resolving to a real file already inside the slot, where the clearing loop would otherwise
delete the file the new link points at.

**And a third defect found next to it.** `switchModel` rewrote the message `switchToPath` composed:

```nim
result.message = "switched to " & target & " model: " & result.target
```

dropping the `(could not clear: …)` suffix R-19 added — so a *named* switch, which is what the tray
and the model menu both call, reported an unqualified success over entries it had failed to clear.
The wording now has one owner, `withCleanup`, and the failures are carried on `SwitchResult` rather
than only in a string.

Five assertions, all mutation-tested. The first attempt at the cycle assertion **ended the suite
with a libc message rather than naming the check** — `expandFilename` raises on `ELOOP` — so the
resolution is caught and reported as a failure instead.

---

### R-24 · Copy did nothing on X11, and nothing said so · session 8

Found by trying to write the transcript test, not by reading the file.

`copyToClipboard` shelled out to `wl-copy`:

```nim
try:
  let p = startProcess("wl-copy", args = [text], options = {poUsePath})
  discard p.waitForExit()
  p.close()
except CatchableError: discard
```

`wl-copy` is a Wayland tool. On X11 the `startProcess` raises, the bare `except`
swallows it, and **the Copy button on every message and every code block does nothing at all** —
no error, no toast, no log line. Three further faults in five lines: `waitForExit` blocks the GTK
thread on a subprocess; the message is passed as an argv entry, where anything reading the process
table can see it, which is a poor property for a product whose case is that nothing leaves the
machine; and the docstring's justification — "GTK's clipboard is asynchronous" — is false. Only
*reading* is asynchronous, which is exactly why the paste path fifty lines above needs a callback
and this does not.

Fixed with the toolkit's own clipboard, which works on X11 and Wayland alike, spawns nothing and
blocks nothing. `gdk_display_get_clipboard` was already imported in this file for the paste path;
only the setter had to be declared, **with the correct signature**: owlkettle's binding takes a
third `length` argument that GDK does not have (`gdkclipboard.h:113` is two parameters), and while
the spurious argument is harmless on the ABIs this targets, relying on the callee ignoring a
register is not a reason.

Verified by clicking the button under Xvfb: before the fix the clipboard stayed empty; after it,
card 1's button yields message 1's text and card 3's yields message 3's.

---

## How session 2's changes were verified

Neither binary can be built on the audit host: the project targets Nim 2.2.10 on FreeBSD with
GTK4/libadwaita and owlkettle, and the environment has Nim 1.6.14 on Linux with no GTK and no
network to fetch either. So the verification is **partial, and its limits are stated rather than
implied**:

* **30 of 35 modules type-check**, including `jenova_core.nim` (3,657 lines), against a scratch
  copy with the two `when not defined(freebsd)` guards disabled. Not checkable: `gui.nim`,
  `theme.nim`, `canvas.nim`, `sourceview.nim`, `vte.nim` — everything that imports owlkettle.
* **`jenova-core` builds and all seventeen self-tests execute and pass**, including the two added
  this session. This is real execution, not a compile.
* **The `lifecycle-selftest` was proven to fail without its fix** by reverting `isAlive` in the
  scratch tree and re-running.
* **`upstream.forward` was driven end-to-end.** The driver went uncommitted at first, which made
  this line a claim nobody could check (report 07, V-09); it is committed now, at
  `serverselftest.nim:191-300`. It runs against a fake upstream that feeds a response head
  in seven-byte packets, confirming that headers splice correctly, that the no-header path stays
  byte-identical, that a 200 KB body relays whole, that a reply shorter than a status line is not
  dropped, and that the response-cache tee matches the client's bytes exactly in every case.
* **`gui.nim` was differentially checked** against empty owlkettle stubs at HEAD and in the working
  tree. Every owlkettle symbol is missing in both runs, so the ~940 error signatures are identical
  noise; a *new* signature would mean a real error. There were none, and the file parses to end of
  file, which is what catches a syntax mistake.

**What this does not cover:** anything owlkettle-typed in `gui.nim` — a wrong widget property, a
wrong callback signature, an owlkettle API misuse. The GUI edits were kept minimal for that reason
and none of them changes the child count of a container holding a shortcut-carrying button, which
is the documented hazard (`gui.nim`, G-51). **The first FreeBSD build of this branch is the real
test of the GUI changes.**

---

## A sixth review pass: five real, one skipped as not yet reachable · session 10

Six findings against this branch's own work. Each was checked against the tree before anything was
changed, and every fix below is asserted by a suite that was run.

### R-24 · the relay's contract and its self-test asserted opposite things · **critical**

`upstream.forward` clears `pending` at the tail, so an upstream that closes having sent fewer bytes
than a status line yields a 502 and `roUnavailable`. `shorterThanAStatusLine` in
`serverselftest.nim` asserted the opposite — that those bytes reach the client and the run reports
`roComplete`. **Phase 4 of `serve-selftest` failed on every run**, and the failure was in this
branch, which had added both halves.

The implementation is the half with the argument, and it is written down at `upstream.nim:204-213`:
bytes surviving to the tail mean no status line was ever completed, so forwarding them sends the
client a fragment that is not an HTTP response, counts it as relayed, and reports success over it —
an answer the response cache is entitled to store. The assertion now follows the implementation and
states the discard positively, so undoing it fails a test rather than passing one.

### R-25 · valid uploads were refused, and the row deleted behind them · **high**

`assetPayload` measured `clean.len mod 4 != 0` against a string that still carried its `=` padding,
so any `data:` URI whose base64 omitted the optional padding — remainder 2 or 3 — was refused.
`base64.decode` handles both correctly; verified by running it. The cost is not cosmetic:
`syncFileAsset` returns false, and `api.upsert` then deletes the row it has already written, so the
upload is lost and the client is told the save failed. Padding is stripped before the length is
measured now, and only a remainder of 1 — the one length base64 cannot produce — is refused.

### R-26 · a rename could trash the old file and write nothing in its place · **medium**

The other half of report 07's V-10. `syncFileAsset` answers `true` for a row with no bytes having
written nothing, which is correct on its own — but `api.mirrorUpsert` paired that success with the
rename cleanup and trashed the previous file. `loadFileAsset` stops the rename that caused it in
the window; nothing stopped it at `putEntity`, which is the layer the frozen Web UI reaches too.
New `fssync.contentWritesAFile` separates "succeeded" from "wrote a file", and the cleanup is
gated on the second.

### R-27 · `chatBody` wrote into its caller's `JsonNode` · **medium**

`JsonNode` is a ref, so `appendToSystem` reached back into whatever the caller passed: building two
bodies from one turn put the workspace context and the thinking directive in twice. The assertions
in `jenova_core.nim` already worked around it by constructing a fresh literal per call rather than
reusing one, which is the shape of a defect rather than of a decision. Copied now, and only when
there is something to inject, so the common path allocates nothing extra.

### R-28 · two smaller ones, both contradicting a comment beside them

* **`thumbCache` cached nil.** The comment said *"Only cache a successful load: caching nil would
  make one unreadable image permanently unreadable"* and the store below it was unconditional.
  `loadPixbuf` answers nil without raising, so one undecodable file poisoned its key for the life
  of the process — including after the cause was fixed. The store is now inside the test its own
  comment describes.
* **`assetview.classify` trusted a filename it said it would not.** The header claimed the byte
  scan outranks every declaration; the branch order let `mimeFromName` route a text file called
  `notes.png` to the image loader. Corrected on both sides — a `data:` URI's own type still wins,
  because it was written around those exact bytes and because an SVG's bytes are textual, and the
  comment now says so instead of overstating the rule.

### Skipped: the `mathfont` → `mathtex` metrics bridge · **not yet reachable**

Reported as major: the two modules declare `MathConstants` types of different shapes (24 fields
against 45) and `readConstants` omits metrics `mathtex` consumes. **Verified, and it cannot fail
today** — nothing imports `mathfont`, `readConstants` has no caller in the tree, and the only
caller of `renderMath` is `math-selftest`, which builds its `MathFont` by hand. It is a
prerequisite of M-3's Cairo draw rather than a defect in shipped code, so it is recorded in
`.devdocs/08-math-rendering.md` beside the phase that has to close it.

### A seventh pass, on the sixth's own fixes · session 10

Two more against the asset path this session had just changed, both real, both fixed:

* **R-29 · a move committed without the file moving.** R-26 gated the rename cleanup on a file
  having been written, which stopped the old copy going to the trash — but `writeRow` has already
  stored the new name and folder by then, so an update that moved an asset while carrying no
  payload left the row naming a path with no file and the bytes stranded under the old name.
  Skipping the cleanup only changed where the orphan sat. The two endings are now chosen between:
  bytes written at the new path means the old copy is superseded and goes to the trash; no bytes
  written means the existing mirror *is* the asset, and new `fssync.moveFileAssetMirror` carries it
  to the new path.
* **R-30 · the base64 filter wrote bytes nobody supplied.** `assetPayload` dropped every character
  outside the alphabet before decoding, so `data:;base64,QQ!` became `QQ` and `A` was written to
  disk under a success. The filter exists because base64 is routinely line-wrapped and a stored URI
  can carry newlines — so whitespace is still skipped, and anything else is now a refusal.

Both are asserted in `fs-selftest`, and **both assertions were proven to fail with their fix
reverted**: neutering `moveFileAssetMirror` fails three, and dropping the refusal fails one.

### An eighth pass: a reader/writer split, a symlink hole, and one fix that was worse

* **R-31 · `assetview.decodeBase64` no longer accepted what the writer stores.** Relaxing
  `fssync.assetPayload` to take unpadded base64 (R-25) left the reader demanding a multiple of
  four, so a payload `syncFileAsset` had stored came back `ok = false` and the viewer reported a
  stored file as unreadable — a file that saves and will not open. The same split ran the other
  way: the reader still dropped a stray character rather than refusing it, so `QQ!` read back as
  `A`. Both rules are the writer's now, and `asset-selftest` asserts five payloads storable and
  three refused **against both procs in the same breath**, so the next change to either that does
  not change the other fails there rather than in a viewer.
* **R-32 · the static route could be walked out of with a symlink** · severity: **high**.
  `http.resolveStatic` normalised lexically, which resolves `.` and `..` as text and knows nothing
  about links, so a symlink inside the served root pointing out of it produced a path that still
  began with the root, passed the prefix test, and was read through by `serveStatic`. This is the
  hole `fssync.resolveStoragePath` was fixed for — **at both ends**, and only one of the two files
  had been done. Resolved compared against resolved now, with the root resolved too so a tree
  reached through a link still serves. `fs-selftest` asserts the escape refused, the ordinary file
  still served, the escape refused through a symlinked root as well, and the older sibling-prefix
  guard intact. **Proven to fail with the fix reverted**: two assertions go red.
* **R-33 · the response-cache tee was unbounded.** `capture[].add` grew with the whole reply while
  `cacheStore` discards anything over `MaxCacheEntryBytes` — so a long generation was held in
  memory in full to produce a value already certain to be thrown away. `upstream.forward` takes a
  `captureMax` now, and the server passes one byte past the cache limit: everything storable is
  still captured whole, and anything larger is short by construction and refused rather than filed
  as if complete. The relay is untouched, so no cache decision can affect a client's stream.

### A ninth pass: the cache served one request's diagnostics to another

* **R-34 · the response cache stored the diagnostic headers** · severity: **high**.
  `upstream.forward` captured the head *after* splicing `extraHeaders` into it, so the bytes filed
  in the cache carried `X-Jenova-Trimmed`, `X-Jenova-Rag-Hits` and every `X-Jenova-Hit` of whichever
  request happened to fill the entry — and a later hit replayed them verbatim to a different
  conversation. The cache key is the rewritten body, so two requests can share an entry while
  having been prepared very differently: a five-turn conversation that trimmed nothing could be
  served a head announcing that forty turns were dropped. **That is the one diagnostic whose entire
  purpose is to report silent conversation loss truthfully**, and it was the one being fabricated.
  The tee now files what the upstream said, and the caller splices its own diagnostics on a hit at
  the same offset as on a miss, so the two paths put the same headers in the same place. The
  header-building moved above the cache lookup for that reason.
* **R-35 · the viewer's size ceiling did not cover the stored column.** `MaxOpenBytes` was checked
  against the mirror and nothing checked the fallback, so a row with no file on disk went to
  `classify` at whatever size it happened to be, on the GTK thread — the exact cost the constant
  exists to bound. The new `MaxStoredBytes` is that ceiling expressed against the column, which
  cannot be the same number: the column holds base64, so measuring it against the raw ceiling would
  refuse to open a file the composer had just accepted. Asserted as that relation rather than as
  the arithmetic.
* **R-36 · `hb_ot_math_get_glyph_variants` was passed a null count.** The parameter is IN/OUT and
  the total is the return value either way, so a real variable holding zero is well defined by the
  interface where `nil` relies on a reading of HarfBuzz's implementation. Changed to the variable.
  **Not verified by running it**: there is no maths font on this host, so `verticalVariantCount` is
  never reached with a real font here. Recorded as such rather than claimed as tested.

**One finding in the same batch was already fixed** and is recorded so it is not re-opened:
`assetview.decodeBase64` was asked to strip padding and reject only a remainder of 1, which is
exactly what R-31 did in the commit before. The report described the tree as it stood two commits
earlier.

### The shutdown race, closed at the third attempt · **measured throughout**

The review asked for the acceptor threads to be joined after the listener closes and before the
worker sentinels are queued, so no acceptor can enqueue a descriptor once its class's workers have
exited. The reasoning was right from the start; two attempts to implement it were wrong, and each
was wrong for a different reason that only running it revealed.

**First attempt — join them as they were.** Closing a listening descriptor while another thread
blocks in `accept(2)` on it is unspecified by POSIX, and on FreeBSD it does not wake that thread:
`joinThread` never returned and `serve-selftest` hung on three runs out of three. `shutdown(2)`
answers `ENOTCONN` on a listening socket, so it is no help either. Reverted, and the drain in
`joinAll` added as a mitigation instead.

**Second attempt — wait in `poll` with a timeout** so the loop ends on its own and needs no wakeup
at all. Correct in principle, and it still hung: **three runs out of four, intermittently.** The
intermittency was the clue. Two acceptors poll the same listening descriptor; a single pending
connection makes it readable for both; one wins the `accept` and the other, on a *blocking*
socket, waits in `accept(2)` for a connection that may never arrive. A textbook thundering herd,
invisible until something tried to join those threads.

**Third attempt — the listener is non-blocking.** The loser's `accept` fails immediately and it
rounds through `poll` again. `stop` now joins every acceptor before it queues a sentinel, then
closes the listener, so every send that will ever happen has happened before the first worker can
exit. **Six runs out of six, no hang.**

Three things fell out of it that are worth keeping:

* **`running` had to become `Atomic[bool]`.** The acceptors used to be woken by their descriptor
  closing; now the only thing that ends their loop is reading that flag, so a non-atomic
  cross-thread read the compiler may hoist out of the loop would hang the join. The same hazard
  `serverselftest` already records for its own load flag.
* **The accepted socket is set blocking explicitly.** FreeBSD hands the listener's non-blocking
  flag down to it and Linux does not; every read and write below assumes blocking, so it is set
  rather than inherited in either direction.
* **The drain in `joinAll` stays, demoted.** It was the mitigation for a race that is now closed;
  it is a backstop now, and its comment says so.

**The general lesson, twice over in this branch:** the first shutdown fix and the relay contract
were both settled by running the thing rather than reading it, and in both cases the *second*
answer was wrong too. A concurrency change that passes once has not been tested.

### A ninth pass, continued: the probe and the tee

* **R-37 · the status-line contract only applied when there were headers to add.** `splicing` was
  initialised from `extraHeaders.len > 0`, so R-24's rule — less than a status line is no reply —
  was skipped entirely for a relay with nothing to splice. That is the commoner path, not the
  rarer: `/embed` passes no headers at all, and a completion with nothing to report passes an
  empty string. An upstream that sent `HTTP/1.1 200 O` and closed had those bytes relayed and the
  run reported `roComplete`. The probe runs for every response now; `spliceHeaders` returns its
  buffer untouched when there is nothing to add, which was already asserted. **Proven to fail with
  the fix reverted**: four assertions go red.
* **R-38 · `captureMax` was not a hard bound.** The test was `len < captureMax` and the append took
  the whole buffer, so a 16 KB chunk arriving one byte under the cap took the capture 16 KB past
  it. Bounded rather than unbounded, and no caller was harmed — but the caller sets the cap exactly
  one byte past what it will accept, and reasoning that precise deserves a limit that is exact.
  Both append sites now go through one `teeAppend` that takes only the remaining capacity.

### Deferred, with the reason stated

Three further findings from the same review are **not** taken here. None is introduced by this
branch and each needs a decision rather than a patch:

| Finding | Why it is not taken |
|---|---|
| **Remove the mirror when content is explicitly cleared** (`fssync.nim`) | The distinction it rests on does not survive the layer below it. `api.writeRow` writes `node.f(col)` for **every** column (`api.nim:296-302`), so an omitted `content` and an explicit `""` both reach the row as empty — by the time the mirror is consulted there is nothing left to tell them apart. And the safe default is the opposite of the one proposed: deleting a mirror because a client omitted a field is precisely the trap `loadFileAsset` (`gui.nim:676-683`) exists to stop. R-29 removes the staleness for the case that actually moves the row; a general "empty column means delete the file" rule would need the API to carry presence, not just value. |
| **`rag.forgetMessage` races restore and update indexing** (`api.nim`) | Real. `affected` is collected before `db.begin()` and unfiled after the commit, deliberately — unfiling inside the transaction strips the index for a delete that then rolls back, which the comment at `api.nim:399-403` records. Closing the window needs a per-message lock, a deletion generation, or a conditional delete, across `deleteConversation`, `forgetIndexed` and the bulk path. That is a concurrency design for the retrieval layer, not a fix to this diff. |
| **Descendant discovery races fork creation** (`api.nim`, `withForks`) | The same shape and the same answer: the `DescendantsCte` walk runs before the transaction, so a fork created in the gap is flagged deleted inside it but is absent from `affected`, and `rag.query` has no deletion filter to catch it. Serializing discovery with the transaction is the fix and it is the same design decision as the row above. |

The middle two share a root — **`rag.query` does not filter deleted rows** — and that is the thing
worth fixing rather than each caller. Recorded as the next retrieval question.

### What was run

`nimble core`, `nimble gui`, all **20** `-selftest` subcommands, `tests/gui_check.sh`, and the six
`tests/test_*.sh` suites — all green, and re-run after the seventh pass. `bin/jenova --check` passes, and so does the panel-open
variant with all nine guards forced true, with no GTK criticals and no markup errors. The
mapped-window half of `tests/gui_build.sh` still cannot run here — but **for one reason, not
three.** `xdotool` (4.20260303.1) and `xclip` (0.13) are both installed at `/usr/local/bin`, as are
`import`, `convert` and `xwininfo`. **The only missing piece is a display server the harness can
start: `Xvfb`.** An earlier note in this session recorded all three as absent and was wrong.

`Xvfb` is what `gui_build.sh` reaches for, and it is not installed. `/usr/local/bin` does carry
`Xorg` and **`Xwayland`**, and `Xwayland` can run headless — which makes "no display server at
all" the wrong description of this host, and a `Xwayland`-backed variant of the harness's display
block a real option rather than a hypothetical one. Worth trying before treating the mapped-window
gate as FreeBSD-only work.
