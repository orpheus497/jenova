# BRIEFING

**Last updated:** 2026-09-01 10:17 (Session 014)
**Branch:** `bsd`

---

## 0. READ THIS BEFORE DOING ANYTHING

Every rule below exists because it was broken, repeatedly, and cost the USER a day.

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run** — and **never deny what plainly was run.** Both halves are the rule. If it was not executed, say "I don't know". If the USER says they ran it, they ran it. |
| **2** | **This is a Nim program using `llama-server`. That is all it is.** No shell scripts, no Lua, no C, no Makefile. Build with `nimble`. |
| **3** | **The archived old build is not work.** A broken reference to an archived file is fixed by **deleting the reference or porting it to Nim** — never by repairing it, and never by asking the USER which (**D-AZ**). Both options sit inside the standing ruling. |
| **3b** | **Everything is driven from the GUI** (**D-BC**). Anything needing a terminal, a shell script or a hand-edited file is a defect. |
| **4** | **Explain in plain English, then cite the ID.** "G-23 needs resolving" communicates nothing. Say what it is, then give the reference (**D-BA**). |
| **5** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Check the stdlib and the codebase first — including whether the API route you are about to write is already implemented and tested, because repeatedly it was. |
| **6** | **Do not rebuild old patterns.** The two-command split was rebuilt after the USER killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **7** | **Comments only where the code is not self-explanatory.** No essays above functions. Do not retroactively "improve" existing comments. |
| **8** | **Do not ask what has been answered.** `DECISIONS_LOG.md` SETTLED FACTS and its QUESTION STATUS index, first. |
| **9** | **Do not write derivable facts into these documents.** Counts and file lists rot. Point at the code. |
| **10** | **Re-check a tracker's claims against the code; do not carry them forward.** Session 013 found seven false claims in these documents, one repeated across five files. |
| **11** | **Verify a scope list against the source, not against a summary.** The "GUI parity" list carried since Session 010 named six items. The Web UI's own component listing has roughly three times that. |
| **12** | **A "not yet run" label is not durable.** It survives exactly until any evidence contradicts it — a screenshot, a defect report, or the USER saying so. Carrying it past that point has now cost two sessions. |
| **13** | **A new assertion is not believed until it has been seen to go red.** Step 1's were run against the unfixed source and produced 12 failures before they were trusted. Two suites in this project have reported PASS while asserting nothing. |

---

## 1. What this is

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does the inference; this is everything around it |
| **Binaries** | `bin/jenova` — the desktop app. `bin/jenova-core` — the same program headless, for LAN. Both link the same modules; the split exists so a server host builds without GTK |
| **Build** | `nimble`. Tasks in `jenova_core.nimble`: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| **Architecture** | `BLUEPRINT.md` |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | **Six** shell suites under `tests/`, run by `nimble suites`, plus **five** self-test subcommands in `jenova-core` (`db-`, `serve-`, `rag-`, `pipeline-`, `sha256-selftest`). **None of them covers the GUI** — see §5 |

## 2. State

**Verified as of 2026-09-01 10:17.** Both binaries build from a clean run of
`nimble core` and `nimble gui`; the FreeBSD-only guard was confirmed to still *fire*
when the target is changed, not merely to exist; **all six suites and all five
self-tests pass.** `bin/jenova-core` is an ELF 64-bit FreeBSD executable.

**One qualification, and it is not a product fault.** **Run `nimble suites` with
`bin/jenova` closed.** Two suites assume nothing is listening on the machine's real
ports: `test_routes` expects a 502 meaning "no `llama-server` answered" while talking to
the real backend on 8081, and `test_lifecycle` runs `backends health` and `backends
start` with no port override, so the product's correct *"port 8081 is already in use"*
refusal reads as a failure. Given a dead upstream port `test_routes` passes 13/13 with
the app still running. **This is T-12's unknown trigger, identified after two sessions.**
Fix filed in `TODOS.md` Backlog. Separately, invoke the suites through `nimble suites`,
not by calling the scripts — `test_nvimctl.sh` needs `nim` on `PATH` and only `nimble`
puts it there.

**The 2026-08-31 23:28 build was run by the USER**, and no appearance or rendering
defect came back from it. The report from that run is that the GUI is missing a large
number of Web UI features, which is why the outstanding work is **functional, not
visual**. Do not re-add an "unrun" label to those features.

**The backend is in good shape.** Configuration, database, threaded HTTP server, the
whole `/api/*` surface, the filesystem mirror, retrieval, the prompt pipeline, backend
supervision and watchdog, model discovery and switching are implemented and covered by
tests.

## 3. Done this session — two plan steps

### Step 2 — a message carries its actions again (G-28)

**Once a message was sent there was nothing you could do to it.** One copy button, on
code blocks, was the whole of it. It now has **copy, edit, delete, regenerate and
continue.**

The change everything else rested on was not a button: **`Message` had no row id.** It
carried a role and a string, so there was nothing to edit or delete even if a button
existed. `saveMessage` now returns the row it wrote and `loadMessages` selects it.

**Two things are deliberately held back until branching exists (D-BF), and they are
Step 3's job:** edit **does not resend**, and regenerate and continue are offered on the
**last message only**. Both are the same restriction — re-answering a turn that has turns
after it produces an alternative version of all of them, and without the tree that
destroys them rather than offering a choice.

### Step 1 — the file mirror no longer lies

