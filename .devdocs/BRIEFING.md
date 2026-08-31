# BRIEFING

**Last updated:** 2026-08-31 15:49
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

| | |
|---|---|
| **SIGBUS on redraw** | Crashed after ~90 s with the user typing. Backtrace: `gtk_widget_set_margin_top` inside owlkettle's diff, from a timer calling `redraw`. **Cause: conditionally-present sibling widgets** in `view` — owlkettle matches Box children positionally, so a Label that appears and disappears shifts the rest. **The fix is in the source and compiled into `bin/jenova`; it has NOT been run.** Core dumps land in `/var/coredumps/`; `gdb -batch -ex "bt 25" ./bin/jenova <core>` gives the trace |

## 4. Outstanding

**`TODOS.md` T-1 … T-10 is the complete list. All ten were re-verified against the tree on
2026-08-31 and all ten hold; no new defect was found.** The sequenced plan is `PLANS.md`:

1. **Stabilise** — T-1 … T-5. T-1 is the only blocker and the work on it is *to run it*.
2. **The `jca_web` workspace question** — a product decision (T-6).
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
