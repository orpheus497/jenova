# TESTS

Test specifications, validation criteria and expected outcomes. Mandated by `AGENTS.md`
§ WORKSPACE ARCHITECTURE.

**Created:** 2026-08-28 (Session 004). **Last updated:** 2026-09-01 11:37 (Session 014).
Mandated from the outset; absent for Sessions 001–003. See `DECISIONS_LOG.md` C-10.

> **§5a onward are stage acceptance records** — what each stage had to prove and how. They are
> history, kept for the reasoning. **§0 is the current suite.**
>
> **The commands in §5a–§5f no longer run — corrected 2026-08-31 (Session 007).** They were written
> against a tree that no longer exists and a session copying one of them will get an error, not a
> result. Specifically: **`make core` and `make check`** (§5a N-S0, §5b, §5c, §5d) — there is no
> Makefile (D-AM); **`tests/Makefile check`** — archived; **the N-S1 shell comparison**, which
> sources `lib/detect-env.sh`, `lib/jenova-conf.sh`, `lib/jenova-model.sh` and reproduces
> `bin/jenova-ca:44-48` — all four files are archived, and the inverted-precedence defect it
> measured (B-12 / Q-9) died with them; and **`jenova-core llama-selftest`** (§5f N-S4) — that
> subcommand went with `llama.nim` and `inference.nim` on 2026-08-31.
>
> **The recorded results and the reasoning remain valid as history.** What each check was *for* is
> why these sections are kept. **§0 is the only section to run anything from.**

---

## 0. Current suite — 2026-08-31

**`nimble suites`** builds both binaries then runs the scripts below. Each runs in a scratch
`JCA_HOME` and none spawns a `llama-server` backend.

| Script | Covers |
|---|---|
| `test_api_db.sh` | The `/api/db/*` contract — cascades, fork reparenting, upward restore |
| `test_api_fs.sh` | The filesystem mirror, `/api/fs/*`, `/api/storage/*` and its containment |
| `test_routes.sh` | The route inventory, incl. the pipeline reaching the upstream |
| `test_lifecycle.sh` | The `llama-server` argument vector, `--lan`, port flags, refusal paths |
| `test_models.sh` | Model discovery and switching (§5h) |
| `test_nvimctl.sh` | Reading the live Neovim buffer (§5i). **The one suite that spawns a process** — a headless `nvim` — and the only one needing a compiled driver, `tests/nvimctl_check.nim`. Skips cleanly with no `nvim` installed |

Plus the core's own subcommands: `db-selftest`, `serve-selftest`, `rag-selftest`,
`pipeline-selftest`, `sha256-selftest`, `tree-selftest`, `db-capabilities`.

**There is no Makefile.** `make check` and `make -C tests check` no longer exist (D-AM).

**Archived 2026-08-31:** `test_gpu.sh`, `test_gpu_single.sh`, `test_validate_arg.sh`,
`download-draft-model.sh` — orphaned, wired into nothing. `test-health.sh` went earlier: it shelled
to `python3` and started no server.

**A new suite must be proven able to fail.** Two suites in this project have reported PASS while
asserting nothing. `test_models.sh` was verified by corrupting what its assertions read and
confirming it goes red.

**Run `nimble suites` with `bin/jenova` closed — 2026-09-01. This is T-12's unknown
trigger, identified after two sessions of it appearing and vanishing.**

**Two suites assume nothing is listening on the machine's real ports**, and both fail
while the desktop application is running:

- **`test_routes.sh`** pins `JENOVA_PORT` for its own core but never overrides
  `JENOVA_LLAMA_PORT`, so that core forwards to the default **8081**. Five assertions
  expect **502** — "the pipeline completed and no `llama-server` answered" — and see 200
  or 500 when a real backend answers there.
- **`test_lifecycle.sh`** pins `JENOVA_PORT` for its `serve` cases (`:92`, `:98`, `:110`)
  but runs `backends health` (`:120`) and `backends start` (`:125`) with **no port
  override**. `health` then succeeds where it asserts failure, and `start` refuses with
  *"port 8081 is already in use"* instead of the expected missing-model message — the
  product refusing to start a second backend over a live one, which is correct.

**Proven and dated on both sides:** all six suites passed three times between 09:56 and
09:58, `bin/jenova` was started at 10:01:13, and the failures appear only after.
`test_routes` passes **13/13** on the same binary, with the application still running,
given `JENOVA_LLAMA_PORT=<dead port>`. **Neither is a product fault.** Fix filed in
`TODOS.md` Backlog: give both scripts their own dead upstream ports.

**Also: run the suites through `nimble suites`, not by calling the scripts directly.**
`test_nvimctl.sh` compiles `nvimctl_check.nim` and `nim` is not on `PATH` — `nimble` is,
and it puts `nim` there. Invoked directly the suite fails at the compile step; under
`nimble suites` it passes 5/5.

**Six self-tests, six suites.** *`tree-selftest` was added 2026-09-01 for the
branching tree walk. Earlier trackers said four self-tests;
`db-capabilities` is a capability report, not an assertion, which is where the
miscount came from.*

## 0a. The coverage gap: nothing tests the GUI — 2026-09-01

