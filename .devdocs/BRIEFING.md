# BRIEFING

**Last updated:** 2026-08-31 13:21
**Branch:** `bsd`
**Phase:** 3 — Execution. Plan B (Nim native FreeBSD desktop application) is the active workstream.

> **This file is overwritten each session, not appended to.** Its previous revision carried a §5
> that contradicted its own §1 three times over — it said N-S6 had five items outstanding when §1
> recorded N-S6 complete, listed N-24 as "cheap and independent" and N-31 as "not blocking" when
> both were closed, and stated the tree was uncommitted when it is clean. **Recorded as B-41 and
> fixed by this rewrite**, because this is the file `AGENTS.md` says to read first.

---

## 1. Current state

| Item | Value |
|---|---|
| Architecture | **`llama-server` is the inference engine; the Nim core is the harness around it (D-AF).** Never a standalone — this is permanent |
| Stage | **N-S0 … N-S6 COMPLETE, and re-verified against source 2026-08-31 13:07.** Config, database, threaded server, the full `/api/*` surface, filesystem mirror, RAG, the completion pipeline (N-30 closed), and lifecycle — `backends [start\|stop\|restart\|status\|health\|args]`, both argument vectors, `--lan`, port flags, and a watchdog thread. **B-13 closed by construction** |
| Next | **N-S7 — the GUI.** owlkettle GTK4 window, chat view, streaming, tray on StatusNotifierItem (N-10). The highest-risk stage; D-Q put it last deliberately. **Gated by N-11**, a dependency change awaiting approval. *(At 13:07 this row proposed three stages of repairing the shell installer, the shell-era docs and the shell test scripts ahead of it. **Withdrawn by D-AH — that is rebuilding the program being replaced**, and D-O already ruled it out)* |
| Archived | **Done 2026-08-31.** 14 `lib/*.lua`, `bin/jenova-ca`, two test scripts and `tests/proxy-concurrency/` moved to `.devdocs/ARCHIVE/` with a manifest. **Thirteen defects closed by the move alone** — B-12, B-13, B-14, B-15, B-16, B-17, B-18, B-19, B-23, B-36, N-19, N-23. **B-24 is NOT among them** — see the correction in §6 |
| Broken by it | **Enumerated 2026-08-31 13:07 and it is six times what was recorded.** 33 dangling `jenova-ca` references across the shell tree, 14 in `lib/ui.lua` alone, plus **22 in `README.md` and `docs/`**. Full table in `TODOS.md §1b` |
| Startup | **One command.** `jenova-core serve` starts the HTTP server *and* forks both backends; the forks return instantly and models load inside `llama-server`. Already-running backends are left alone, so a harness restart never reloads a model. `JENOVA_NO_BACKENDS=1` serves without them, which is what the test suites use |
| Runtime home | **`$HOME/Jenova`.** `~/JCA` is the legacy deployment and is permanently untouchable (D-AE); the core refuses to resolve against it |
| Tests | `test_api_db` 23 · `test_api_fs` 46 · `test_routes` 13 · `test_lifecycle` 31 · `pipeline-selftest` 15 · `rag-selftest` 7 · `sha256-selftest` 4 · `db-selftest` · `serve-selftest`. **Run individually, all PASS.** `make -C tests check` **aborts on its first line** — `test-health.sh` needs `python3` and starts no server (B-40). And there is **no `check` target at the repository root** (B-42) |
| Open decisions | **NONE.** `DECISIONS_LOG.md`'s status index at the top of the file is authoritative and overrides the stale `AWAITING USER DECISION` markers further down. **Nothing is blocked on the USER** — but **six new items raised today are Directive 1 gated**, which is a different thing: they need approval to execute, not a decision to make |
| Settled, never re-asked | **Devices:** agent on GPU, embedding on CPU, drafter on GPU, **Vulkan0 and Vulkan1**. **`etc/jenova.local.conf` is the USER's file** — no session edits or "fixes" it. **`~/JCA`** untouchable. **Licence** AGPL-3.0. **Engine** `llama-server`, always |
| Commits | **The working tree is clean.** `git status --porcelain` is empty; HEAD is `5e6db04`. *(The previous revision of this file said "everything is uncommitted" — false, and recorded as B-41(d).)* Commit boundaries remain the USER's alone (C-11) |

## 2. Rulings in force — not to be reopened

