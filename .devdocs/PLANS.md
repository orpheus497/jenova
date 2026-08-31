# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-08-31 23:28

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

## G-24 … G-27 — the USER's direction of 2026-08-31 23:05 — **BUILT 23:28, UNRUN on screen**

> **All four are implemented in source and compiled.** Q-29 and Q-30 were answered by the USER's
> *"proceed"* (see `DECISIONS_LOG.md`), and **G-23 was diagnosed and fixed along the way — it was
> Neovim painting `Normal`, not GTK (D-AX)**. What remains is the one thing this plan cannot do:
> **look at it.** The section below is kept as the record of what was decided and why, and the
> order it was done in.
>
> **What to check on the first run**, in this order — each is a distinct mechanism, and lumping them
> into "does it look right" is how three G-23 attempts were spent:
> 1. **Neovim page translucency.** The particle canvas should show through the editor. If it does
>    not, the override is not reaching the instance — check `hi Normal` inside it before changing
>    any value.
> 2. **Text selection.** Select in the message box and in a note: purple, not blue.
> 3. **Code-block colours.** A fenced block in a reply should be purple keywords and gold strings,
>    not Adwaita's blues.
> 4. **The document panel.** Toggle it on a chat; the page editor's `nvim` must survive the toggle.
> 5. **The editor page's bottom row.** Close and fullscreen, not a message box.

Four asks given together. They are **not** four independent tickets: G-26 removes work, G-24 and
G-25 both hang off the Neovim integration, and G-27 is the only one that can be done in isolation.
**Do them in the order below**, because G-25 is the one with an unanswered design question and
starting there stalls the other three.

### Order, and why

| Step | Item | Blocked by | Why here |
|---|---|---|---|
| 1 | **G-27** — palette completion | nothing | Entirely additive, touches `theme.nim`/`sourceview.nim`/`vte.nim` only, and **its VTE half is a prerequisite for G-24 and G-25 looking right** — a Neovim page in stock ANSI is off-scheme however it is framed |
| 2 | **G-23** — the Neovim tab's opacity | nothing, but needs the diagnostic | Still open, still wants `GTK_DEBUG=interactive`, **still not a fourth value change**. G-24 restyles the same widget, so resolving this first stops a fifth guess being folded into a layout change |
| 3 | **G-24** — Neovim as a page | 2 | Small once 2 is known: it is a margin, an action row and a style class |
| 4 | **G-26** — cancel the file explorer | nothing | Already recorded; the work is *not doing* G-16. Its real cost is **T-14** moving up |
| 5 | **G-25** — the right-hand document panel | a USER decision (below) | The largest, and the only one that cannot start today |

---

### G-27 — finish the palette *(actionable now)*

Four separate defects with four separate fixes. **Do not treat this as one CSS pass.**

1. **Selection colours.** `theme.nim` has no selection rule, so GTK4 uses the system accent —
   Adwaita blue — everywhere text is selected. Add `selection`, `entry > text > selection` and
   `textview text selection` on `@jenova_primary` with `@jenova_fg`, and a `:selected` rule for any
   list row. This is the single most visible item and the cheapest.
2. **A Jenova GtkSourceView scheme.** `sourceview.nim:89` asks for `Adwaita-dark` first, and a probe
   compiled against the installed library **confirms it resolves** — so every code block in chat is
   GNOME's palette. GtkSourceView schemes are XML and merge from
   `gtk_source_style_scheme_manager_append_search_path()`. **Ship the scheme inside the binary**
   (`staticRead`, written to `$JCA_HOME/.system/styles/` at startup, path appended before the first
   buffer is built) so the application stays one file with no data dependency. Map keyword →
   `@jenova_purple_head`, string → `@jenova_accent` gold, comment → `@jenova_muted_fg`, number and
   constant → `ColBrandBlue`, error → `@jenova_secondary` crimson. Keep `SchemePreference` as the
   fallback chain beneath it.
3. **The VTE palette.** `vte.nim:77` passes a nil palette of size 0, so Neovim renders in VTE's
   built-in xterm 16 — this is why the Neovim page looks like a different application. Build a
   16-entry `array[16, GdkRGBA]` from the brand constants and pass `paletteSize = 16`. **The eight
   bright slots matter more than the eight normal ones** for a Neovim colourscheme, and this only
   fixes what nvim draws through ANSI: a user whose config sets `termguicolors` bypasses the
   palette entirely and needs a Neovim colourscheme instead — which is theirs, not ours, and is
   the boundary D-AT drew. **State that limit in the code rather than discovering it later.**
