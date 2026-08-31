# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-08-31 21:14

---

## Where the program is

A native FreeBSD desktop application in Nim. `llama-server` is the engine; this is the harness.
`bin/jenova` is the app, `bin/jenova-core` the headless server. Build with `nimble`. Architecture
is `BLUEPRINT.md` (rewritten 2026-08-31; the pre-rewrite audit record is archived).

**Done:** config, database, threaded HTTP server, the `/api/*` surface, filesystem mirror, RAG, the
completion pipeline, backend lifecycle and watchdog, model discovery and switching, the GTK4 window,
the StatusNotifierItem tray, conversation persistence. No Lua, no C, no shell scripts.

**Verified 2026-08-31 (Session 007) by reading every file the trackers name:** T-1 … T-10 are the
complete and accurate outstanding set. **No new defect was found.** Cross-referencing the trackers
against the tree produced corrections to three *documents* and none to the code inventory — which
is the first time that has been true, and it is the point of the exercise.

---

## The live workstream — GUI parity (D-AP)

**This is what is actually being built.** The USER's direction, 2026-08-31: the GUI becomes the
product; `jca_web` becomes the ephemeral single-device LAN client. **This closed T-6**, and it
re-ordered everything below — the four stages that follow are still correct, but stage 1 is no
longer the front of the queue.

| | State |
|---|---|
| G-1/G-2 theme + canvas | **Done, run, confirmed** |
| G-3 side panel, G-3b rename/delete | **Done** |
| ~~G-4 workspace tree~~ | **DONE — run and confirmed by the USER 19:38.** Panel, tree and notes work |
| ~~G-5 markdown + code blocks~~ | **Done and confirmed 18:55.** No syntax highlighting (G-7) |
| ~~G-6 remaining surface~~ | **Retired 20:10 — triaged into G-16 … G-21 by the USER's scope call (D-AT):** filesystem view/browser, writer/editor, **file awareness**, **Neovim in a tab**, models selector, trash view. **MCP DEFERRED** — it was the only item that is a subsystem rather than a view, and it is out |
| ~~T-1 — the SIGBUS~~ | **CLOSED 20:52, confirmed by a completed run.** It was the **Quit path**: `closeWindow()` then `redraw()` in the same timer callback. **Eleven cores, six wrong hypotheses, and the USER diagnosed it.** Record in `PROGRESS.md` 20:43/20:52 |
| ~~G-7 syntax highlighting~~ | **DONE — `sourceview.nim`, a hand-written gtksourceview-5 binding. Run and confirmed 20:52** |
| ~~G-13c~~ | **DONE.** Fullscreen had no exit; fixed 19:39, confirmed 20:52. **Now redundant** — the top bar survives fullscreen since the `AdwWindow` change, so the bottom-row control is a second exit rather than the only one. Kept: it costs nothing |
| ~~Top bar in fullscreen~~ | **DONE 20:49, confirmed 20:52.** `Window` + `gtk_window_set_titlebar` → **`AdwWindow`** with the bar extracted into `proc topBar` and inserted atop the chat column. **Given up and stated:** `AdwWindow` has no `title` field, so the WM/taskbar title may be empty |
| ~~T-13~~ | **DONE in source 20:56, UNRUN.** Renaming a file asset wrote a zero-byte file over it and wiped its metadata; the rename now resends `content`/`size`/`type`/`uploadDate` as the notes branch already did |
| ~~G-8 … G-11~~ | **CLOSED 18:55 — fixed and confirmed on screen.** Panel slab, unstyled tree, one-word wordmark, collapsing code blocks. Record in `PROGRESS.md` 18:42/18:55 |
| ~~G-12, G-13a~~ | **DONE — in the 19:23 build the USER confirmed at 19:38** |
| ~~G-14, G-15~~ | **DONE — note creation and nested-container visibility, confirmed working 19:38** |
| ~~G-13b~~ | **DEFERRED by the USER 19:11 — suspected compositor, not the program.** Not work unless identified |

**How this work goes wrong, and the rule that came out of it (D-AR).** Four consecutive rounds
shipped a broken window because a scripted bulk edit was followed by `nimble gui` and nothing else.
**A compile proves the tree is valid, never that it is right.** Layout changes are rewritten as a
block through the harness's edit tooling, read back, and the widget tree shown before building.
Sizing APIs (`min-width`, `sizeRequest`, flap `width`) are **minimums** — check the semantics before
reaching for one.

**LAN gets no further investment.** Built, works, retained under Directive 3.

---

## G-19 / G-18 — Neovim in a tab, and file awareness *(scoped 2026-08-31 20:58)*

**Ruling D-AT.** The USER: *"neovim integration with a tab that has neovim running with the ai able
to read the active document."*

### The mechanism is PROVEN, by running it — and it needs no msgpack client