**Renaming a workspace, project or folder used to strand every file underneath it.**
Paths on disk are built from ancestors' *names*, and nothing moved the directory — so
the old tree was orphaned and the next save landed in a fresh empty one beside it. That
mattered because the Neovim page rooted at the workspaces directory **is** the file
browser (D-AW): the tree is the interface, and it told the truth only until the first
rename.

It now moves the directory, and everything under it travels with it. A move that cannot
be done rolls the database write back. A rename onto an already-occupied path is
**refused rather than merged**, because a merge has no undo and a refusal does
(**D-BE**). The GUI shows the refusal instead of discarding it.

Detail for both steps is in `PROGRESS.md`; the assertions and the red-proofs are
`TESTS.md` §0b (renames) and §0c (message actions).

## 4. What is actually missing — the honest list

**The desktop application has the shape of the Web UI and not its function.** Chat,
sidebar, workspace tree, notes, theme, canvas, syntax highlighting and the embedded
Neovim page all work. Almost everything you do *to* a message does not exist.

| Works | Missing entirely |
|---|---|
| Send a message, stream a reply | **Branching** — alternative versions of an answer (G-29) |
| **Copy, edit, delete, regenerate, continue a message** | **Attachments** of any kind — image, text, PDF, audio (G-30) |
| Conversations: create, rename, delete, search | **Tables, task lists, LaTeX maths** (G-34) |
| Workspace / project / folder tree, notes — **and renaming one now keeps its files** | **Any settings screen — so no temperature, top_p, top_k, penalties** (G-31) |
| Markdown text and highlighted code blocks | **Tables, task lists, LaTeX maths** (G-34) |
| Theme, canvas, glass panel, wordmark | **Any settings screen — so no temperature, top_p, top_k, penalties** (G-31) |
| Neovim page + AI reads the live buffer | **Import / export of conversations** (G-32) |
| Tray, LAN toggle, backend start/stop | **Generation statistics, and a stop button** (G-33) |
| Two hardcoded model-switch menu items | **A real model selector and model information** (G-20) |
| One line of grey status text | **Typed errors, retry, context-overflow reporting** (G-35) |
| — | **Trash view** (G-21), **delete confirmations** (G-36), **a real note editor** (G-17) |
| — | **Hardware profile detection and selection** — currently impossible from anywhere (S-1) |
| — | **Recall of past chats** — the search engine is built and starved (T-17) |

**Almost all of it is GUI work over a backend that is already finished and tested** —
the message-update route, the recursive fork cascade, `/api/db/import`, the trash
routes and `models.switchModel` all exist with assertions behind them.

Full detail with mechanisms and line references: `TODOS.md`. Ordered plan: `PLANS.md`.

## 5. Known broken in the Nim code

Six items, each verified by reading the file it names (`TODOS.md`). **T-14 is no longer
among them** — it was fixed this session. The one that matters:

- **Nothing populates the search index** (T-17), so the AI has no recall of past chats.
  The search half is finished and proven; the indexer half was never written. **Scope is
  decided — it indexes chats** (D-BD), and it is Step 4.

Separately, **there is currently no way to detect hardware or change profile at all**
(S-1). It was two shell scripts and both are broken by subtraction. It becomes Nim with
a GUI screen (D-BC), Step 6.

The rest — a leaked embedding server on exit, an unbounded statement cache, two holes
in the file-containment check, untrimmed chat history — are real but not urgent, and are
Step 9.

Two cosmetic defects are newly filed in the `TODOS.md` **Backlog**: two dead style rules
in `theme.nim`, one of which is G-8's defect recurring in the same file, and a code
comment in `gui.nim` describing a `Paned` that was never used.

## 6. The gap nobody has recorded: the GUI has no test coverage

All six suites and all five self-tests exercise `jenova-core` — routes, database,
filesystem, lifecycle, models, and the Neovim buffer reader. **Nothing tests `gui.nim`
at all.** Every GUI defect in this project's history was found by the USER looking at
the screen.

That is tolerable for layout and is not tolerable for the work in §4, which is mostly
*logic* — branching, message editing, parameter passing. **Each step in `PLANS.md`
names what would prove it worked**, and where that can be a suite it should be one.

## 7. Waiting on the USER

**Nothing in the plan is blocked.** Three product decisions remain parked, none on the
critical path: filesystem as the source of truth (T-11), deployment (T-7), a CLI (T-8).

## 8. Next

**`PLANS.md` Step 3 — conversation branching** (G-29). Editing or regenerating a turn
produces an *alternative version* of it, and the Web UI moves between versions with
prev/next arrows and a counter. **The backend already models the fork tree and is
asserted;** the GUI holds a flat `seq[Message]` and cannot represent a branch, so this is
a state-shape change first and widgets second.

**Step 2 did the first half of it:** every message now carries its row id, which is the
identity a sibling lookup needs. And Step 3 has two callers already waiting — it is what
lets edit resend, and what lets regenerate work anywhere but the last message (D-BF).

## 9. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Language** | Nim only, plus `llama-server`. No shell, no Lua, no C, no Makefile |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Unused files** | Archive to `.devdocs/ARCHIVE/`, never delete, never leave in the root |
| **MCP** | Deferred by the USER. Largest thing in the Web UI — do not pick it up casually |
| **Virtual file explorer** | Cancelled by the USER (D-AW). The Neovim page is the browser |
| **`jca_web`** | Frozen (D-Z). Read it to establish parity; never edit it |