**Every suite and every self-test above exercises `jenova-core`.** Routes, database,
filesystem mirror, containment, lifecycle and the argument vector, model discovery and
switching, the Neovim buffer reader. **There is no test of `gui.nim` of any kind** — no
suite, no self-test, no compiled driver.

**Every GUI defect in this project's history was found by the USER looking at the
screen**: the black sidebar slab, the unstyled tree, the unreadable wordmark, the
collapsing code blocks, the five-column panel, the oversized chat bubbles, the
one-way-door fullscreen, notes that could not be created, and the crash on quit.

That was survivable while the outstanding GUI work was *layout*, where a screenshot is
the only real test anyway. **It is not survivable for the work now planned**, which is
mostly *logic*: conversation branch trees, message mutation, and parameter plumbing
into the request body.

**What `PLANS.md` requires, per step, and why each is assertable:**

| Step | What must be proven | How, without a window |
|---|---|---|
| **1 — container rename** (T-14) | ~~A renamed project takes its files with it, and a failed move rolls back~~ **DONE 2026-09-01 — see §0b** | Done as planned: `test_api_fs.sh`, +17 assertions |
| **2 — message actions** (G-28) | ~~Edit and delete reach the right rows and cascade correctly~~ **DONE 2026-09-01 — see §0c** | Done as planned: `test_api_db.sh`, +12 assertions. Regenerate and continue remain screen-only |
| **3 — branching** (G-29) | ~~The active path and the sibling counts are right for a known fork shape~~ **DONE 2026-09-01 — see §0d** | Done as planned, and as predicted it was the step needing an assertion rather than a screenshot: `jenova-core tree-selftest`, 26 assertions |
| **4 — chat indexing** (T-17) | A query returns the right message; a conversation-scoped filter confines results; re-indexing a conversation does not duplicate chunks | Extend `rag-selftest`. It already indexes a scratch corpus and asserts ranking, filtering and the vector round-trip |
| **5 — settings** (G-31) | A stored sampling value actually reaches the outbound JSON body | A check on the body-building function. **Not** a live generation |
| **6 — hardware profiles** (S-1) | Known hardware selects the right profile; an opt-in profile never wins automatically; the fallback ladder holds (specific > GPU generic > CPU generic) | A new suite over the profile data. Pure scoring logic, no hardware needed. **Prove it can go red first** — the archived `test_validate_arg.sh` never asserted this and rewrote `etc/jenova.conf` as a side effect |
| **9 — statement cache** (T-2) | The cache stays capped under many distinct queries | A new suite. **Prove it can go red first** |
| **9 — containment** (T-4) | A write through a symlinked parent is refused 403; a legitimate write under a symlinked root succeeds | Extend `test_api_fs.sh`, both directions |
| **9 — history trim** (T-3) | Oldest dropped first, system message never dropped, budget respected | A unit check on the trim function at a small budget |

**The rule this section exists to state:** where a GUI feature's *behaviour* can be
asserted below the widget layer, it must be. Reserve the screen for what only the
screen can show.

## 0b. `tests/test_api_fs.sh` — container renames (T-14, 2026-09-01)

**17 assertions added**, covering what `PLANS.md` Step 1 named and two things it did not.

| Asserted | Why it is the assertion |
|---|---|
| A renamed project's directory moves, and nothing is left at the old path | The defect itself: the row moved and the directory did not |
| The note **and** the file asset are found under the new path | Files are what was being stranded. A directory that moves empty proves nothing |
| The same for a folder rename, and for a workspace rename | Three different resolvers, three different parent chains |
| A renamed workspace keeps its `.git` directory | The workspace *is* a git repository; a rename that loses it loses the history |
| `/api/fs/tree` lists the note at its new path | The Neovim page is the file browser (D-AW), so the tree is the interface the fix exists for |
| A rename onto an occupied directory answers an error, both directories survive intact, and the row is still holding its **old** name | The refusal and the rollback, which are D-BE. This is the assertion most likely to rot |
| Renaming everything back restores the original paths | The move works in both directions, and it leaves the rest of the script reading as written |

**Proven able to fail — the whole point.** Run against the pre-fix source with the new
assertions in place, `test_api_fs.sh` reports **FAIL (12)**, and the twelve are exactly
the positive checks. Some of the absence checks pass vacuously in that run — a
`Delta/Gamma` that never existed is trivially absent — which is why the positive checks
carry the proof and are stated first.

**One assertion was wrong on the first run and the suite caught it**, which is the
cheapest possible demonstration that it bites: it read the row back through
`GET /api/db/projects/<id>`, a route that does not exist. There is no per-id GET on this
surface; the collection listing is the read path. The corrected assertion matches the
whole row, which also pins the column order.

## 0c. `tests/test_api_db.sh` — message actions (G-28, 2026-09-01)

**12 assertions added.** Of the five actions a message now carries, **edit and delete are
pure HTTP and are asserted here; copy is a clipboard call and regenerate and continue are
GUI composition over `gui.send`** — those three are screen-only and are not claimed to be
covered.