| Ruling | Decision |
|---|---|
| **D-AH** | **Do not rebuild the program being replaced.** The shell installer, the shell-era docs and the shell test scripts are scaffolding around a system that goes. **Remaining work = what is missing from the Nim core**, never what is broken in the old one. **N-35 withdrawn, B-39 deferred, B-24 resolves by deletion, B-11 was never a question.** Deployment of the single binary is one decision after the rewrite |
| **D-AG** | **Testing is per-instance and permissioned.** Every run that starts a process is asked for individually — what, why, how long. **Permission to test once is never permission to test again.** Building and self-tests that spawn nothing stay permitted under D-AC |
| **D-AF** | **`llama-server` is the inference engine. Jenova is the harness.** `upstream.nim` is the primary path. In-process inference is retained behind `JENOVA_INPROC=1` (Directive 3) but is not the default and nothing new is built on it. **Supersedes D-N's linkage clause and D-W entirely** |
| **D-AE** | **`~/JCA` is permanently off limits — no migration, overwrite or change, ever.** The `~/Jenova` split exists so testing cannot reach the deployment. **Not to be raised again** |
| **D-AD** | The runtime home is `$HOME/Jenova`, at all 20 code sites. `paths.resolve` refuses `$HOME/JCA` unless `JENOVA_ALLOW_DEPLOYED=1` |
| **D-AC** | Building and testing are permitted. Nothing may create, write, delete or rename under `~/JCA`. `make install` stays out of scope for the whole rewrite |
| **D-AB** | This workspace is a Linuxulator container. **A detection is not evidence until its mechanism is shown not to route through the emulation layer** — state the mechanism with the claim |
| **D-Z** | `jca_web/` is frozen. Not touched, edited or damaged. B-01, B-03, B-04 defer to N-S9 |
| **D-Y** | No deployment, build or install *testing* until the rewrite is complete. V-1 … V-6 are a post-refactor phase. **Note the distinction N-S6b turns on: writing the install path is not exercising it** |
| **D-X** | **The licence is AGPL-3.0; copyleft dependencies are permitted. Closed permanently** |
| **D-S / D-T / D-U** | Worker-thread pool, not `asyncdispatch`. Two-device personal product. Per-class thread isolation: `static:4 health:2 api:3 completion:3 embed:1 debug:1` — **re-verified in `routes.nim` today** |
| **D-L / D-O / D-P / D-Q** | Native FreeBSD GUI target · fix only what survives · GTK4 + libadwaita via owlkettle · backend first, GUI last |
| **C-11** | No git writes, ever |

## 3. What the core does today — **re-verified against source, not carried forward**

**Served by `bin/jenova-core`:** `/health`, `/v1/health`, `/api/db/*` (7 entities, soft deletes,
cascades, restore), `/api/fs/*` (trash, restore, empty, tree), `/api/storage/*` (save, get, list,
trash), static assets, and `/v1/chat/completions`, `/completion`, `/infill`, `/embed*` proxied to
`llama-server` and the embedding server. Dispatch confirmed at `server.nim:245-253`; classification
at `routes.nim:71-84`, where `/v1/health` is tested **before** the `/v1/` prefix precisely because
it used to answer 400.

**Every chat request is rewritten before it leaves** — `pipeline.nim` carries the four intent
prefixes (`:44-47`), the `--- REPOSITORY CONTEXT ---` marker (`:53`), the `tool_choice: none` strip
(`:210`) and the cache key on the **rewritten** body.

**Retrieval ships** (`rag.nim`): the FTS5 virtual table is created at `:62`, and
`jenova_core.nim:474` calls `rag.initSchema()` on the `serve` path — the wiring whose absence made
the first chat request answer 500 while `pipeline-selftest` stayed green.

**Lifecycle** (`lifecycle.nim:350`): watchdog at 30 s interval / 60 s cooldown / 3 failures, exactly
as documented. `--lan`, `--port`, `--llama-port`, `--embed-port` present; **`--daemon` deliberately
absent.**

**`lib/` holds four files:** three shell modules that `config.nim` shells out to, and `ui.lua` until
N-S7. **Thirteen subcommands** on `jenova-core`, not the eight this workspace recorded.

## 4. Where the trackers were wrong — 2026-08-31 13:07

**The Nim core matched its map on every functional claim tested, and thirteen open B-defects were
re-confirmed at their cited `file:line`.** What failed is the surrounding record.

