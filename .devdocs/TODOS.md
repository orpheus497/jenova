# TODOS

**Last updated:** 2026-08-31 23:28

Only what is actually outstanding. Everything closed lives in `PROGRESS.md`; everything retired
lives in `.devdocs/ARCHIVE/`. **Do not re-add defects about archived files** — that loop cost a day.

> **Re-verified 2026-08-31 20:10 (Session 010) against the tree, item by item.** T-2 … T-5, T-9 and
> T-10 were each checked by reading the file they name and **all hold**. *(T-9 was closed
> 2026-08-31 22:51; T-10 is now partial. See `PROGRESS.md`.)*
>
> **Two things Session 007's identical sweep missed, and the reason is the same both times — it
> read documents where it should have read artifacts.** (1) **T-1 was not "unexplained"** — five
> cores existed and a working `gdb` was installed; see T-1. (2) **T-13 and T-14 are new defects in
> code the sweep had already walked past**, both in the rename path beside the one fixed at 19:23.
> **"No new defect was found" is a claim like any other**, and it is only as good as what was
> opened. The sequenced plan is `PLANS.md`.

---

## USER direction 2026-08-31 23:05 — all four implemented 23:28, none seen on screen

Four asks, given together, scoped in `PLANS.md` and built on the USER's *"proceed"*. **Every one is
compiled and unrun**, which is the only claim being made about them. G-26 was a scope reduction and
took no code.

| ID | Item |
|---|---|
| ~~**G-24**~~ | **DONE in source 23:28 — compiled, UNRUN on screen.** The margin, the card radius and the drop shadow are gone, and the bottom action row has a third branch so the editor page gets Close + fullscreen instead of the chat input. `PROGRESS.md` 23:28 |
| ~~**G-25**~~ | **DONE in source 23:28 — compiled, UNRUN on screen.** `Paned` around the main area, always present so a toggle cannot rebuild the page editor's `nvim`. Documents are plain `.md` files in the chat's project directory (**Q-29 → plain file**), edited by a second `nvim` on `nvimctl.docSocketPath`; `Editor:` follows the panel while it is open (**Q-30 → panel wins**). `PROGRESS.md` 23:28 |
| **G-26** | **CANCELS G-16. No virtual file explorer is to be built.** USER: *"due to the integration of the neovim page - we do not need to create a virtual file explorer - as long as everything is correctly in sync - this is because the ability to open a page with the users full neovim set to the workspaces folder - operates almost as an entire IDE for the user (depending on their config)."*<br><br>`vte.nim:90` already spawns `nvim` with its cwd at `p.workspaces`, so the premise holds today. **The load-bearing clause is "as long as everything is correctly in sync"** — and it is not, yet: **T-14** (a container rename orphans everything under it on disk) is exactly the sync defect that makes a filesystem-first view lie. G-26 does not close T-14; it raises its priority, because the file tree stops being a mirror and becomes the interface |
| ~~**G-27**~~ | **DONE in source 23:28 — compiled, UNRUN on screen.** Selection rules, a `jenova-dark` GtkSourceView scheme embedded in the binary, the sixteen-slot VTE palette, the `.glow-text` port, and the GTK4 `expander-widget` correction. Stylesheet verified to parse through a real `GtkCssProvider`; scheme verified to load. **One stated limit:** `termguicolors = true` in the USER's `init.lua` bypasses the VTE palette entirely. `PROGRESS.md` 23:28 |

## Open — observed on screen, not resolved

| ID | Item |
|---|---|
| ~~**G-23**~~ | **DIAGNOSED AND FIXED 2026-08-31 23:28 — and it was never a GTK problem, which is why three attempts on that side failed.** **Neovim paints the background**: a colourscheme sets `Normal` with a `guibg` (`jvim` uses `#14131A`), Neovim emits it per cell, and VTE renders what it is told — no CSS rule and no `set_clear_background` call can see through a cell the application filled. **Established by running the USER's own config**, not by reading: `hi Normal` reports `guibg=#14131a` normally and no background under the override. `vte.TransparentBackground` clears it via `--cmd`, for the embedded instance only. **UNRUN on screen** — the mechanism is proven, the appearance is not |

