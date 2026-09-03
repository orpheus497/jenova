# BRIEFING

**Last updated:** 2026-09-03 11:45 (Session 026c)
**Branch:** `bsd`, at **`256a6528`**. **The working tree is NOT clean and code is being changed
right now — read §0a before you touch `src/`.** *(This header said `9fc9ecc7` "with Session 025's
work uncommitted". The USER committed it as `256a6528`; the commit is titled "Chat bubble resizing"
and its content is the whole of Session 025 — 13a, 13b, the three composer repairs and the SIGBUS
fix. **The branch header was a commit stale in three consecutive sessions**, which is why this line
is checked with `git log` and never carried forward.)*
**Step 13a and 13b are built.** **13a's composer was rebuilt at 11:14 as `DraftView`** after two
failed repairs from the USER's screen, and **a SIGBUS on Enter was fixed at 11:24** — an event
handler bound in `afterBuild` held a pointer freed on the first redraw. All of it is in
`PROGRESS.md`, with the five toolkit traps collected in `PLANS.md` Step 13a. Two new modules
(`composer.nim`, `convmd.nim`), and `gui.nim`, `api.nim`, `fssync.nim`, `theme.nim`,
`jenova_core.nim` and `jenova_core.nimble` changed. That build was green — every self-test passed,
both binaries built, `bin/jenova --check` exited 0. **Do not carry that record forward as current:
`src/` has moved a long way since.** **Whether the tree builds is a fact with a five-minute shelf
life while §0a is live** — this sentence has already carried two binary timestamps that were false
within minutes of being written. **Run `nimble core` and `nimble gui` and find out.** `jvim/` is
tracked on purpose and `.gitignore` says so.

**Session 026 re-derived 22 A-series claims against `src/` and refuted none.** The findings hold;
**every `gui.nim` address in them was wrong**, which is the seventh sweep's ruling being ignored
when the A-series was written. The corrections are in `TODOS.md` at the head of the A-series.

**Then, on the USER's approval: A-69 fixed at 11:38 and nothing else** (`PROGRESS.md`;
`gui.nim` rebuilt, `--check` 0). **Two things this session found that are not in the A-series
corrections above:** the 866 parity verdicts behind 13c **exist in no record at all** — `TODOS.md`
A-59's pointer to "the session record" was checked and is false, so 13c's first step is
re-deriving one area from `jca_web/src`, not looking a list up; and `PROGRESS.md`'s 2026-09-02
07:51 entry, which recorded 10b as built, now carries the correction saying it never worked.

---

## 0a. FOUR SESSIONS ARE LIVE IN THIS REPOSITORY. READ THIS BEFORE OPENING A FILE IN `src/`.

**This is not a hypothetical and it is not history — it is the state of the tree as this line is
written.** On 2026-09-03 the USER had **four Claude sessions open on this checkout at once**, and
at least three were given the same opening instruction. Each asked the USER for the phase in its
own terminal. **Each got a different answer, and each began writing it into these shared files.**
The tree went from clean to six modified trackers and two modified source files in about fifteen
minutes, and no single document knew it.

**What that produced, recorded because it is the failure mode, not the anecdote:**

- A `SESSION_HANDOFF.md` entry stating *"No product code was touched"* and *"Files touched: … No
  source file"* — accurate for its own session, **false about the tree**, which already carried
  another session's `gui.nim` change. Two sessions each correctly denied the edit; a third owned it.
- Two orderings of the remaining work, both recorded as the USER's ruling, in two files:
  **`DECISIONS_LOG.md` D-CI** (the defects 12e-1 → 12f-1 → 12e-2 → 12f-2 → 12d, ahead of 13c) and a
  separate instruction to build **Step 12c (A-3, A-4)**, which D-CI does not mention at all.
- A binary-freshness claim in this very file that was true when written and false eleven minutes
  later.

**The standing rule that comes out of it:**

> **Before editing anything in `src/`, run `git status` and `ListAgents`.** A clean tree in a
> tracker is a claim about the past. If another session holds the file, message it — do not diff
> around it and do not assume the change you are looking at is yours.
>
> **One session owns `.devdocs/` at a time.** As of 11:45 that is this session, by the USER's
> instruction; the others write code and report completed units to it. **Trackers written by four
> hands concurrently are worth less than no trackers**, because they read as one coherent voice
> while contradicting each other two screens apart.