| Claim | Reality |
|---|---|
| N-34: *"`install.sh:240` deploys `jenova-ca`"* | True but one sixth of the surface — 33 sites. **Both it and N-35 are then withdrawn as work by D-AH: every file holding them is a file the rewrite removes.** Enumerate once, schedule nothing |
| B-24 *"CLOSED — dies with the `proxy-concurrency` harness"* | **False.** `tests/test-health.sh:14` still needs `python3`; `python3` is still not in `DEPS`. Archiving the harness closed **half** a defect (**B-40**). **Resolves by deleting the script, not by fixing it** (D-AH) |
| *"`make check` runs five scripts"* | **There is no `check` target at the repository root** (**B-42**). It is `make -C tests check` |
| `ARCHITECTURE_MAPPING.md`: *"Eight subcommands"* | **Thirteen.** Third time this row has been stale (**B-41b**) |
| `ARCHITECTURE_MAPPING.md §8`, second paragraph | Named three archived scripts as present, two paragraphs after saying five (**B-41c**) |
| `BRIEFING.md §5` (previous revision) | Contradicted its own §1 on N-S6, N-24 and N-31 (**B-41a**) |
| `BRIEFING.md §1`: *"Everything is uncommitted"* | **The tree is clean** (**B-41d**) |
| Nothing recorded it at all | **22 `jenova-ca` references in `README.md` and `docs/`**, plus 8 archived Lua modules cited as live implementation (**B-39**) |

**All five of last session's errors had one shape — a count or a completion asserted from what had
just been written instead of enumerated from the thing itself. Four of the eight above are the same
shape again.** The corrections made in place today were all made by enumeration.

## 5. Outstanding — the plan is in `PLANS.md` § REMAINING WORK

> **Corrected 13:21 by D-AH.** The 13:07 revision of this section listed three stages of repairing
> the shell installer, the shell-era documentation and the shell test scripts, ahead of the GUI.
> **All three rebuild the program being replaced**, and D-O — *fix only what survives the rewrite* —
> already ruled them out. **The remaining work is what is missing from the Nim core.**

**1. N-S7 — the GUI.** owlkettle GTK4 + libadwaita, chat view, streaming, tray on
StatusNotifierItem (N-10). Subtracts `jenova-ui/src/main.c`, `lib/ui.lua`, the GTK3 dependency and
`bin/jenova-term`. **Gated by N-11**, and by owlkettle being unproven on this host — a throwaway
spike remains the cheap mitigation. **N-21 is the contract decision to take here rather than
inherit.**

**2. N-S8 — `jenova-cli`.** Terminal agentic loop with tool execution. **The one stage that adds
rather than ports.**

**3. N-S9 — retire `jca_web/`.** **D-Z lifts here**, closing B-01's live privacy leak, B-03, B-04 —
and the shell installer/updater/uninstaller go with it.

**Deployment is one decision at the end, not a stage.** The product is a single Nim binary; what
installs it is settled once, after N-S9, against that binary.

**The engine wiring is done and proven, not pending:** agent on :8081, embeddings on :8082 (verified
against a live embedder), `/infill` classified and forwarded to a `--spm-infill` build, lifecycle
and watchdog. **`llama-server` is the engine — none of this rebuilds it.**

**Independent and cheap, genuinely surviving:** `hardware-profiles/` is data and outlives the
rewrite — B-10 (the only CPU-only profile, entirely Linux), B-20 (`profile.conf` contradicts its
`jenova.conf`), B-05's non-CUDA half.

**Resolves by deletion:** `tests/test-health.sh` — a shell health test for the archived proxy that
shells to `python3` and starts no server. `jenova-core` covers health in-binary. Archive it and
**B-24 dies by subtraction**, as B-23 did.

**Not work, recorded so it is not re-raised:** the shell tree's defects die with the shell tree
(B-11, B-27, B-28, B-29, B-35, the 33 dangling `jenova-ca` references, **N-34 and N-35 entirely**),
and the documentation defects (**B-39**, with B-32/B-33/B-34) defer until the rewrite is complete.

**Needs the USER, because `~/JCA` is out of bounds:** end-to-end generation and per-request sampling
through a live `llama-server`. The models live under `~/JCA`.

## 6. Standing process notes

- **Enumerate, do not assert.** Counts and completion claims get checked against the thing itself.
  Four of today's eight findings exist because that was not done.
- **Every decision and ambiguity goes to the USER.** Seek clarity over assuming.
- **A ruling records only what the USER said.** Any inference drawn from it is a separate question
  that must be asked.
- **Before raising a question, check the standing rulings and the code for an existing answer.**
- **A stage that archives or moves files must re-read what points at them** — the archive left 33
  dangling references and only 5 were recorded.
- **C-11:** no git writes. **D-AB:** state the mechanism behind any detection claim. **D-AG:** every
  process-starting test run is asked for individually.
