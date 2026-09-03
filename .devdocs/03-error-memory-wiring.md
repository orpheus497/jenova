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
| E-03 | 32 silent exception handlers, 3 of them user-visible faults | error | medium | **open.** Needs a per-site judgement pass, not a sweep |
| E-04 | Error-body reader | — | none | **withdrawn — the finding was wrong** (see above). A fix was written and reverted |
| E-05 | Pipeline diagnostics discarded; silent history trimming | wiring | medium | **fixed.** Intent, RAG hits, web hits, editor-document and trimmed-turn count travel as response headers; documented in `docs/usage.md`. The splice is built to fail only by omitting the header, never by damaging the stream, and was driven end-to-end against a fake upstream |
| E-06 | `lanAddress` spawns 3 shells on the GTK thread; header claim false | error | medium | **half fixed.** The false claim in the module header is corrected and now says exactly what the GUI spawns and why. **The thread move is deliberately not taken**: it moves state across a thread boundary in the one file this project cannot type-check off FreeBSD. Do it in a session that can compile the GUI, using `hwWorker`'s shape |
| M-01 | Three unbounded GUI caches, never cleared | memory | **high** | **fixed.** `BlockMemo` and `ParseMemo` gain caps with oldest-first batch eviction and a `clear`; `thumbCache` gains a cap; all three are emptied on a conversation switch and the two keyed ones forgotten on a delete. Asserted by overrunning the caps, not by reading the constants |
| M-02 | Attachment disk cache never swept | memory | medium | **fixed.** `paths.sweepCache` prunes oldest-first at startup and **matches only `attach-*`** — asserted, because `cacheDir` comes from an environment variable and this is exactly how B-07 happened |
| M-03 | RAG vector search full-scans every chunk per query | memory/perf | **high** | **fixed.** A generous newest-first scan ceiling, a hash index replacing the O(rows × documents) dedupe, and scoring straight off the packed blob instead of allocating a seq per row. Asserted that packed and unpacked scoring agree, including at 768 dimensions and on a mismatched width |
| M-04 | Backend logs never rotated | memory/disk | medium | **fixed.** Size-capped rotation at start, one previous generation kept. Rotation is at start and not mid-run because that is the only moment no descriptor is open on the file |
| M-05 | Deliberate bounded leaks — **do not "fix"** | memory | none | recorded, untouched |
| W-01 | Three settings wired to nothing | wiring | high | **1 of 3 fixed**, and all four reasons corrected. `copyTextAttachmentsAsPlainText` is wired through `pipeline.copyTextFor`. `pasteLongTextToFileLen` needs a paste handler on the composer; `pdfAsImage` needs a rasteriser; `autoMicOnEmpty` needs a recorder. A new assertion refuses any pending reason that blames the finished attachments step again |
| W-02 | Three endpoints called but not served | wiring | medium | **won't fix — `jca_web` is frozen** (ruling). Recorded in report 02, P-C2 |
| W-03 | Retrieval indexing coverage is accidental | wiring | low | **open.** The coverage is complete; consolidating it at the shared `putEntity`/`patchMessage` layer is the remaining work. Now documented in `docs/context-and-retrieval.md` §1 |
| W-04 | `toolCalls` written by one surface, read by neither | wiring | low | **parked** — downstream of MCP, which is deferred |
| W-05 | Push/Pull database round trip | wiring | medium | **parked** — ruling: out of scope for the GUI, and `jca_web` is frozen |
| D-12 | `db-selftest`'s 25% overlap floor is a wall-clock assertion that fails under load | test | low | **open**, newly found. Documented in `docs/usage.md` so a failure is not mistaken for a database defect; the threshold should be re-shaped against a baseline measured in the same run |

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