### In-flight register — 2026-09-03 11:45. **Uncommitted work by other sessions.**

**Attribution took three corrections to settle, and how it settled is the useful part.** Two
sessions denied the 12c work; mtimes and the `gui.nim` diff together pointed at one of them; **the
actual author was a fifth session nobody had counted**, which identified itself unprompted. **A-5
in particular was declared an orphan by two sessions** before its author claimed it. **Nothing here
was recorded until its author claimed it or this session read it out of the tree** — a peer
explicitly asked not to be recorded on inference, and it was right to.

### Roster — who is who, 2026-09-03 11:57

**Recorded because it took an hour and three wrong attributions to establish, and because
`ListAgents` shows a session its peers but never itself** — each session's own name is the one
missing from the four it can see.

| Name / role | Writes | Work |
|---|---|---|
| **DEVDOCS MAINTAINER** — `jenova-26 [25ad4a]` | `.devdocs/` **only**, and nothing else, ever | Sole writer of these trackers. **Holds and brokers the `src/jenova_core.nim` token.** Verifies every reported unit by running the binaries before recording it |
| **PLANNER** — `jenova-d3 [1f330e]` | Nothing | Writes forward plans and hands them to the maintainer. No product code, no `.devdocs/` |
| **CODING PEER 1** | `markdown.nim`, `gui.nim` | **A-26** and **A-17** built; **A-48** in flight |
| **CODING PEER 2** | `fssync.nim`, `api.nim` | **A-69** built; **A-16** written, **A-18** next |
| **12c AUTHOR** | `pipeline.nim`, `http.nim`, `server.nim` | **Step 12c** (A-3, A-4, A-5) built. **Never compiled it** — instructed not to build |
| **EXAMINER** | Nothing | Web UI ↔ GUI parity. Produced 13c's first real work list (`PLANS.md` Step 13c) |

**Address a session by role, not by socket and not by "the other session".** Three of the five
could not name themselves, two disclaimed the same change, and one was not counted at all until it
spoke up.

**Agreed division, by FILE rather than by work unit — because files collide and tasks do not:**

| Files | Holder | Work |
|---|---|---|
| `pipeline.nim`, `http.nim`, `server.nim` | 12c author | **Step 12c — A-3, A-4, A-5. BUILT** (`PROGRESS.md`). Then **12d** (A-7), since it already holds both files that needs |
| `markdown.nim`, `gui.nim` | A-26 author | **12e-1 (A-26) — BUILT.** Then **12e-2 (A-48)**, the same file. **`gui.nim` goes whole to one holder** — it carries A-26, A-5 and A-69 together, and splitting one file across two writers is the collision being avoided |
| `fssync.nim`, `api.nim` | third peer | **12f — A-17** written and compiling, **assertions outstanding, so not a completed unit.** Then **A-16/A-18**. Needs a small `gui.nim` surface for A-18 and negotiates it with that file's holder first |
| `.devdocs/` | this session | The trackers, and this register |

**That parallelises D-CI instead of serialising it, and no two sessions hold a file.**

### `src/jenova_core.nim` is a TOKEN, not an etiquette

**All the assertion work lands in that one file** — `pipeline-`, `error-` and `attach-selftest` for
12c, `markdown-selftest` for A-26, `fs-selftest` for A-17. **A clobber there is invisible until a
build breaks or an assertion silently disappears**, which is the exact class of failure these
trackers exist to catch and the reason Session 023 found a green suite over dead code.

> **The `.devdocs/` session holds the token and passes it on.** Ask, write, build, report green,
> and it moves to the next in queue. **Hold it while you type, not while you think.** A holder that
> goes quiet has it reclaimed, and the reclaim is recorded here.

