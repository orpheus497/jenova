# BRIEFING

**Last updated:** 2026-08-31 18:19
**Branch:** `bsd`

---

## 0. READ THIS BEFORE DOING ANYTHING

Every rule below exists because it was broken, repeatedly, and cost the USER a day.

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run.** "The tray works", "the UI freezes", "this will break" — all asserted without testing, all wrong or unknown. If it was not executed, say "I don't know". |
| **2** | **This is a Nim program. It has no Makefile and no shell scripts.** Build with `nimble`. Do not write, repair, or discuss shell scripts, installers or Makefiles. They are archived. |
| **3** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Before writing a parser, client or helper, check whether the codebase or the stdlib already has one. |
| **4** | **Do not rebuild old patterns.** The two-command split (server started separately from the app) was rebuilt after the USER had already killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **5** | **Anything not in use goes to `.devdocs/ARCHIVE/`.** Not deleted, not left lying in the root. |
| **6** | **Comments: only where the code is not self-explanatory.** `AGENTS.md` forbids retroactive comment editing. Do not write essays above functions. Do not "improve" existing comments. |
| **7** | **Do not ask what has been answered.** Check `DECISIONS_LOG.md` SETTLED FACTS first. The Vulkan2 device list and "the app starts its own server" were each re-raised after being settled. |
| **8** | **Do not write derivable facts into these documents.** Counts, file lists and subcommand lists rot immediately and cause the doc-churn loop. Point at the code. |
| **9** | **A tracker that names a file must be re-read when that file is archived.** `BLUEPRINT.md` described `proxy.lua` and `jenova-ca` for three sessions after they were deleted, while being the file `AGENTS.md` calls authoritative (**D-AO**). A stale document does not sit inert — it manufactures work. |

---

## 1. State

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does inference; this is the harness around it |
| **Binaries** | `bin/jenova` — the desktop app (window, tray, chat, backend control). `bin/jenova-core` — headless server. Both link the same modules; the split exists so a LAN/server host builds without GTK |
| **Build** | `nimble`. Tasks are in `jenova_core.nimble`. **No Makefile** |
| **Architecture** | `BLUEPRINT.md` — rewritten 2026-08-31 and current. The pre-rewrite audit record is `ARCHIVE/devdocs/BLUEPRINT_pre-007.md` and is **history, not requirements** |
| **Language purity** | No Lua. No C. No shell script in the product tree except `hardware-profiles/`'s profile-selection tooling, which is setup-time data handling |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | Five suites under `tests/`, run by `nimble suites`. Reported passing at Session 006; **not re-run since** |

## 2. Verified working, by running it *(Session 006 — not re-run since)*

- `bin/jenova` starts, opens the window, and registers the tray icon.
- It starts the HTTP server and both backends itself — one command, no separate `serve`.
- The embedding server comes up on `:8082`.
- The agent `llama-server` comes up on `:8081` **now that `Vulkan2` is out of `etc/jenova.local.conf`** — it was rejecting the whole `-dev` argument and dying instantly.
- Conversations persist to the `conversations`/`messages` tables and reload at startup.
- Clean exit: both worker threads join, no hang.

## 3. Known broken

**Nothing is known broken.** This section previously asserted a redraw SIGBUS as the blocking
defect. **It was corrected on 2026-08-31 and the correction is the more useful entry:**

| | |
|---|---|
| **The "redraw SIGBUS"** | **Not established.** One core exists (`/var/coredumps/jenova.66331.1001.core`, from `./bin/jenova`, **15:26** — before the 15:44 rebuild), **and its signal is unknown**: no debugger here reads a FreeBSD core, and that binary no longer exists. "SIGBUS", "~90 s while typing" and the `gtk_widget_set_margin_top` frame had **no artifact behind them**. The stated cause is contradicted by `owlkettle/widgets.nim:243`, where a type mismatch at a child index is a **handled** remove-and-reinsert, not a bad write. **The USER ran the current build for 1:41.78 on 2026-08-31 and it exited cleanly on Ctrl-C, producing no core.** See `TODOS.md` T-1 |

**This is rule 1 catching a live example, and it was caught by the USER, not by me** — I read the
claim in these documents and repeated it as fact without checking the evidence. **A tracker entry is
not evidence. Check the artifact.**

## 3a. The live workstream — GUI parity (D-AP)

The GUI is the product; `jca_web` becomes the ephemeral single-device LAN client. **Done and run:**
theme, canvas. **Built, unrun:** side panel, workspace tree, markdown/code blocks. **Missing:**
notes and fileAssets in the tree, syntax highlighting, models selector, settings, attachments, MCP.

**Read D-AR before touching `gui.nim`.** Four rounds shipped a broken window because a scripted bulk
edit was followed by a compile and nothing else. **`nimble gui` exiting 0 says the widget tree is
valid, never that it is right**, and one such edit inserted a wrapper without re-indenting its body
— the panel rendered as five columns and compiled cleanly. Layout changes go through the harness's
edit tooling as one block, read back before building.

**Sizing APIs are minimums.** `min-width`, `sizeRequest` and the flap's `width` were each reached
for as if they capped something. To make a `Picture` small, decode it small.

**`Box`'s adder defaults to `expand: true`**, and `insert(...)` inherits that default. `hexpand`
propagates **up** the tree, so one greedy button makes the whole panel greedy.

## 4. Outstanding

**`TODOS.md` T-1 … T-10 is the complete list. All ten were re-verified against the tree on
2026-08-31 and all ten hold; no new defect was found.** The sequenced plan is `PLANS.md`:

0. **GUI parity (G-1 … G-7)** — the live workstream, §3a. Everything below is queued behind it.
1. **Stabilise** — T-2 … T-5. **Nothing blocks**; T-1 is unexplained, not a gate.
2. ~~The `jca_web` workspace question~~ — **answered by D-AP**; it is the GUI parity work.
3. **Deployment** — one decision, taken once (T-7).
4. **CLI** — after the above (T-8).

Independent of all four: profile data hygiene, T-9 and T-10.

**Explicitly not work:** the archived shell tree. It is gone, not pending.

## 5. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Unused files** | Archive to `.devdocs/ARCHIVE/`, never delete, never leave in the root |