| Asserted | Why it is the assertion |
|---|---|
| An edit writes the new text **and leaves `convId`, `role` and `timestamp` alone** | `api.writeRow` is INSERT OR REPLACE over every column, so an edit routed through `putEntity` would blank the rest of the row. The three "keeps" assertions are the ones that would catch that, and they fail for a different reason than the "writes" one — which is why all four are separate |
| An update with no id, and one naming no known column, are both refused | A blank `UPDATE` would report success having written nothing |
| Deleting one message removes it from the listing, **as an explicit negative check** | The action the window's per-message delete performs. A `check` for absence written as a substring match would pass vacuously on an empty response, so this one greps and fails on a hit |
| Its siblings and its conversation survive | Distinguishes a single-turn delete from the conversation cascade asserted further down |
| The deleted message is still in `/deleted` | It is a soft delete, so it must be recoverable — which is what makes the trash view (G-21) possible later |

**Proven able to fail, in both halves separately.** Neutering the `UPDATE` inside the
extracted `api.updateMessage` turns *edit writes the new text* red (and the pre-existing
*partial update writes only given fields* with it), while the three "keeps" assertions
stay green — correctly, since those columns genuinely are not touched. Pointing the
DELETE at a different id turns *deleting one message removes it from the listing* and *a
deleted message is soft-deleted, not gone* red. Two independent corruptions, two
different sets of red, which is the evidence that the assertions are measuring two
different things rather than one.

**Why the update logic moved:** the route body was extracted into `api.updateMessage` and
exported as `patchMessage` so the window's edit and `POST /api/db/messages/update` run
one implementation. Before that the only partial-update code lived inside the HTTP
handler, and the GUI would have needed a second copy — two definitions of one contract,
drifting from the first change.

## 0d. `jenova-core tree-selftest` — the branching tree walk (G-29, 2026-09-01)

**Why this is a self-test and not a suite.** Conversation branching is a tree walk, and a
wrong tree walk **does not fail loudly**: it draws a plausible transcript with the wrong
turns in it, or a "2 of 3" counter off by one. Neither is visible to someone who does not
already know the right answer, which makes it precisely the class of defect a screenshot
cannot catch. So the walk was put in `api.nim` as three pure functions over `(id, parent)`
pairs — `pathTo`, `siblingsIn`, `deepestFrom` — and is asserted here against a fork shape
written out by hand, with no database and no window. `sha256-selftest` is the precedent:
pure logic gets its own subcommand.

**26 assertions.** It began as 15 over one fork shape — a turn regenerated twice, a
conversation continuing under the middle version, an edit of the root turn — and **that
was not enough, which the USER found by running the build.**

**What the first 15 missed, recorded because it is the lesson.** They covered the shape
branching *creates* and never the shape it *inherits*: every message written before
branching has a NULL `parent`, so an existing conversation arrives as a flat set of
roots. `siblingsIn` then reads the whole conversation as versions of one turn, and the
transcript collapses to a single message. **A suite that only tests the shape a feature
produces cannot see the shape it is given.** The eleven added assertions are that gap,
in three layers: the broken behaviour stated explicitly, the migrated behaviour, and the
migration itself.

| Asserted | Why |
|---|---|
| The path to a leaf is root-first and skips the branches not taken | The transcript itself |
| An unknown or empty leaf yields **no** path rather than a partial one | A `currNode` pointing at a deleted turn must fall back, not draw half a conversation |
| Every version of a turn is a sibling, in the order they were made | What the counter counts and what prev/next steps through |
| A turn never branched is its own only sibling | Lets the caller ask unconditionally and draw the control only when there is more than one |
| Root turns are siblings of each other | Editing the first turn of a conversation is the case most likely to be missed |
| Switching to a branch follows it to its **newest** leaf | Picking an older answer must show the conversation that followed *it*, not strand the reader at the switch point |
| A cycle in the parent links, and in the child links, **terminates** | `parent` is data and a row is editable through the API. A cycle must draw a wrong transcript at worst, never hang the window |
| **Unmigrated history makes every message a sibling, and collapses the path to one message** | The defect the USER hit, stated as an assertion so it is a known property rather than a surprise |
| The same turns, once chained, are one path with no version arrows and open on the last turn | What the migration has to produce |
| The migration chains a real table, leaves an already-parented row alone, skips soft-deleted rows, and **changes nothing on a second run** | It runs on every `initDb`, so idempotency is not optional |

**Proven able to fail, three independent corruptions.** Removing the `reverse` in `pathTo`
turns *the path to a leaf is root-first* red; taking the first child instead of the last
in `deepestFrom` turns *the newest branch is the one followed from the root* red; and
making `migrateMessageParents` return immediately turns *the oldest turn stays the root*,
*each later turn is chained to the one before it* and *migrating twice changes nothing*
red. Each corruption is caught by its own assertions and no others.

**Also verified end to end, not only synthetically:** a copy of the USER's live database
was run through `jenova-core db-init` and its four NULL-parent messages came out correctly
chained. The original was not touched.

## 0e. `pipeline-selftest` — request keys survive the rewrite (G-33, G-39, 2026-09-01)

Three assertions, and they guard a silent failure. The window asks for its statistics and
its reasoning split by putting `timings_per_token` and `reasoning_format` in the request
body, and **`llama-server` sends neither unless asked**. `pipeline.prepare` rewrites that
body. If it ever dropped keys it did not recognise, both features would go quietly dead
with every other test in the project still green — no error, no log line, just numbers
that never appear.

