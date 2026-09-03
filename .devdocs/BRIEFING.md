# BRIEFING

**Last updated:** 2026-09-03 11:24 (Session 025)
**Branch:** `bsd`, at **`9fc9ecc7`** ("Docupdates") **with Session 025's work uncommitted.**
**Step 13a and 13b are built.** **13a's composer was rebuilt at 11:14 as `DraftView`** after two
failed repairs from the USER's screen, and **a SIGBUS on Enter was fixed at 11:24** — an event
handler bound in `afterBuild` held a pointer freed on the first redraw. All of it is in
`PROGRESS.md`, with the five toolkit traps collected in `PLANS.md` Step 13a. Two new modules
(`composer.nim`, `convmd.nim`), and `gui.nim`, `api.nim`, `fssync.nim`, `theme.nim`,
`jenova_core.nim` and `jenova_core.nimble` changed. **All sixteen self-tests pass, both binaries
build, `bin/jenova --check` exits 0.** `jvim/` is tracked on purpose and `.gitignore` says so.

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
| **18** | **REPLACED 2026-09-03 09:02 — the suites now mean something, and test work is now LAST.** This rule said a green build proved nothing because `nimble suites` ran no self-tests and four of six passed when they could not run. **A-1 and A-2 are built** — all fourteen self-tests run and a suite that cannot run fails. **The rule that replaces it is the USER's instruction of 09:05 (`TODOS.md` A-68): test and check work is left until last.** A red suite met while doing feature work is not a work item — record nothing, say nothing, carry on, exactly as Rule 0 already directs. Do not open a session with test bookkeeping. |

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

> ### THE CURRENT WORK IS THE PARITY BACKLOG — `TODOS.md` **A-59**, scoped as `PLANS.md` **Step 13**.
>
> Chosen by the USER 2026-09-03 09:10. **1,095 Web UI features enumerated.** It is the largest body
> of work in the project and it is what "the GUI is missing Web UI features" actually means.
>
> **13a and 13b are BUILT (2026-09-03 10:21, `PROGRESS.md`).** The composer is a `TextView`, so the
> six chat-form gaps behind the one-line `Entry` are closed together; and `data-services` — the
> area that had no verdicts at all until it was read first-hand — is closed: markdown conversation
> export/import, forking a conversation, and the mirror's `pull` half, so an edit made in the
> embedded Neovim now comes back into the database.
>
> **What is left is 13c: the other eight areas' 866 verdicts, and they are leads, not facts**
> (**D-CG**) — one agent each, no adversarial re-check. Verify a row against the source before
> scoping it. **And remember "Missing" is not a feature count:** both items built today turned out
> to be a single root cause behind a column of rows, which is the shape to expect from the rest.
>
> **Step 12c…12f are not cancelled** — they are the verified defects and they sit behind this.

**The shape of it, which does not rot:** the backend is largely finished and the outstanding work
is mostly in the window.

## 5. Known broken

**A-1 and A-2 were the two that outranked every feature gap. Both were built 2026-09-03 09:02**
(`PROGRESS.md`); `nimble suites` runs all fourteen self-tests and a suite that cannot run fails,
**except `test_nvimctl.sh`, which the USER ruled must keep skipping on a missing `nvim`.**
**T-12 went with them.** That pass also found `test_models.sh` asserting **pre-D-CB** behaviour —
red since 2026-09-02 10:43, invisible because Rule 0 stopped anyone running the suites. The
product was correct; the assertion was stale, and it is corrected.

**All remaining test and check work is deferred to last** — the USER's instruction, `TODOS.md`
**A-68**. The live work is `PLANS.md` Step 12c onward, below.

**One more, found 2026-09-03 while building Step 13b and verified by reading both halves —
`TODOS.md` A-69:** **attaching a file has never filed it as a workspace artefact.**
`gui.fileAttachmentsAsArtefacts` mints the `fileAssets` id with `$genOid()`, `fssync.physicalPath`
refuses any id that is not a UUID, and `api.upsert`'s mirror-failure branch then deletes the row it
just wrote — so the user sees "could not file … in the workspace" on every attachment and G-44 /
Step 10b has never worked. **The fix is one call** (`fssync.newUuid()`), and the same trap is
already documented in a comment eleven lines above it.

**Four high-severity code defects, all verified by reading the source — and all re-verified
2026-09-03 09:00 against the current tree:**

- **A-3 — attaching an image silently deletes the earlier conversation** from what the model is
  sent. `pipeline.trimHistory` measures the full JSON serialisation including the base64 payload,
  against a budget of a few kilobytes.
- **A-4 — a 24–25 MiB attachment produces an untyped 500.** The 25 MiB attachment cap is checked
  before base64; the 32 MiB body cap after. They cross at 24 MiB, and the result is the
  undiagnosable grey line G-35 exists to prevent.
- **A-5 — the context-used figure omits the cached prefix**, so it under-reports without bound
  exactly as a conversation gets long. The Web UI computes it correctly, so this is also a parity
  divergence.
- **A-6 — the G-40 memos may still copy per frame.** `[A]`, and it needs a second read before it
  is believed.

**Also verified and user-visible:** a note edit that preserves character count renders as the old
text (**A-26**); markdown links and images are not rendered at all (**A-48**); Copy is Wayland-only
and swallows its failure (**A-27**); the trash is write-only from the window (**A-16**–**A-18**);
the documented `CANVAS=0` off-switch for the only continuous GPU load cannot be triggered by any
means (**A-25**).

**Still outstanding from before:** **G-47**, the editor page's Neovim truncated at the bottom on a
resize — **not diagnosed**, two candidates recorded, and not settleable without the running widget.
Two cosmetic Backlog items (G-37, G-38) and the G-51 widget constraint.

## 6. The coverage gap — now one gap, not two

**Half of this section is closed.** Every suite and every self-test exercises `jenova-core`, and
**`nimble suites` now executes all fourteen self-tests**, with a suite that cannot run reporting
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