4. **Glows and the missing borders.** `app.css:270` is `text-shadow: 0 0 8px rgba(221,183,255,0.4)`
   (`.glow-text`) and `:227` a crimson `box-shadow: 0 0 20px`; neither was ported and GTK4 supports
   both. Apply the text glow to `.brand` and the active conversation row, not globally.

**Also audit, because the USER named "some text in the side panel and buttons":** every widget in
`leafRow`, `nodeTools` and `topBar` carries `ButtonFlat` + `.row-btn`, which sets no colour — so
icon buttons inherit the theme's, not the brand's. `Expander`'s own title and disclosure arrow are
likewise unstyled. Enumerate them against the running window before writing rules; **a colour
audit done by reading is how three G-23 attempts died.**

---

### G-24 — the Neovim tab becomes a page *(after G-23)*

`gui.nim:1242` already swaps the main area, so this is framing, not restructuring:

1. Drop `margin = 12` and the `.nvim-term` radius/shadow so the editor fills the column edge to
   edge, the way the transcript's `ScrolledWindow` does.
2. **Branch the bottom action row on `app.editorOpen`, not only on `app.openNote`.** Today the
   editor page shows the chat `Entry` and Send button, and has no Close — the note page gets
   Save/Close and the editor should get the same shape (Close, plus `fullscreenButton`).
3. Hide the `notice` label while the editor is open; it is chat feedback.
4. **Keep the three-children-same-types invariant** the comment at `gui.nim:1238` records. That is
   what stops owlkettle's positional diff swapping a widget out from under it, and it is the
   discipline that survived T-1.

---

### G-25 — the right-hand document panel *(needs one USER decision first)*

**What is settled:** it is a `Paned` (`owlkettle/widgets.nim:1344` — `orient`, `initialPosition`,
`first`, `second`), not a `Flap`, because owlkettle does not expose AdwFlap's `flap-position`. It is
toggled per chat from the top bar, and it hosts a real `nvim` in a second VTE, not a text view.

**What is not settled, and must not be guessed — two questions for the USER:**

- **Q-29: what is a "document"?**
  - **(a) A `notes` row that Neovim edits on disk.** `fssync` already writes every note to
    `Workspaces/<ws>/<project>/<folder>/<title>_<id>.md`, so the file exists and the sidebar already
    lists it. **But the database is authoritative and nvim would be a second writer** — save in
    nvim and the row is stale; save in the GUI and nvim's buffer is. That is **T-11** (filesystem as
    source of truth), which is recorded as undecided, so option (a) *is* taking T-11.
  - **(b) A plain file under the project directory**, outside the `notes` table. No two-writer
    problem, no T-11 entanglement, and "multiple can be saved" is just files in a directory. The
    cost is that these documents are not in the workspace tree unless the panel lists them itself
    — which G-26 says is acceptable, because Neovim is the browser.
  - **Recommendation: (b)**, and it can be revisited if T-11 later lands. It is the option that
    does not require a settled answer to a question the USER has explicitly left open.

- **Q-30: with two Neovim instances, which one does `Editor:` read?** `pipeline.configureEditor`
  takes one socket (`gui.nim:1337`) and `nvimctl` reads whatever buffer that instance has focused.
  The panel document is the one "directly connected to the chat", so **the panel's socket is the
  likelier answer** — but the full-page editor is where the user is actually working. Candidates:
  the panel always wins; the most recently focused wins; or `Editor:` gains a suffix. **Not a
  decision to take silently — it changes what the model is shown.**

**The work, once those are answered:**

1. `vte.nim` — replace the module-level `sockPath`/`spawnCwd` pair with per-widget spawn arguments,
   so two terminals can carry different sockets and working directories. `newNvimTerminal` reads
   globals at build time today because `beforeBuild` sees no field values; the `renderable` will
   need `{.private, onlyState.}` fields set the way `SourceCode` sets its buffer.
2. `nvimctl.nim` — `socketPath` becomes a function of a role, not a constant. **Keep it short:** the
   104-byte `sun_path` limit is measured, not assumed, and two sockets under `.system/` stay inside
   it.
3. `gui.nim` — `Paned` around the chat column; `panelOpen` and `panelDoc` state; a document switcher
   in the panel header; the top-bar toggle.
4. **Retire the `fileAssets` rows from the tree** — G-25 replaces them. The `fileAssets` table,
   `/api/db/fileAssets` and the mirror stay for the LAN client (D-Z), so this is a GUI removal only.

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
| ~~**19.1-19.3**~~ | **DONE 21:23, compiled and linked, UNRUN.** `src/jenova/vte.nim`; the terminal spawns `nvim --listen` at the **same socket `nvimctl` reads**, so the tab and the `Editor:` intent see one editor. Toggle in the top bar. `nm -u` shows all five `vte_*` symbols | **It links; it has not rendered.** Needs a run |
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