**Now ten assertions, in two groups.**

**Four on the pass-through:** unknown top-level keys survive `prepare` with their values
intact. Sampling parameters travel the same path, so `temperature` is asserted alongside
them — Step 5 depends on the same property. **Proven able to fail** by a one-line
`req.delete("timings_per_token")` in `prepare`.

**Six on the outbound body, and these exist because their absence let Continue ship broken
twice.** The window's request body used to be built inside `gui.nim`, where no self-test
could reach it — so a body the server *refuses outright* looked identical to a correct one
from every angle except running the program. It now lives in `pipeline.chatBody`.

| Asserted | Why |
|---|---|
| An ordinary turn asks for live timings and for reasoning to be split out | The two features depend on the server being asked |
| An ordinary turn does **not** ask to continue anything | Sending the continuation fields on every turn would change what the model does |
| A continuation names what it is continuing (`"content"`) | Not `true`, and never `reasoning_content` — the visible answer is what is resumed |
| **A continuation turns the generation prompt OFF** | The half that was missing. Without it `llama-server` answers **HTTP 400** — *"Cannot set both add_generation_prompt and continue_final_message to true"* — so Continue failed outright rather than merely behaving oddly |
| A continuation still ends on the assistant turn being extended | The fields are meaningless without the partial reply as the tail |

**Proven able to fail:** dropping the `add_generation_prompt` line turns *a continuation
turns the generation prompt OFF* red and nothing else.

**Also verified against a running server, which is what the earlier attempt skipped:**
`"1, 2,"` continues to `"1, 2, 3, 4, 5"` — non-streaming returns the whole message,
streaming emits only the new tokens. The window streams, so appending is correct.

## 5i. `tests/test_nvimctl.sh` — the live editor buffer (G-18, 2026-08-31)

Covers `src/jenova/nvimctl.nim`. No `jenova-core` subcommand exists behind it, so the script owns the
editor's lifecycle and `tests/nvimctl_check.nim` owns the assertions.

**Why the assertions are what they are.** `nvimctl` does not fail by crashing. It fails by returning
the file **on disk** instead of the **buffer** — which looks correct in every test where nothing has
been edited, and is precisely wrong for the feature, whose purpose is reading unsaved work. So the
same 13 assertions run twice: once clean, then again after `setline(2,…)` edits the buffer **without
saving**. The script also asserts the edit never reached the file.

**Proven able to fail:** on the dirty pass the buffer-text and `modified` checks were observed going
red and the driver exiting 1, while `cat` showed the file unchanged. That is simultaneously the
proof the assertions bite and the proof of the feature's core claim.

**Measured, not assumed:** `nvim --listen` rejects a socket path near **104 bytes** — FreeBSD's
`sun_path` limit. The suite uses `/tmp/jenova-test-nvim.$$.sock`; the product uses
`$HOME/Jenova/state/`. A path under a deep scratch directory fails with
`Failed to --listen: invalid argument`.

**Run 2026-08-31: 5 passed, 0 failed.**

## 1. Standing rule

The editing environment is a Linux container on a FreeBSD host (the Linuxulator). **Nothing run
there is evidence for FreeBSD behaviour.** Static checks (`sh -n`, `luajit -bl`) and pure-logic
scripts are the exception: they test the text, not the kernel. Anything touching sysctls,
`/proc`, procstat, GPU or the network stack must be run natively before it counts.

## 5a. Plan B stage acceptance

### N-S0 — build proof

1. `make core` exits 0 and writes `bin/jenova-core`; `file` reports an **ELF 64-bit FreeBSD**
   executable.
2. `./bin/jenova-core` runs and exits 0.
3. **The FreeBSD guard must fire, not merely exist.** `nim c --os:linux src/jenova_core.nim`
   must fail with the `{.error.}` message. Run this on every change to the guard — C-9 records a
   guard that passed static checking while doing nothing.

### N-S1 — configuration precedence

The regression that matters is B-12. Compare the two resolution paths directly:

```sh
# Shell path — reproduces bin/jenova-ca:44-48 (local conf sourced BEFORE profile)
sh -c 'JENOVA_ROOT="$PWD"; export JENOVA_ROOT; \
  . ./lib/detect-env.sh; . ./lib/jenova-conf.sh; \
  . ./lib/jenova-model.sh; . ./etc/jenova.conf; \
  echo "THREADS=$THREADS DEVICES=$DEVICES FIT_TARGET=$FIT_TARGET"'

# Nim core — corrected order
./bin/jenova-core config | grep -E '^(THREADS|DEVICES|FIT_TARGET)='
```

**Expected while `etc/jenova.local.conf` declares 8 / three devices / 768:** the shell prints the
*profile* values (4, two devices, 512) and the Nim core prints the *local conf* values. They are
**supposed to differ** until N-S6 deletes `bin/jenova-ca`; identical output before then means the
Nim core has regressed to the inverted order.

Environment precedence: `JENOVA_THREADS=16 ./bin/jenova-core config` must report `THREADS=16`,
beating both files.

