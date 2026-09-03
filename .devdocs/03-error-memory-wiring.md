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
| E-05 | Pipeline diagnostics discarded; silent history trimming | wiring | medium | **fixed.** Intent, RAG hits, web hits, editor-document and trimmed-turn count travel as response headers; documented in `docs/usage.md`. The splice is built to fail only by omitting the header, never by damaging the stream, and was driven end-to-end against a fake upstream |
| E-06 | `lanAddress` spawns 3 shells on the GTK thread; header claim false | error | medium | **fixed.** Now a `lan_addr` job on the control worker answering with `umLanAddr` — `hwWorker`'s shape. The one remaining synchronous call is at startup, before the window exists, where there is no frame to block |
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
* **`upstream.forward` was driven end-to-end** against a fake upstream that feeds a response head
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