**Nothing enters `PROGRESS.md` as built until a green `nimble core`, `nimble gui` and `bin/jenova
--check` has been established against the tree as it then stands.** A build proof taken before
`jenova_core.nim` changed underneath it is not a proof of the tree after — a peer volunteered
exactly that about its own green run, and it is now the rule. **In practice every unit here was
verified by a session other than the one that wrote it, and 12c's author never compiled its own
work at all**, having been told not to build. **That separation turned out to be worth more than
the process that produced it by accident.**

---

## 0. READ THIS BEFORE DOING ANYTHING

Every rule below exists because it was broken, repeatedly, and cost the USER a day.

> ### Rule 0 — **DO NOT RUN THE PRODUCT, AND DO NOT LOOK AT THE MACHINE** (**D-BJ**)
>
> Until the migration is complete: do not start `bin/jenova`, `jenova-core serve`, the
> backends, or `nimble suites` **unless the USER asks for that specific thing in that
> message**. **Building is not running** — `nimble core` and `nimble gui` are free and are
> how a change is checked.
>
> **Never enumerate processes or ports to see what the USER has open.** Nobody asked for an
> audit of their machine. Running the product seizes ports and loads gigabytes onto the
> GPU, in the middle of the USER's actual work.
>
> **T-12 is closed.** Two suites fail if something already holds the real ports. That is
> the whole of it, it has been fully diagnosed three times, and it is never diagnosed
> again. Seeing those failures: write nothing, say nothing, carry on.
>
> **The underlying pull, named so it is recognisable:** an unexplained red result creates
> an appetite to prove it, and that appetite is the bug. **Evidence is only worth
> gathering for work the USER asked for.**

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run** — and **never deny what plainly was run.** Both halves are the rule. If it was not executed, say "I don't know". If the USER says they ran it, they ran it. |
| **2** | **This is a Nim program using `llama-server`. That is all it is.** No shell scripts, no Lua, no C, no Makefile. Build with `nimble`. |
| **3** | **The archived old build is not work.** A broken reference to an archived file is fixed by **deleting the reference or porting it to Nim** — never by repairing it, and never by asking the USER which (**D-AZ**). |
| **3b** | **Everything is driven from the GUI** (**D-BC**). Anything needing a terminal, a shell script or a hand-edited file is a defect. |
| **4** | **Explain in plain English, then cite the ID.** "G-23 needs resolving" communicates nothing. Say what it is, then give the reference (**D-BA**). |
| **5** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Check the stdlib and the codebase first — including whether the API route you are about to write is already implemented and tested. |
| **6** | **Do not rebuild old patterns.** The two-command split was rebuilt after the USER killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **7** | **Comments only where the code is not self-explanatory.** No essays above functions. Do not retroactively "improve" existing comments. |
| **8** | **Do not ask what has been answered.** `DECISIONS_LOG.md` SETTLED FACTS and its QUESTION STATUS index, first. |
| **9** | **Do not write derivable facts into these documents.** Counts and file lists rot. Point at the code. *Session 023 found the self-test count wrong again — two files said thirteen, the dispatch carries fourteen.* |
| **10** | **Re-check a tracker's claims against the code; do not carry them forward.** Session 013 found seven false claims. Session 015 found thirteen rotted citations. **Session 023 checked 388 claims across all ten trackers and 176 of them — 45% — did not hold as written.** |
| **11** | **Verify a scope list against the source, not against a summary.** The "GUI parity" list carried since Session 010 named six items. **The real inventory is 1,095 Web UI features, enumerated 2026-09-03 and recorded as `TODOS.md` A-59.** Check scope claims against that. |
| **12** | **A "not yet run" label is not durable.** It survives exactly until any evidence contradicts it — a screenshot, a defect report, or the USER saying so. |
| **13** | **A new assertion is not believed until it has been shown to discriminate — and you prove that by varying the DATA, never by breaking the code (D-BX).** Give the function inputs that must produce different answers and assert both sides; assert a *transition* rather than a state. |
| **14** | **Cite the symbol, then the line.** A bare line number is a claim with an expiry date. `fssync.resolveStoragePath (fssync.nim:694)` survives a refactor; `fssync.nim:628` does not. *Session 023 watched an agent cite `nvimctl.alive` at `:350` in a 196-line file — inside the audit that was hunting for exactly this.* |
| **15** | **A green suite says the parts work, never that anything calls them.** `rag.nim` was fully asserted and completely dead for weeks. When a feature is finished, assert the *join*, not only the parts. |
| **16** | **NEVER edit the product code to break it, for any reason (D-BX).** Not to prove an assertion bites, not with a copy to restore from. If a test passes on data that should fail it, the hole is in the assertion set; write the missing assertion and re-run it **against data**, never against a damaged file. |
| **17** | **A compile is not evidence the application starts.** **Run `bin/jenova --check` before handing over any GUI change** — it builds the whole window under a real GTK and exits, showing no window and binding no port. **And know its limit: it builds each branch once**, so it proves the window reaches its first frame and never that it survives a *state transition*. It exited 0 on the build that aborted the moment a note was opened (G-51). |
| **18** | **REPLACED 2026-09-03 09:02 — the suites now mean something, and test work is now LAST.** This rule said a green build proved nothing because `nimble suites` ran no self-tests and four of six passed when they could not run. **A-1 and A-2 are built** — every self-test runs and a suite that cannot run fails. **The rule that replaces it is the USER's instruction of 09:05 (`TODOS.md` A-68): test and check work is left until last.** A red suite met while doing feature work is not a work item — record nothing, say nothing, carry on, exactly as Rule 0 already directs. Do not open a session with test bookkeeping. |