**Recorded result, 2026-08-28:** all three checks pass. Shell 4 / `Vulkan0,Vulkan1` / 512; Nim
8 / `Vulkan0,Vulkan1,Vulkan2` / 768; env override 16.

### N-S2 — database concurrency

`./bin/jenova-core db-selftest` — a writer thread and four reader threads against one database.

**What it asserts, and why each matters:**

| Check | Why it is the right check |
|---|---|
| `sqlite3_threadsafe()` != 0 | A single-threaded SQLite build would make the whole design unsound. `initDb` refuses to run against one |
| `journal_mode` = `wal` | Without WAL a writer blocks every reader, reintroducing serialization |
| Distinct connection handle per thread | Structural proof the layer is per-thread, not one shared handle behind a lock |
| **Reader/writer time-window overlap > 0** | **The load-bearing measurement.** Completion proves nothing — serialized work completes too. Only overlap shows the threads ran *at the same time* |

**Recorded result, 2026-08-28:** PASS. 2000 operations across 5 threads in 15.8 ms; each reader
100% concurrent with the writer; five distinct handles.

**A passing self-test does not mean the system is concurrent.** It covers this layer alone. The
system-level property is decided at N-S3, where the async loop must dispatch blocking work to
worker threads rather than calling it inline (C-13). A future regression test for that belongs
with N-S3, not here.

### N-S3 — the server must not serialize

`./bin/jenova-core serve-selftest`. **This is the regression test for the defect that motivated
the whole rewrite**, so it is worth being precise about why it is built the way it is.

It opens an SSE stream and records the gap between consecutive events — **twice**: once with the
server idle, then again while four other connections sit inside real 400,000-row recursive CTEs
in SQLite. The stream is opened *before* the load starts, so it owns its worker; the property
under test is that established streams are not stalled by blocking work elsewhere.

| Why each choice | |
|---|---|
| **Maximum** gap, not average | An average hides a single long freeze, and a single long freeze *is* the defect |
| **Two phases, compared** | One passing run says nothing about whether load matters. The comparison is the evidence |
| **Real SQL, not `sleep`** | A sleep would not exercise the database path that stalled the Lua proxy |
| Budget = 2.5× the send interval | A serialization defect shows as *multiples* of the interval, not milliseconds over it |

**Phase 3 — a saturated class must not take the server down.** Added 2026-08-28 under D-U. Over-
subscribe the debug class 3:1 with 800 ms holds, then time `/health` and `/`. This is the property
a single shared pool fails *even when nothing blocks*: completion streams are long-lived by
design, so enough of them occupy every worker and the server goes dark. **A server can pass phases
1 and 2 and still fail this one.**

**Recorded results, 2026-08-28:** PASS all three. Idle max gap 40.1 ms against a 40 ms interval;
under load 40.1 ms with 38 slow queries overlapping the stream; `/health` 0.2 ms and `/` 0.2 ms
while the debug class was saturated.

> **A test that silently stopped testing — worth remembering.** When the class table was resized
> under D-T, phase 2 kept passing but reported 4 slow queries where it had reported 41.
> `/debug/stream` and `/debug/slow-query` had both landed in the now-1-thread debug class, so the
> "load" queued *behind* the stream rather than overlapping it. The assertion still passed, and it
> was measuring nothing. The load endpoint moved to the api class. **A passing concurrency test
> whose overlap count collapses is not passing — check the work actually happened concurrently.**

**Also verified by raw socket** — deliberately not with `fetch`, which normalises `..` out of the
URL client-side and would have made the traversal check meaningless:

```
GET /../etc/jenova.conf   -> 403 Forbidden
GET /../../etc/jenova.conf-> 403 Forbidden
GET /nope.js              -> 404 Not Found
GET /                     -> 200 OK   (public/index.html)
POST /                    -> 405 Method Not Allowed
GET /debug/slow-query     -> 404 under `serve` (gated; enabled only for the self-test)
```

### N-S3b — the `/api/db/*` contract

`sh tests/test_api_db.sh` — 22 assertions, wired into `tests/Makefile check`. Starts its own
`jenova-core` on a scratch database and stops it on exit.

**Every assertion encodes something `lib/proxy.lua` does**, not something that merely seems
reasonable. `jca_web` is a shipped client that must keep working unchanged while it is deprecated
(D-L), so "sensible" is not the standard — "identical" is.

The three that exist because a first implementation got them wrong, all found by reading `db.lua`
rather than inferring from the route list:

| Assertion | The behaviour it pins |
|---|---|
| `child deleted without forks reparents grandchild` | Children are moved onto the deleted node's own parent, not orphaned (`db.lua:369`) |
| `deleteWithForks removes nested descendants` | The fork walk is recursive, not one level deep (`db.lua:341-360`) |
| `restoring a note revives its workspace` / `its project` | Restore cascades *upward*; without it a restored item sits inside a deleted container and never appears (`db.lua:905-917`) |

Also pinned: integer columns stay JSON numbers rather than strings, partial updates touch only
the fields supplied, soft deletes populate the trash listing, and import runs transactionally.

**Recorded result, 2026-08-28:** PASS, 22/22.