The obvious design was a Nim **msgpack-RPC client** against `nvim --listen`. **It is not needed.**
`nvim --server <sock> --remote-expr <vimscript>` prints the result on stdout, and Neovim ships it.
Directive 3 — *do not reinvent what exists* — and it matches how the program already invokes
installed binaries (`wl-copy` in `copyToClipboard`; `git`, `fetch`, `xdg-open`).

**Executed 2026-08-31 20:57 against a real `nvim --headless --listen`, output verbatim:**

| Query | Result | Gives us |
|---|---|---|
| `expand("%:p")` | `/…/sample.txt` | the active document's path |
| `join(getline(1,"$"),"\n")` | `line one\nline two\nline three` | **the buffer, including unsaved edits** |
| `line(".")` | `1` | cursor position, for "what am I looking at" |
| `&modified` | `0` | whether disk and buffer agree |
| `&filetype` | `text` | **feeds `sourceview.nim`'s language directly** |

**The buffer query is the whole point of G-18:** the AI reads *what is on screen*, not what was last
saved to disk.

### A constraint found by running it, not by reading

**The socket path must be short.** `nvim --headless --listen <108-char path>` fails with
`Failed to --listen: invalid argument` — FreeBSD's `sun_path` is ~104 bytes. **`$HOME/Jenova/state/`
is well inside that**; a scratch path under `/tmp/claude-…` was not. Any future "it works on my
machine" here is this.

### Steps

| Step | Item | Shape of the work | Proof it worked |
|---|---|---|---|
| **19.1** | **`vte.nim` — the terminal widget** | Hand-written `vte-2.91-gtk4` FFI, **exactly the shape of `sourceview.nim`**: flags from `staticExec("pkg-config …")`, a small Nim surface, and the `renderable` declared in `gui.nim` because owlkettle's macro emits an unexported type. **`vte-2.91-gtk4 0.80.5` is installed — checked, not assumed.** LGPL, permitted under D-X | `nm -u bin/jenova` shows the `vte_*` symbols and the link resolves |
| **19.2** | **Spawn `nvim` in it** | `vte_terminal_spawn_async` with `nvim --listen $JENOVA_STATE/nvim.sock`. **Short path — see above.** The USER's own config and plugins load, which is the entire reason for hosting a real `nvim` rather than rendering a UI ourselves | The tab shows a working Neovim the USER can edit in |
| **19.3** | **The tab itself** | A new pane in the chat column beside the transcript and the note editor. **Child types stay stable** — that constraint is already recorded for this column | Switching tabs does not disturb the transcript |
| ~~**18.1**~~ | **DONE 21:03, RUN.** `src/jenova/nvimctl.nim`, with `tests/test_nvimctl.sh` + `tests/nvimctl_check.nim` wired into `nimble suites`. **5 passed, 0 failed.** The suite runs its assertions twice — clean, then after editing the buffer **without saving** — and **the interim run went red**, which proves both that the checks assert something and that the reader returns the *buffer*, not the file on disk | **Done.** Skips cleanly with no `nvim` installed |
| ~~**18.2**~~ | **DONE 21:14, RUN.** New `Editor:` intent prefix — the existing gating mechanism, so it works from the GUI, the Web UI and any client with no UI work. `prompts.Editor` tells the model the buffer may differ from disk. Both binaries build; `pipeline.configureEditor` wired into both entry points | **9/9 checks pass**, including **"no prefix → buffer NOT leaked"** — the gate is asserted, not assumed |