---

## 1. What this is

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does the inference; this is everything around it |
| **Binaries** | `bin/jenova` — the desktop app. `bin/jenova-core` — the same program headless, for LAN. They link the same **non-GUI** modules; the split exists so a server host builds without GTK |
| **Build** | `nimble`. Tasks in `jenova_core.nimble`: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| **Architecture** | `BLUEPRINT.md` |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | `nimble suites` runs the **self-test subcommands** (from the `SelfTests` const in `jenova_core.nimble` — **read the names out of `src/jenova_core.nim`, never from a number written here**) and then the six shell suites under `tests/`. A failing assertion fails the run, and a suite that cannot run fails rather than skipping — **with one sanctioned exception: `test_nvimctl.sh` still skips when `nvim` is absent**, the USER's overrule, because `nvim` is not a build dependency of either binary. **Nothing tests the GUI — see §6.** |

## 2. State

**Verified 2026-09-03 by reading the source.** Both binaries build; the last recorded run of
every self-test and `bin/jenova --check` passed on 2026-09-02 12:19 and **nothing has changed the
code since**, so that record stands. Both binaries are ELF 64-bit FreeBSD executables.

**The backend is implemented and mostly covered.** The database, the threaded HTTP server, the
`/api/*` surface, the filesystem mirror, retrieval **and its feed**, the prompt pipeline, and model
discovery and switching all have assertions behind them. **Two named parts do not:** `config.load`
and its precedence chain have no self-test and no suite, and the watchdog's decision function
`lifecycle.watchOnce` — whose own docstring says it was separated from the loop *so it could be
tested* — is asserted nowhere.

**And the coverage those assertions represent is not what it looks like.** See §6 — it is the most
important thing on this page.

**The desktop application has the shape of the Web UI and a large part of its function**, plus a
substantial set of capabilities the Web UI never had. What it is missing is now enumerated properly
for the first time: **1,095 Web UI features** were catalogued on 2026-09-03 (`TODOS.md` A-59)
against the six-item scope list that had been carried since Session 010.

## 3. What happened in Session 023

**A three-part audit, commissioned by the USER. No code was changed and nothing was run.**

1. **Web UI ↔ GUI parity.** 1,095 features enumerated from `jca_web/src`; 866 parity verdicts
   produced across eight of nine areas. *(`data-services` was not reached then; it was read
   first-hand 2026-09-03 09:48 and resolves to three gaps — §4.)* 31 GUI capabilities beyond the
   Web UI catalogued.
2. **Every `.devdocs/` claim against the source.** 388 claims checked across all ten trackers.
   **212 TRUE, 87 STALE, 53 MISLEADING, 35 FALSE.** Corrected in this pass.