> **A wrong assertion, corrected rather than accommodated.** The workspace-cascade check first
> asserted `projects/all` was empty, but a *different* workspace's project was legitimately still
> alive — the cascade was right and the test was wrong. Rewritten to check the specific row. An
> assertion that only passes because unrelated state happens to be empty is not a test.

### N-S4 — in-process inference

**`./bin/jenova-core llama-selftest [prompt]`** loads the model from config and generates,
bypassing the server. Use it to separate a model/backend problem from a serving problem.

**Recorded result, 2026-08-28** at the full deployed configuration — `devices=Vulkan0,Vulkan1`,
`ctx=32768`, `slots=2`, `kv=q8_0`, `ngl=-1`, `threads=8`: loads (Vulkan0 152.85 MiB, Vulkan1
381.11 MiB) and generates 48 tokens.

**Serving, and the property that matters.** With `serve` running, issue a long generation and time
other classes *while it runs*:

```sh
# long generation in the background
printf 'POST /completion ... {"prompt":"...","max_tokens":180}' | nc 127.0.0.1 $PORT &
# then, concurrently:
GET /health            GET /api/db/workspaces            GET /
```

**Recorded result, 2026-08-28:** `/health` 3–4 ms, `/api/db/workspaces` 6 ms, `/` 3 ms, while the
generation ran to all 180 tokens. **This is precisely the scenario in which `proxy.lua` froze
every other client.** Warm the model with a one-token request first, or the timing measures model
loading rather than serving.

Streaming shape: `POST /v1/chat/completions` with `"stream":true` returns
`Content-Type: text/event-stream` and `chat.completion.chunk` records terminated by
`data: [DONE]`.

> **Not covered by any test yet:** sampling parameters are ignored (N-25) and client disconnect
> does not cancel a generation (N-26). Neither should be assumed working because these checks pass.

## 5g. `tests/test_lifecycle.sh` — the backend argument vector and lifecycle flags (N-S6)

**31 assertions, PASS.**

**The `--lan` assertions are the load-bearing ones and go both ways:** that the client port moves to
`0.0.0.0`, *and* that neither backend does. Backends bind loopback unconditionally — publishing them
would put two unauthenticated inference endpoints on the network (S-0, D-E,
`jenova-ca:568-575`). A one-directional assertion would pass on a build that published everything.

Also pinned: the three port overrides reach the right places; **an unknown `serve` flag is refused
rather than ignored** — silently swallowing a typo is how a run does the wrong thing while looking
correct; and **`backends health` fails when nothing is listening**, because health is not liveness.
A wedged `llama-server` keeps its pid and stops serving, so a pid check calls it healthy. That is
what the watchdog acts on. It does not start `llama-server` — that needs a model, and the models live
under `~/JCA`, which D-AE places permanently out of bounds. It asserts the **command line**, via
`jenova-core backends args`, which prints it without starting anything.