## Watch — same shape as a fixed bug, not observed

| ID | Item |
|---|---|
| **T-15** | **`Entry` can re-enter the widget diff the way `ToggleButton` was suspected of doing — unobserved, so do NOT pre-emptively rewrite.** `Entry`'s `text` hook calls `gtk_editable_set_text`, whose `changed` callback ends in `redraw()`, and two of our three Entries have a second writer: `app.draft` (cleared by `send`) and `app.noteTitle` (set by `commitRename`/`openNoteEditor`). **All eleven cores were the Quit path, and none was an `Entry`.** If a core ever shows `EntryState`, the fix is to remove the second writer or stop binding `text` from state something else mutates. **Note the history before acting on this:** the identical suspicion about `ToggleButton` was *wrong* — the widget was only ever the first thing a doomed diff touched. **Rewriting three Entries on suspicion is D-AN's defect list with line numbers** |

## Real, verified by reading the code

| ID | Item |
|---|---|
| **T-2** | **`db.nim`'s prepared-statement cache never evicts.** `api.nim`'s message update builds its `SET` clause from whichever fields the client sends, so distinct SQL strings accumulate, each holding a `sqlite3_stmt`. Fix belongs in `db.nim` (a cap plus finalize-on-evict), not in `api.nim` |
| **T-3** | **Chat history is never trimmed.** The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE` |
| **T-4** | **`fssync.resolveStoragePath` only resolves symlinks for paths that already exist.** A new file written through a symlinked parent escapes the workspace root; separately, a symlinked `$JENOVA_WORKSPACES` makes the check reject legitimate paths. Both directions need an assertion |
| **T-12** | **Does not reproduce — 2026-08-31 22:51.** `test_routes` passes **13/13** in the working tree *and* against the committed baseline, rebuilt into a scratch tree with `git archive HEAD`. So this session did not fix it and it is not in the baseline either. The likeliest explanation is that the run which recorded it had something listening on 8081, turning the three 502 assertions into 200s. **Left open, not closed** — a defect that stops reproducing without a fix is a defect whose trigger is unknown. If it returns, check `sockstat -4l | grep 8081` before anything else |
| **T-5** | **`bin/jenova` leaves `llama-server` running on exit.** Deliberate for the agent model (not discarding a multi-gigabyte load), but the embedding server is also left with nothing attached, and a stale pidfile points at a dead process after a failed start |

## Backlog — GUI parity with the Web UI (given 2026-08-31, USER)

**The direction (D-AP):** the GUI becomes the product. The Web UI becomes what a *single* device
sees when it connects over LAN, ephemerally. **1:1 parity with the Web UI is the target** —
appearance, colouring, wallpaper/canvas, structure and feature set.

Scoped into stages in `PLANS.md`. **Nothing here is blocked** — T-1 is fixed in source and awaits a
run, not a gate (see above). **The forward-looking scope is D-AT's list, G-16 … G-21, further
down**; this section is the record of what was already built and confirmed.

### Observed on screen — the USER ran the build, 2026-08-31 18:30

**G-4 and G-5 are no longer "built, unrun". They were run.** The report: *"markdown blocks are
not dynamic — the panel, the workspace tree are coloured black so can't really see the text, but
visible."* Each item below was traced to a line before it was written down.

> **CLOSED 2026-08-31 18:55 — the USER ran it: *"for the most part it looks good."*** All four
> fixes are in `PROGRESS.md` 18:42, confirmed at 18:55. The run emitted **no CSS parsing warning**,
> so every rule added parsed. **The four rows below are kept as the record of what was wrong and
> how it was found — they are not outstanding work.**

| ID | ~~Item~~ — closed, kept for the record |
|---|---|
| **G-8** | **The side panel renders as a flat black slab — `.glass-panel` is applied to nothing.** The class is defined at `theme.nim:135-140` and carried by **no widget**: `gui.nim:771` puts only `StyleClass("jenova-sidebar")` on the flap child. The Web UI's sidebar root *is* that class — `ChatSidebar.svelte:177`, `h-full glass-panel rounded-r-[24px]`. What `.jenova-sidebar` gives instead is `alpha(#131313, 0.55)` plus a right border: **a 55% tint of `#131313` over a `window` that is also `#131313` is invisible**, and there is no highlight edge, no radius and no shadow to separate the panel from the ground. Separately, theme.nim's own `.glass-panel` **omits** `box-shadow: 0 8px 32px rgba(0,0,0,0.37)` (`app.css:215`) while its comment at `theme.nim:132-134` names the drop shadow as one of the three things carrying the depth |
| **G-9** | **The workspace tree has no styling at all.** `gui.nim:818,828,838` are bare `Expander`s with no style class, on the same near-black ground. The Web UI gives every workspace item a card — `rounded-lg border border-white/5 bg-surface/20`, with crimson `text-secondary` chevron and `Layers` icons and a `text-sm font-medium text-foreground` name (`ChatSidebarWorkspaceItem.svelte:27-41`). With no card, no border and no icon colour the tree is undifferentiated text |
| **G-10** | **The wordmark is one word where the Web UI has three.** `gui.nim:781-784` renders `JENOVA` in `.brand` `#7b52ab` — **≈2.9:1 against `#131313`**, which is the "can't really see the text" in the panel header. The Web UI stacks JENOVA / COGNITIVE / ARCHITECTURE in `#7b52ab` / `#c96464` / `#e4b382`, uppercase and bold, beside a **48×48** logo tile with a purple border and glow (`ChatSidebar.svelte:181-190`). Ours decodes the logo at 24×24 (`gui.nim:774-780`) |
| **G-11** | **Code blocks collapse — the body is not sized to its content.** `gui.nim:613` wraps the code `Label` in `ScrolledWindow {.expand: false.}`. owlkettle 3.0.0's ScrolledWindow (`widgets.nim:1116-1131`) exposes **only `child`**; `gtk_scrolled_window_set_propagate_natural_height`/`_width` is called **nowhere in the package**, so it keeps GTK's default of not propagating its child's natural size and reports a near-zero minimum — and `expand: false` in a vertical Box grants exactly the minimum. **The fence parser is not at fault:** `markdown.parse` emits an unterminated fence as code (`markdown.nim:50-52`), so a block does appear as it streams. Candidate fixes: drop the ScrolledWindow and wrap the Label inside the Frame (what the Web UI does), give it a `sizeRequest`, or add the propagate-natural FFI |

### From the 19:32 run — fullscreen, and notes confirmed

| ID | Item |
|---|---|
| **G-13c** | **Fullscreen was a one-way door. FIXED 19:39, compiled, unrun.** The USER: *"the fullscreen option cuts the top of the gui off and theres no way to exit it."* **This is ours, not the compositor** — it is the toggle added at 19:02. **GTK4 hides a titlebar set via `gtk_window_set_titlebar` while fullscreened**, which is the cut-off top, and that HeaderBar held the only control that could leave. The fullscreen button now lives in the **bottom action row** — mapped in fullscreen, present in both the chat and note-editor layouts — with an **F11** accelerator. The accelerator has to hang off an always-mapped widget: owlkettle attaches the shortcut controller to the button at `GTK_SHORTCUT_SCOPE_MANAGED`, so a popover child answers only while its popover is open. **Note for G-13b:** this titlebar mechanism *was* written down at 18:55 and then discarded on the USER's answer that the header bar stays — which was true of a **compositor** fullscreen and false of ours. Two different events, one shared symptom; discarding it for the wrong one cost a round |
| ~~G-7~~ | **DONE in source 19:39 — compiled and linked, unrun.** Syntax highlighting via a hand-written `gtksourceview-5` (5.18.0) binding in new `src/jenova/sourceview.nim`; specs and schemes are a GResource inside the library, so nothing installs beside the binary. The `renderable` had to be declared in `gui.nim` — owlkettle's macro emits an **unexported** type (`widgetdef.nim:730`). Two GtkTextView setters are re-declared under Nim-side names because owlkettle's header-less prototypes conflict with `gtksource.h` at the C level. **`nm -u bin/jenova` shows all nine `gtk_source_*` symbols referenced and the link resolved `-lgtksourceview-5` — that proves it links, not that it renders** |
| ~~G-4, G-14, G-15~~ | **CONFIRMED 19:39 — the USER: *"tested notes seem to work."*** |

### From the 19:11 run — the USER: *"these features dont work"*

| ID | Item |
|---|---|
| ~~G-14~~ | **DONE — fixed 19:23, run and confirmed by the USER 19:38.** `fssync.physicalPath:149` refuses a non-UUID id, `syncNote` returns false, and **`upsert` deletes the row it just wrote** (`api.nim:221-230`). `createNote` minted `$genOid()`. **The evidence was in the database before any code was read: zero rows in `notes`, not even soft-deleted ones** — inserted and rolled back inside one call. New `fssync.newUuid()` sits beside the `isValidUuid` it must satisfy; 20 000 draws all valid and unique, and a `genOid`-shaped id confirmed rejected. **`tests/test_api_db.sh` already asserted this rule and I had run that suite without reading what it proved** |
| ~~G-15~~ | **DONE — fixed 19:23, run and confirmed by the USER 19:38.** `newChat(projId = id)` wrote `workspaceId=""` while `convsIn` matches on all three ids, so the row saved and matched nothing. **Pre-existing — it shipped in G-4's first half and survived the 18:55 confirmation because nothing had been created below the top level**; `createNote` inherited it. `nodeTools` now takes the container's full ancestry rather than one parent column. **A feature confirmed on screen was confirmed only for the path that was exercised** |

### Open — from the 18:55 run

| ID | Item |
|---|---|
| **G-12** | **There was no way to quit from inside the application.** **Quit existed only in the tray** (`trayMenu`, id 12, `gui.nim:282`); the HeaderBar's menu popover carried Start/Stop/Restart, the two model switches, the LAN toggle and Open Web UI, and no Quit. A desktop with no StatusNotifierWatcher gets no tray (`gui.run` treats that as non-fatal by design), which left the headerbar's own close button as the single exit. **Fixed 18:55: a Quit item in the app menu, on the existing `pendingActions` "quit" path — `gui.nim:400` already handled it. Compiled, NOT run** |
| **G-13a** | **No way out of fullscreen. FIXED 19:02, compiled, NOT run.** `BaseWindow.fullscreened` (`owlkettle/widgets.nim:122,140-145`) was a property the application never bound, so nothing in the program could leave fullscreen. Now bound to a new `App.fullscreen` field with a menu item driving it. **Known limitation, stated rather than discovered later:** owlkettle exposes **no window-state event**, so the app cannot *observe* a fullscreen the compositor initiated — escaping that case takes two toggles (one to sync the flag, one to leave). That is an exit where there was none |
| **G-13b** | **DEFERRED 2026-08-31 19:11 by the USER: *"the fullscreen issue may have to do with my compositor not the program — defer for now unless identified."*** **Do not open work on this.** It is reopened only if the fault is identified as the program's, and the evidence for that would be a fullscreen run's terminal output. The analysis below is kept because it records four dead hypotheses — re-deriving them is the doc-churn loop. **Original entry:** fullscreen layout does not fill, and glitches or freezes. **No mechanism established.** The USER selected both symptoms; *"header bar disappears"* was **not** selected, which **disproves the inference that G-12 and G-13 shared a root cause** and rules out GTK4's fullscreen titlebar-hiding. **Three hypotheses were checked against the source and all three died:** owlkettle's `fullscreened` property hook is guarded by `widget.hasX and state.X != widget.valX` (`widgetdef.nim:508-519`), so it was never fighting the compositor; `addOverlay` defaults to `hAlign/vAlign = AlignFill` (`widgets.nim:431-432`), so the Flap does fill its overlay; and the Flap child does carry the sidebar classes. **The one thing that is proven and still suspect:** `gtk_overlay_set_measure_overlay` is **called nowhere in owlkettle**, so it keeps GTK's default of `FALSE` and the Overlay's size request comes **only from its main child** — a `DrawingArea` that requests nothing. The sidebar and the chat column are therefore **invisible to the window's own size measurement**. That is a real structural fault; whether it is *this* fault has not been observed. **Next step is evidence, not a patch:** run fullscreen and capture the terminal — GTK names the widget in an allocation warning |

### Backlog — GUI parity, as scoped before the run

| ID | Item |
|---|---|
| ~~G-1 / G-2~~ | **DONE — ran, USER confirmed.** Theme and canvas |
| ~~G-2b~~ | **CLOSED — not a task.** The USER's ruling: *"the font should just be whatever users system font is."* Every `font-family` and absolute `font-size` is out of the stylesheet. Nothing to install, and a native app overriding the desktop's typography was the defect, not the missing fonts |
| ~~G-3 / G-3b~~ | **DONE** — panel, wordmark, logo, New Chat, search, conversation list, inline rename, delete. Delete is soft and cascades into the trash tree, so it needs no confirmation dialog |
| ~~G-4~~ | **COMPLETE in source 19:11 — compiled, NOT run.** The tree half was confirmed on screen at 18:55. **The remaining half is now built:** notes and fileAssets are listed at all three container levels, filtered by the same search box, with create/rename/delete through `api.putEntity`/`deleteEntity`; and a note opens in a `TextView` editor in the main area with Save/Close. **File assets are listed, renamed and deleted but have no editor — their content may be binary**, which is a scope call, not an omission. Save goes through `putEntity`, the same path the HTTP route takes, so the filesystem mirror and the per-workspace git repo apply |
| **G-5** | **RUN. Text blocks render; code blocks collapse — see G-11.** `markdown.nim` — headings, bullets, quotes, bold/italic/inline code as Pango markup; fenced code framed with a language label and copy button. **No syntax highlighting:** `gtksourceview5` is an approved dependency (D-AK) but owlkettle has no binding, so it is raw FFI and belongs in its own item. **Copy uses `wl-copy`** and lives at `gui.nim:572`, not in `markdown.nim` — Wayland only, unconfirmed |
| ~~**G-6**~~ | **Triaged 2026-08-31 20:10 — replaced by G-16 … G-21 below.** It was one heading covering six unrelated things, one of which was an entire unbuilt subsystem |
| **G-7** | **Syntax highlighting in code blocks.** `gtksourceview5` is installed and approved (D-AK); owlkettle has no binding, so this is a small hand-written FFI surface — its own item, not a rider on G-5 |

## Backlog — the parity surface, triaged (given 2026-08-31 20:10, USER)

**G-6 was one word per item, and one of those words was a subsystem.** Triaged against
`jca_web/src/lib/components/app/` by reading it. **The USER's scope call, verbatim:** *"the file
system and browser, the writer and editor, the file awareness and neovim integration with a tab
that has neovim running with the ai able to read the active document — we dont need mcp for the gui
yet — defer to the future."*

| ID | Item | Backend state |
|---|---|---|
| ~~**G-16**~~ | **CANCELLED 2026-08-31 23:05 by the USER — see G-26.** The Neovim page rooted at `$JCA_HOME/Workspaces` is the file browser. **Do not build `FilesView`/`VFSExplorer` equivalents.** The `/api/storage/*` surface stays — it is the LAN client's and is asserted by `test_api_fs.sh` — but no GUI view is built on it |
| **G-17** | **The writer and editor.** The note editor exists (G-4) and is the seed; this is making it an actual writing surface rather than a `TextView` with Save/Close | `putEntity` path exists. **GUI work only** |
| **G-18** | **File awareness — the AI can read the active document.** The model is given the open file's content as context | `pipeline.nim` already injects RAG and persona context; this is another injection source. **Small backend + GUI** |
| **G-19** | **Neovim in a tab.** **Decided (D-AT): a `vte4` terminal widget hosts a real `nvim --listen <socket>`, and a small msgpack-RPC client in Nim reads the active buffer** (`nvim_get_current_buf`, `nvim_buf_get_lines`). The USER keeps their own Neovim and their own config; file awareness becomes a socket query. **New dependency: `vte4`** (LGPL — permitted under D-X). FFI shape follows `sourceview.nim` | **Nothing exists.** `/infill` is already asserted as "the USER's Neovim dependency" (`test_routes.sh:82`), so the engine half is partly there |
| **G-20** | **Models selector.** The Web UI has six components; the GUI has **two hardcoded menu items** ("Switch to instruct/thinking model") | `models.discover` / `models.switchModel` exist. **GUI work only** |
| **G-21** | **Trash view.** `TrashView.svelte` | `/api/fs/trash` exists **and is asserted by `test_routes.sh`**; `list` already takes an `is_deleted` flag. **GUI work only** |
| ~~**MCP**~~ | **DEFERRED by the USER 2026-08-31 20:10 — "we dont need mcp for the gui yet".** **Do not open work on this.** Recorded because the size is the reason it must not be picked up casually: the Web UI's MCP is **14 components** over a *browser-side* client (`@modelcontextprotocol/sdk`, StreamableHTTP/SSE/WebSocket) plus an agentic tool loop in `stores/agentic.svelte.ts`. **`grep -rin mcp src/` returns two hits, both the `mcpServerOverrides` TEXT column** carried for the Web UI's data model. Parity means writing an MCP client **in Nim**, not porting a view |
| **G-22** | **Chat settings / attachments.** `ChatSettings`, `DialogChatSettings`, `ChatAttachments`. **Not named in the USER's scope call and not assumed to be in it** — raise before working |

## Real, verified by reading the code — found 2026-08-31 20:10, in no previous tracker

| ID | Item |
|---|---|
| **T-14** | **Renaming a workspace, project or folder orphans everything under it on disk.** `mirrorUpsert` returns bare `true` for `projects` and `folders` (no filesystem action at all), and `syncWorkspace` only `ensureDir`s the **new** name. Since `physicalPath` derives every note and asset path from ancestor **names**, a container rename strands the old directory tree and later writes land in a fresh one. *Reasoned from source, not executed* |

## Found 2026-08-31 22:51 during the review-finding sweep — executed, not read

| ID | Item |
|---|---|
| **T-16** | **`hardware-profiles/detect-hardware.sh` cannot run at all.** Line 19 sources `$JENOVA_ROOT/lib/detect-env.sh`, archived with the rest of the shell tree, so the script aborts there — every mode, including `--info` and `--apply`. **Executed and confirmed**, not read: `sh hardware-profiles/detect-hardware.sh --info` prints only the sourcing error. `BRIEFING.md` lists `hardware-profiles/` as retained setup-time tooling, so this is a live gap. It also means the OS-release and `_JENOVA_ROOT` fixes made on 2026-08-31 are correct but unexercised. Three ways out — inline the handful of values it uses (`JENOVA_OS_RELEASE`, `JENOVA_CPU_MODEL`, `JENOVA_CPU_THREADS`, `JENOVA_PHYSICAL_THREADS`, `JENOVA_RAM_GIB`, `JENOVA_SWAP_GIB`, `load_jenova_profile`), restore the library, or move profile selection into the Nim core — and the choice is **T-7's**, not a defect fix |
| **T-17** | **Nothing indexes anything for retrieval.** `rag.query` short-circuits on `documentCount() == 0`, and `rag.indexContent`/`indexFile` have **no callers repo-wide outside `rag-selftest`**. The query path is complete and proven by the self-test — keyword ranking, path filter, snippet survival, the float32 BLOB round-trip, the similarity maths — but the `--- REPOSITORY CONTEXT ---` block can never appear in a real request and `Prepared.ragHits` is always 0. **This is B-15 carried across the rewrite**, with one cause instead of Lua's three: no indexer is wired. Deciding *what* it walks (the workspace tree? a project root? on what trigger?) is the open question, not the code |
| **T-18** | **`hardware-profiles/Vulkan/dgpu-i5-1135g7/jenova-setup` calls `bin/jenova-swap-mount`, which is archived.** The `_JENOVA_ROOT` traversal was off by one and is now fixed, but the helper it resolves to no longer exists, so the script always takes its inline `mdmfs` fallback. That fallback works; the dead reference and the `README`/`docs/usage.md` lines still advertising `jenova-swap-mount` as a command do not. Decide whether the tool comes back or the references go |

## Product decisions — not mine to make

| ID | Item |
|---|---|
| **T-6** | ~~**`jca_web` still owns the workspace side**~~ — **ANSWERED 2026-08-31 by D-AP.** The workspace surface is **built natively** (G-4). `jca_web` is **not dropped**: it becomes the ephemeral single-device LAN client. This was option A plus a retained option C, and it is no longer an open question |
| **T-11** | **Filesystem as the source of truth, database freed for RAG and memory.** *(USER proposal 2026-08-31 — recorded, not yet decided; see D-AQ.)* Today the database is authoritative and `fssync.nim` mirrors it to disk. The proposal inverts that. **The expensive half already exists** — `fssync` already writes a directory per workspace, a git repo per workspace, a trash tree and `.metadata.json` sidecars. What must be settled: identity in the sidecars, and what replaces the database's transactional guarantee for move/rename/delete (the per-workspace git repo is the obvious candidate). **Independent of G-1 … G-6 and must not be entangled with them** |
| **T-7** | **Deployment.** The product is two Nim binaries. How they get installed is one decision, taken once. The shell installer is archived and is not the answer |
| **T-8** | **CLI.** After the above |

## Data, independent of everything

| ID | Item |
|---|---|
| **T-10** | **Three profiles still contradict their own `profile.conf`.** Closed for `Vulkan/dgpu-i5-1135g7` (jenova.conf synced to NGL 16 / 8K / 1 slot / no drafter) and `Vulkan/dgpu-igpu-i5-1135g7` (draft flag to 1) on 2026-08-31 22:51. Remaining: `apu-ryzen7-5700u`, `CPU/generic` and `dgpu-generic-12gb` — and the `FIT_TARGET` and `HEALTH_TIMEOUT` values on the two just synced, which were left alone because `-fitt` is not passed at all when `NGL_AGENT` is an explicit count. **Not the whole prefix:** `PROFILE_OPT_IN` and `PROFILE_DESC` *are* read, by `detect-hardware.sh` |

---

## Closed by the 2026-08-31 rewrite — do not reopen

The audit series B-44 … B-65 was written against `gui.nim` and `tray.nim` before either had been
run. **Most of it is void**, and the reason matters:

- **B-44, B-45, B-46, B-53, B-55, B-56, B-57** — fixed, and mostly by *deleting* the code that had
  them. The hand-rolled HTTP client, SSE parser, JSON escape decoder and JSON serialiser are gone;
  `std/json` was already imported three modules away.
- **B-47** ("the UI freezes 2–4 s") — **never measured, asserted from reading.** Control work did
  move off the GTK thread, but the defect as stated was speculation.
- **B-48, B-49, B-50** (tray protocol) — **asserted from reading the D-Bus spec, then asserted to be
  disproven from a claim the USER never made.** The tray registers and renders. Unknown, not open.
- **B-61, B-62, B-63, B-64, B-65** — dead code and comments that contradicted their own code.
  Partly gone with `llama.nim`/`inference.nim`.
- **Everything about the shell tree** — N-34, N-35, B-11, B-27, B-28, B-29, B-35, B-39, B-42, B-54,
  and the dangling `jenova-ca` references. **Archived, not pending.**

**The lesson, recorded as D-AN:** a defect list produced by reading unrun code is speculation with
line numbers. It generates a plan, which generates devdoc edits, which generates the next session's
correction pass. **If it was not executed, it is not stated.**