3. **Mechanism analysis.** Seven subsystems read end to end — GUI wiring and threading, memory,
   GPU and rendering, the data layer, retrieval and the pipeline, lifecycle and backends, and the
   structure of `gui.nim`. **64 findings, none refuted**, plus five coverage gaps the audit found
   in itself.

**Full narrative: `SESSION_HANDOFF.md`. The findings: `TODOS.md` A-series. The work: `PLANS.md`
Step 12.**

**Read `[V]` / `[A]` on every A-row before acting on it** (**D-CG**). Roughly a third were
confirmed first-hand this session; the rest are agent findings that survived a refutation attempt
and nothing more.

**`TODOS.md` A-67 is a traceability index** mapping each of the 64 sweep findings to its A-row, so
this file's coverage can be checked mechanically instead of trusted. It exists because **the first
pass dropped five findings** — recovered as A-61 … A-65 — and mis-stated A-52's severity. All 64
now resolve.

## 4. What is actually missing

**This section no longer carries a feature table.** It carried one for six sessions, it was
corrected three times — for PDF, for audio, for the trash view, and finally for the note editor —
and it was wrong again each time within a day. **That is rule 9, and the fix is to stop
re-deriving it here.**

**The list is `TODOS.md`.** The ordered plan is `PLANS.md`. The parity inventory is `TODOS.md`
A-59, and it supersedes every scope list this project has written.

> ### THE CURRENT WORK IS THE VERIFIED DEFECTS — `PLANS.md` **Step 12c…12f**. The parity backlog is next, not now.
>
> **Changed 2026-09-03 11:40 and this line has moved twice today, so read the dates.** The parity
> backlog (`TODOS.md` **A-59**, `PLANS.md` **Step 13**) was chosen by the USER at 09:10 and was the
> current work until **D-CI**, at which point the USER chose the defects instead. **A-59 is not
> cancelled and is explicitly next** — D-CI says so in its own text.
>
> **Two orderings are live, both given by the USER, in two different terminals** (§0a):
>
> - **D-CI** — `12e-1` (A-26, the note memo) → `12f-1` (A-17, the storage trash root) → `12e-2`
>   (A-48, markdown links) → `12f-2` (A-16/A-18, trash restore and a window surface) → `12d` (A-7,
>   the response cache), **12d last because it is the only one that touches `upstream.forward`'s
>   verbatim relay** and D-CD warns that wiring the writer without fixing the hit response makes
>   cached turns render blank.
> - **Step 12c** — A-3 and A-4, the two data-losing defects in the chat path. **In flight now**
>   (§0a) and **absent from D-CI's list**, which is a gap in the ordering rather than a decision
>   against it.
>
> **13a and 13b are BUILT (2026-09-03 10:21, `PROGRESS.md`).** The composer is a `DraftView`, so
> the six chat-form gaps behind the one-line `Entry` are closed together; and `data-services` is
> closed: markdown conversation export/import, forking a conversation, and the mirror's `pull` half,
> so an edit made in the embedded Neovim now comes back into the database.
>
> ### **13c cannot be picked up as written. Its work list does not exist.**
>
> **Verified 2026-09-03 by search, and this is the single most useful thing on this page for
> whoever takes 13c.** `TODOS.md` A-59 says the 866 per-feature verdicts are "in the session
> record". **They are in no record.** The strings `views-dialogs`, `models-server` and
> `sidebar-workspace` occur **nine times in the whole of `.devdocs/`**, every one inside A-59's own
> nine-row summary table or the sentence telling you to start with them. Session 023's verdicts
> were produced by agents, counted, and never written down.
>
> **So 13c's first unit is re-deriving one area's inventory from `jca_web/src` directly** — not
> looking a list up, not verifying rows that exist. Budget for that before scoping anything, and do
> the largest three by count (`views-dialogs` 65, `models-server` 61, `sidebar-workspace` 47)
> **for root causes**: both 13a and 13b collapsed to one cause behind a column of rows, and that is
> the shape to expect.

**The shape of it, which does not rot:** the backend is largely finished and the outstanding work
is mostly in the window.

## 5. Known broken