**Sequencing:** 19.1 is the only risky step (a new C dependency and the program's second FFI). 18.1
is independent of all of it — **it works against any `nvim --listen`, including one the USER already
has running** — so it can be built and proven before the terminal widget exists.

**Not in scope:** writing *back* into the buffer from the AI. Reading is what was asked for.

---

## The standing plan

Four stages. **They are ordered by dependency, not by preference**, and stages 2–4 each open with a
decision that is the USER's to make. A session does not start stage 2 by choosing for them.

### Stage 1 — Make it stable *(actionable now; no decision required)*

`TODOS.md` **T-2 … T-5**. A session can execute all of it unaided. **Nothing blocks it** — T-1 was
corrected on 2026-08-31 and is an unexplained core, not a gate.

| Step | Item | Shape of the work | Proof it worked |
|---|---|---|---|
| **1.1** | **T-1 — the SIGBUS.** **Diagnosed and fixed in source 20:10; UNRUN** | **The writing is done; the running is not.** Two fixes are in: the frame clock repaints the canvas alone instead of diffing the whole tree, and the GUI builds `--mm:arc` so ORC stops collecting owlkettle's `state → event → state` cycles under GTK (**D-AS**). **Exercise the paths that produced the cores** — fullscreen, F11, opening and closing notes | **No new core** after a session that includes fullscreen and note toggling. If one appears, it is now readable: `gdb -batch -ex "bt 25" bin/jenova /var/coredumps/<core>` |
| **1.2** | **T-5 — backends survive exit** | `gui.run`'s `defer` joins the worker threads and stops nothing. Leaving the *agent* loaded is deliberate — reloading multiple gigabytes into VRAM on every restart is worse — but the **embedding** server is left with nothing attached, and a backend that dies during start leaves its pidfile behind. Fix: stop the embed backend on exit; clear a pidfile whose process is not alive | `jenova-core backends status` after a GUI exit reports the agent up, embeddings down, and no stale pid |
| **1.3** | **T-2 — unbounded statement cache** | `db.nim`'s cache is a plain `Table` and finalizes only at connection close, while `api.nim`'s message update builds its `SET` clause from whichever fields the client sends. Distinct SQL accumulates without bound. **The fix belongs in `db.nim` — a cap plus finalize-on-evict — not in `api.nim`**; constraining the caller leaves the cache still unbounded for the next caller | A new suite that issues many distinct field combinations and asserts the cache stays capped. **It must be proven able to fail** before it is believed |
| **1.4** | **T-4 — `resolveStoragePath` containment** | Two directions, one fix. The symlink check is gated on `fileExists or dirExists`, so a **new** file written through a symlinked parent escapes the root; and `normBase` is lexical, so a symlinked `$JENOVA_WORKSPACES` makes the check reject **legitimate** paths. Resolve the deepest existing ancestor and compare against a resolved base | Extend `test_api_fs.sh`: a write through a symlinked parent is refused **403**, and a legitimate write under a symlinked root succeeds |
| **1.5** | **T-3 — chat history is never trimmed** | The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE`, dropping oldest-first and never dropping the system message | A unit check on the trim function at a small budget; not a live generation |

**Sequencing note.** 1.2–1.5 are independent of each other and of 1.1, and all four are queued
behind the GUI parity workstream above.

### Stage 2 — The workspace question — **ANSWERED, and now the live workstream**

`TODOS.md` T-6 is closed by **D-AP**: option A (build it natively) **plus** a retained option C
(`jca_web` survives as the LAN client). Not a decision any longer — it is the GUI parity work
above.

### Stage 3 — Deployment *(USER decision, then work)*

`TODOS.md` **T-7**. The product is two Nim binaries plus `etc/`, `public/`, `png/` and
`hardware-profiles/`. **How they get installed is one decision, taken once.**

**The shell installer is archived and is not the answer** (D-AH, D-AM) — it has been raised as
outstanding work three separate times and it is not. The realistic candidates are a FreeBSD port /
package, or `nimble install` plus a documented data-directory layout. Service integration (`rc.d`,
`rcvar`, `sysrc jenova_enable=YES`) was cancelled at D-H **specifically so it could be written once
against the Nim program** — it belongs in this stage, not before it.

### Stage 4 — The CLI *(after stages 2 and 3)*

`TODOS.md` **T-8**, gated by **D-AI**. `jenova-core` already has an operational subcommand surface;
`jenova-cli` is a distinct, user-facing tool and it is explicitly the last thing built.

### Independent of all four — profile data hygiene

`TODOS.md` **T-9** and **T-10**. Neither blocks anything and neither is on the critical path.

- **T-9:** `hardware-profiles/CPU/generic/jenova-setup` is entirely Linux (`cpupower`, `/sys`,
  `numactl`) and is the only CPU-only profile — so a FreeBSD host with no working Vulkan ICD lands
  on tuning that does nothing. Rewrite on FreeBSD sysctls or delete the script and let the profile
  be data-only, as the two generic fallbacks already are (Q-11).
- **T-10:** each `profile.conf`'s tuning `PROFILE_*` block contradicts the `jenova.conf` beside it
  (for `Vulkan/dgpu-i5-1135g7`: FIT 256 vs 128, CTX 8192 vs 16384, NGL 16 vs `all`, DRAFT 0 vs 1).
  Nothing reads those tuning values. Sync or delete them.

---

## Standing rules for whoever picks this up

From `BRIEFING.md`, and both were paid for:

- **If it was not executed, it is not stated.** A defect list written from reading unrun code is
  speculation with line numbers; it generates a plan, devdoc edits and a correction pass. "I don't
  know" is the correct answer for anything unrun.
- **Check whether it already exists before writing it.** `std/json`, `upstream.nim`, `paths.nim`.
- **Do not re-raise what is settled.** `DECISIONS_LOG.md`'s SETTLED FACTS table first: the engine,
  the devices, the startup model, `~/JCA`, the licence, the build system, the shell tree.
- **Adding a suite includes proving it can go red.** This project has twice shipped a suite that
  reported PASS while asserting nothing.