**Why the argument vector is worth a test at all:** under D-AF `llama-server` is the engine, so
these flags *are* the tuning. They are the accumulated result of work against real hardware, and a
silently dropped or reordered one changes generation behaviour without failing anything. Pinned:
`--spm-infill` (the USER's Neovim FIM), `--cache-prompt`, `--offline`, `-cb`, `-fa auto`,
`-sm layer`, loopback binding and ports for both backends, and the embed server's `-ngl 0 -dev none`
— CPU by design so it cannot compete for VRAM with the agent model.

**The branch most easily conflated is asserted in both directions:** `NGL_AGENT=all` must use
`-fitt` and must *not* pass `-ngl`; an explicit count must pass `-ngl N` and must *not* pass
`-fitt`. The two conflict, and passing both is how a single-GPU profile ends up mis-offloaded.

**Refusal paths too:** `start` with no model exits non-zero and names the reason, `stop` is
idempotent, `status` reports each backend separately rather than collapsing to one word — because
"agent up, embeddings down" is a real state, and hiding it is how B-14 stayed invisible.

## 5h. `tests/test_models.sh` — discovery and switching (N-36, N-37, 2026-08-31)

**15 assertions, PASS.** Guards the total-conversion gate: `models.nim` replaced
`lib/jenova-model.sh` and `bin/jenova-model-switch`, the last two shell scripts the running product
relied on.

**A reimplementation of a file-scanning helper does not fail by crashing — it fails by picking a
different plausible file.** Every assertion pins one of those failure modes rather than a happy
path: the agent model is created *out of collation order* so a missing sort would be caught;
`.old` backups must not be discovered as active; the agent falls back to a flat `models/` directory
and draft and embed **must not**, because giving them a fallback the shell never had would start
passing `-m`/`-md` paths where the original left them empty; and the switch's symlink target must be
**relative**, since an absolute one works until the tree is deployed and then points outside it.

**Equivalence was established against the originals before they were archived, not after.** Both
implementations ran against the same scratch trees and their outputs were compared — four discovery
cases, and a switch compared down to the resulting `models/agent` link targets. Identical in every
case.

> **A negative control, because this project has twice shipped a suite that could not fail.**
> `test_routes.sh` once called `pass`/`fail` helpers it did not have and reported PASS while the
> shell printed "command not found"; `test_api_fs.sh` once reported `ok` on eight absence checks
> while the server was on the wrong port. So this suite was **verified to fail**: corrupting only
> what the assertions *read* turns 4 of the 15 red and the suite exits non-zero. **Adding a suite
> now includes proving it can go red.**

## 5f. `sha256-selftest` and `pipeline-selftest` — the completion pipeline (N-S5c, 2026-08-31)

**`sha256-selftest`: 4 assertions, PASS.** The published FIPS 180-4 vectors — empty string, `"abc"`,
the 56-byte two-block message, and one million `a` characters. **The last one is the point:** it
exercises the block loop and the 64-bit length encoding, where a single-pass test would not. A
hand-written hash fails by producing plausible wrong digests rather than by crashing, so published
vectors are the only honest check.

**`pipeline-selftest`: 15 assertions, PASS.** Intent detection and prefix stripping; visual intent
stripping tools and setting `tool_choice: none`; agent mode never overriding a client system prompt
and injecting the CORE MANDATE only when none exists; the freechat fallback; cache key stability;
**the key being the SHA-256 of the rewritten body and not the original**; cache round-trip;
non-chat bodies passing through untouched; and a message already carrying a context marker not
being re-retrieved.

> **Wiring is not proven by unit checks.** `serve` never called `rag.initSchema()`, so the first
> chat request hit a missing table and answered **500 instead of reaching the upstream** — while
> `pipeline-selftest` stayed green throughout, because it calls `initSchema` itself.
> `tests/test_routes.sh` now posts a real chat body and asserts **502**: 502 means the pipeline
> completed and `llama-server` is merely absent, 500 means it threw. **The distinction is the
> assertion.**

> **A vacuous pass, caught immediately — the second this session.** Those new route assertions
> called `pass`/`fail` helpers that existed in `test_api_fs.sh` and not in `test_routes.sh`. The
> shell printed "command not found" to stderr and the suite still reported PASS, because `FAILED`
> was never incremented. **A test that cannot fail reports success just as loudly as one that
> passes.**

## 5e. `jenova-core rag-selftest` — retrieval (N-S5b, 2026-08-31)

**7 assertions, PASS.** Indexes a three-document scratch corpus, then asserts a keyword hit ranks
the right file, that a snippet survives storage (**the property `search.lua` lost on every
restart**), and that a path filter confines results.

**The vector half is asserted without an embedding server, deliberately.** Endianness, the BLOB
round-trip and the dot product are where a silent error would live, and waiting for a server to be
running to find out is how unverified logic ships. `rag.nim` exposes `vectorRoundTrip`,
`similarity` and `storeChunkVector` so the test can pin them directly: a float32 vector survives
byte-exact, identical vectors score 1.0, orthogonal score 0.0, and a stored vector reads back
through the same `queryBlob` path the query itself uses.

**`chunks with vectors: 0` in the output is not a failure** — it is the embedding server being
absent, and keyword-only retrieval is a supported degraded mode that `search.lua` had too.

**What this does NOT cover, recorded as N-31:** the HTTP request and response shape against a live
embedding server on :8082. That is the one part of the semantic path still unproven.

**`jenova-core db-capabilities`** reports what the linked libsqlite3 can actually do —
threadsafety, journal mode and FTS5 — because Q-24's index choice was contingent on a fact that had
been assumed rather than checked (D-AB). Result on this host: `fts5: available`.

## 5d. The route inventory — **now a test**, `tests/test_routes.sh` (2026-08-31)

**9 assertions, PASS.** Wired into `tests/Makefile check`. Runs in a scratch `JCA_HOME` (D-AE).

**Reading the statuses correctly matters here.** A **502** on `/v1/chat/completions`, `/completion`
and `/infill` is the **pass** condition under D-AF: it proves the request was classified and reached
`upstream.forward`, which then found no `llama-server` listening. **A 404 or 405 would mean the
route was never classified at all** — which is precisely what `/infill` returned before N-S4c. The
test asserts 502, not "not an error", for exactly that reason.

The prose below explains why the check exists and how to extend it when a new surface is claimed.

### Why it exists

**Any stage claiming to reproduce a surface must diff its routes against the running binary before
the claim is made.** N-29 exists because that was never done: the audit enumerated the route
families it noticed, `/api/storage/*` was not among them, and N-S5a was recorded complete with five
routes unserved.

The check is one loop and takes seconds:

```sh
probe() { printf '%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" "$2" \
          | nc 127.0.0.1 "$PORT" | head -1; }
```

Enumerate the source's routes first — for `lib/proxy.lua`,
`grep -oE '"\^(GET|POST|DELETE|PUT|\[A-Z\]\+) /[a-zA-Z0-9/_%.-]*'` plus the `find("…")` matches,
since it uses both forms — then probe every one. **A 404 or 405 on a route the original serves is
the finding.** Reading the handler list is not a substitute; that is what produced the false claim.

## 5c. `tests/test_api_fs.sh` — the filesystem contract (N-S5a, 2026-08-31)

**46 assertions, PASS** (31 at N-S5a, 15 more for `/api/storage/*`). Covers what §5b said was
missing: physical path layout, the git repo per
workspace, base64 `data:` decoding, rename-then-trash-the-old-path, the `<epoch>_<name>` trash
naming, the `.metadata.json` sidecar, all four `/api/fs/*` routes, per-entity delete ordering, and
that bulk import does *not* mirror.

**Both API suites now run inside a `mktemp` `JCA_HOME` and delete only a directory matching their
own prefix.** This is not hygiene — `test_api_db.sh` previously derived its database path as
`"${JCA_HOME:-$HOME/JCA}/.system/jenova.db"` and `rm -f`'d it, **so `make check` deleted the live
conversation database on any machine with a real deployment.**

> **A vacuous run, caught before it was believed.** The first execution reported `ok` on eight
> checks while the server was listening on a different port — every one an absence check, and an
> absence check passes when the entire system is unreachable. **A `/health` liveness gate now runs
> before any assertion.** Same lesson as the N-S3 phase-2 overlap collapse: an assertion that
> cannot fail is not evidence.

> **An over-strict assertion, corrected rather than accommodated.** It pinned the sidecar's byte
> spacing — `fs_sync.lua` writes `{"type": "notes", …}`, the Nim core emits compact JSON. Only
> those two components read the file and both parse it as JSON, so the formats are interchangeable
> in both directions. **The fields are the contract; the spacing is incidental.**

**The `/api/storage/*` assertions are about containment, because that is the risk.** These four
routes take a client-supplied path and read, write and delete with it. Asserted: three traversal
forms all refused with **403 and not 404** (a 404 would disclose whether a path outside the root
exists), an absent file inside the root answering 404, the trash preserving the original relative
path, and — after a defect of mine — **a stored file beginning with `[` being served as its own
content rather than mistaken for the JSON listing.** The first wiring picked the content type with
`not body.startsWith("[")`; `ApiResult` now carries `contentType` explicitly.

**And a fidelity finding that only appeared because the port broke an existing test.**
`test_api_db.sh`'s restore-cascade assertions began failing. Not a regression: **`fs_sync.lua:70`
refuses to mirror a row whose `id` is not a UUID, and `proxy.lua:899` deletes the row and answers
500.** The test used `"n2"`, and had passed only because `api.nim` had no mirroring to reject it —
**the test was encoding the gap rather than the contract.** Real UUIDs now, plus an assertion
pinning the rejection.

## 5b. N-27 — the dimension the contract test did not cover *(CLOSED 2026-08-31 by §5c)*

Recorded 2026-08-31. **`test_api_db.sh` passes 22/22 and is not wrong. It is incomplete.**

`lib/proxy.lua` calls `fs_sync` at **ten sites inside the `/api/db/*` routes** —
`sync_workspace`, `sync_note`, `sync_fileAsset`, `trash_workspace`, `trash_project`,
`trash_folder`, `trash_note`, `trash_fileAsset` — so creating a workspace makes a directory and
deleting a note moves the file into a trash tree. `src/jenova/api.nim` performs none of it.

**Why no assertion caught it:** all 22 issue HTTP requests and inspect the JSON that comes back.
The filesystem is never examined, so the suite has no assertion that *could* fail on this. It is
C-9's lesson in a new place — **a check that cannot fail in a dimension is not evidence about that
dimension**, and a green suite says nothing about what it does not look at.

**Required of the N-S5a acceptance test**, so this cannot recur:

| Assertion | Why |
|---|---|
| Creating a workspace/project/folder through `/api/db/*` **creates the directory on disk** | The mirroring contract, in the dimension the current suite omits |
| Deleting a note **moves the file into the trash tree**, and `GET /api/fs/trash` lists it | Pins delete-side mirroring and the `/api/fs/*` port together |
| `POST /api/fs/trash/restore` **returns the file to its original path** | Restore is the half most likely to be quietly wrong |
| `GET /api/fs/tree` matches the real directory contents | The route N-20 must reproduce |
| **Run against the existing `proxy.lua` first, then the Nim core, and compare** | "Identical, not sensible" — `jca_web` is frozen under D-Z and must keep working unchanged |

## 6. What has actually been verified, and how

**Live on FreeBSD 15.1 (Session 001):** `sh -n` across 53 shell scripts · `luajit -bl` on every
Lua file · `ffi_defs` loading with FreeBSD constants and a 16-byte `sockaddr_in` ·
`test_ffi_flags.lua` 5/5 · `jenova-model-switch` 6/6 including filenames containing spaces ·
environment detection · profile selection across the full ladder · CUDA opt-in exclusion ·
zero bash · zero `IS_LINUX`.

**By source reading (Session 003), not execution:** remediation-plan Phase 1 — non-variadic
`fcntl`/`open`/`ioctl` with a FreeBSD load guard, `set_cloexec` on accepted sockets,
`fd_set_new()`, the `stalled` flag, the drained accept loop, backlog 128.

**Session 004:** `sh -n scripts/cleanup.sh` clean, plus an end-to-end run of
`cleanup.sh --logs --cache --state` answering `n` at the prompt, confirming all three paths
resolve under `$JCA_HOME` (`var/log`, `var/cache`, `.system`) and that nothing outside it is
targeted. Nothing was deleted.

**Not verified by anyone yet:** a full build, an install, a live daemon start, and the complete
`proxy-concurrency` harness on native FreeBSD.