**A-1 and A-2 were the two that outranked every feature gap. Both were built 2026-09-03 09:02**
(`PROGRESS.md`); `nimble suites` runs every self-test and a suite that cannot run fails,
**except `test_nvimctl.sh`, which the USER ruled must keep skipping on a missing `nvim`.**
**T-12 went with them.** That pass also found `test_models.sh` asserting **pre-D-CB** behaviour —
red since 2026-09-02 10:43, invisible because Rule 0 stopped anyone running the suites. The
product was correct; the assertion was stale, and it is corrected.

**All remaining test and check work is deferred to last** — the USER's instruction, `TODOS.md`
**A-68**. The live work is `PLANS.md` Step 12c onward, below.

**A-69 is FIXED — 2026-09-03 11:38 (`PROGRESS.md`), and it is gone from `TODOS.md`.** Attaching a
file had never once been filed as a workspace artefact: `gui.fileAttachmentsAsArtefacts` minted the
`fileAssets` id with `$genOid()`, `fssync.physicalPath` refuses any id that is not a UUID, and
`api.upsert`'s mirror-failure branch deleted the row it had just written — so the user saw "could
not file … in the workspace" on every attachment and **G-44 / Step 10b had never worked, while
`PROGRESS.md` recorded it as built.** One call, `fssync.newUuid()`. **Unobserved: that the row now
survives is a USER screen run** — `gui.nim` links into no test binary and `--check` routes no
events, which is exactly how this shipped in the first place.

**Four of the high-severity defects were built on 2026-09-03 at 11:51 and are gone from
`TODOS.md`** (`PROGRESS.md`, Step 12c and Step 12e-1):

- **A-3** — attaching an image no longer drops the earlier conversation. `trimHistory` measures
  through `pipeline.messageWeight`, which charges an image part a flat `ImageContextBytes` rather
  than its base64 length.
- **A-4** — `MaxAttachmentBytes` is now *derived* from `http.MaxBodyBytes`, so the two caps cannot
  cross, and an oversized body is a **typed 413** drained before it is raised, classified
  `cekBadRequest` and not retryable.
- **A-5** — the context-used figure is `cacheN + promptN + predictedN`.
- **A-26** — the note memo has explicit O(1) invalidation at the two points the editor re-baselines.

**Still open and high severity:**

- **A-6 — the G-40 memos may still copy per frame.** `[A]`, and it needs a second read before it
  is believed. **It is the last of the original high-severity four.**

**Also verified and user-visible, still open:** markdown links and images are not rendered at all
(**A-48**, in flight as 12e-2); Copy is Wayland-only and swallows its failure (**A-27**); the trash
is write-only from the window (**A-16**–**A-18**, in flight as 12f — A-17's code is written and its
assertions are not); the documented `CANVAS=0` off-switch for the only continuous GPU load cannot
be triggered by any means (**A-25**).

**Still outstanding from before:** **G-47**, the editor page's Neovim truncated at the bottom on a
resize — **not diagnosed**, two candidates recorded, and not settleable without the running widget.
Two cosmetic Backlog items (G-37, G-38) and the G-51 widget constraint.

## 6. The coverage gap — now one gap, not two

**Half of this section is closed.** Every suite and every self-test exercises `jenova-core`, and
**`nimble suites` now executes every self-test** — read the list out of the `SelfTests` const in
`jenova_core.nimble`, never from a number written here — with a suite that cannot run reporting
failure. So "it is asserted in `X-selftest`" is a coverage claim again.

**What remains, and it is the durable half:**

- **`gui.nim` has no coverage of any kind.** Every GUI defect in this project's history was found
  by the USER looking at the screen. Nothing about 12a changes that — `gui.nim` links into no test
  binary.
- The behaviour deliberately pushed *below* the widget layer to be assertable —
  `workspace.contextFor`, `nvimctl.editorEnv`, `api.restoreEntity`, `pipeline.chatBody`, the whole
  of `settings.nim` — **is asserted, and those assertions now run.**

**The response is correct and should continue.** Moving behaviour below the widget layer is the
right design and it is why the audit could read this codebase at all.

**One thing not to mistake for coverage** (`TODOS.md` A-66): nobody has verified that a `check(...)`
inside the self-test bodies can actually *fail*. Roughly 900–1,100 lines were grep-sampled, never
read. Sound where sampled is not the same as proven to discriminate. **That is deferred with all
other test work under A-68** and is not to be picked up before the feature work is done.

## 7. Waiting on the USER

**Nothing is blocking. Q-37 is PARKED by the USER (2026-09-03 09:10) — do not re-raise it.**
It asked whether the desktop settings should govern a LAN request: `settings.applyTo` has one
caller, `pipeline.chatBody`, and the LAN path goes through `pipeline.prepare`, which takes no
`Settings`, so the sampling and penalty parameters apply only to bodies the window builds.
**Re-verified 2026-09-03 and it still holds.** It blocks nothing and is parked deliberately, not
forgotten. `TODOS.md` A-53.

**Four product decisions remain parked, none on the critical path:** Q-37 above, filesystem as the
source of truth (T-11), deployment (T-7), a CLI (T-8).

**Answered during this audit and not to be re-raised:** the `.devdocs/ARCHIVE/` deletion was the
USER's own and deliberate (**D-CE**); the response cache is a defect to fix rather than remove
(**D-CD**); `etc/jenova.local.conf` is the USER's in-use machine config and is out of scope
(**D-CF**).

## 8. Unobserved — awaiting a USER screen run

**A screen run is the USER's, when it suits them, and not something a session initiates or asks
after** (Rule 0). What remains unobserved rather than suspected:

0. **Step 13a's composer, after the 11:14 rebuild.** Three defects have been fixed across three
   runs — unclickable, a placeholder that never cleared, no autogrow — and **none of them was
   visible to any check this project can run.** What is unseen: clicking in, typing, Shift+Enter,
   wrapping, the growth and the 168px cap. The four new buttons — Fork on a conversation row, and
   the three in settings — are unseen with it. **`--check` cannot substitute for this:** it builds
   the tree and exits, allocating no sizes and routing no events, which is exactly how it passed a
   composer nobody could click, twice.

1. The note-header pin toggle and a FOCUS note written from the window turning up in a chat scoped
   to a different folder.
2. Session 015's recall against a **live** backend — everything was verified with the embedder
   down, so the semantic half of ranking on real embeddings is unproven.
3. Three settings behaviours needing a live generation: the transcript following a streaming reply,
   the code-block cap on a long answer, and the "Custom" badge which needs `/props` values.
4. A switched model actually loading into a restarted backend.
5. Four Adwaita icons that only appear on a branched or continuable turn — `view-refresh-symbolic`,
   `media-playback-start-symbolic`, `go-previous-symbolic`, `go-next-symbolic`.

## 9. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Language** | Nim only, plus `llama-server`. No shell, no Lua, no C, no Makefile in the product tree |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine. **The names are positional and nothing verifies the mapping** — see D-CE's note |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted (D-X). AGENTS.md Directive 2's "non-copyleft" clause is dead letter here and its operative clause — zero proprietary dependencies — is satisfied |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Retrieval** | Indexes chats (D-BD), fed per completed exchange (D-BI) |
| **Settings** | 1:1 with the Web UI's minus API Key, MCP and `serverUrl` (D-BL) — **re-verified 2026-09-03 against what the Web UI actually draws**, and the claim holds: 47 drawn keys, 41 implemented, the six absent being those three plus four MCP/agentic fields. `OmittedFields` names three of the seven and should name all seven (A-31) |
| **Unused files** | Remove from the product tree; **git history is the archive** (D-AM as amended by **D-CE**) |
| **MCP** | Deferred by the USER. Largest thing in the Web UI — do not pick it up casually |
| **Audio in/out** | Not needed, not gated, not to be raised again (D-BZ). The `input_audio` *send* path stays under Directive 3 |
| **Virtual file explorer** | Cancelled by the USER (D-AW). The Neovim page is the browser |
| **`jca_web`** | Frozen (D-Z). Read it to establish parity; never edit it |
| **`etc/jenova.local.conf`** | The USER's machine file, in use. Never edited, and its divergence from the shipped profile is not a finding (**D-CF**) |
