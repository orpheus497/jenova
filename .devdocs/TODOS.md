# TODOS

**Last updated:** 2026-08-31 19:23

Only what is actually outstanding. Everything closed lives in `PROGRESS.md`; everything retired
lives in `.devdocs/ARCHIVE/`. **Do not re-add defects about archived files** — that loop cost a day.

> **Re-verified 2026-08-31 (Session 007) against the tree, item by item.** Every one of T-1 … T-10
> was checked by reading the file it names. **All ten hold. No new defect was found, and nothing
> here is speculative.** The evidence is in `SESSION_HANDOFF.md` Session 007; the sequenced plan for
> working through them is `PLANS.md`. **T-1's fix is compiled into `bin/jenova` — the outstanding
> work on it is to run it, not to write it.**

---

## Blocking

**Nothing is blocking.** T-1 was the only entry here and it did not survive examination — see below.

## Unexplained, not blocking

| ID | Item |
|---|---|
| **T-1** | **One unexplained core, and a diagnosis that is not supported.** **Corrected 2026-08-31 (Session 007) — the previous text was narrative, not evidence, and it was mine to check before I repeated it.**<br><br>**What is actually known.** Exactly one core from this program exists: `/var/coredumps/jenova.66331.1001.core`, `file` reports *"from ./bin/jenova, pid=66331"*, dated **15:26** — **before** `gui.nim` was edited (15:29) and rebuilt (15:44). So something did terminate abnormally, once, in a build that no longer exists.<br><br>**What is NOT known.** **The signal.** No debugger in the editing container reads a FreeBSD core, and the binary that produced it has been rebuilt, so a backtrace against the current one would be misleading. "SIGBUS", "after ~90 s while typing", and the `gtk_widget_set_margin_top` frame all came from Session 006's write-up with **no artifact behind them** — the same session whose own handoff says its defining failure was asserting what it had not run.<br><br>**The stated cause is contradicted by the library.** `owlkettle/widgets.nim:243` walks both child sequences **by index** and, when the types at an index disagree, calls `gtk_box_remove` then `gtk_box_insert_child_after`. **A type mismatch at a position is an explicitly handled path — it swaps the widget out.** A vanishing sibling causes a cascade of remove/reinsert, which is wasteful and may flicker; it is **not** a write into the wrong widget. *(Read: Box's update hook. Not the whole library, and nothing was run.)*<br><br>**Counter-evidence from the USER, 2026-08-31 16:17.** `./bin/jenova` ran **1:41.78** — past the claimed ~90 s — and exited on the USER's own Ctrl-C (`SIGINT: Interrupted by Ctrl-C`, Nim's default handler). Terminal output was two benign warnings: `VK_SUBOPTIMAL_KHR` (swapchain notice on resize) and a `GtkText` focus-out warning. **`find /var/coredumps -newermt "15:44"` returns nothing — that run produced no core.**<br><br>**Standing status:** one unexplained core predating the current build; the current build shows no fault in 101 s of use. **Not a blocker, and it does not gate G-1 … G-6.** If it recurs, capture the core and read the signal on the FreeBSD host before writing a cause down |

## Real, verified by reading the code

| ID | Item |
|---|---|
| **T-2** | **`db.nim`'s prepared-statement cache never evicts.** `api.nim`'s message update builds its `SET` clause from whichever fields the client sends, so distinct SQL strings accumulate, each holding a `sqlite3_stmt`. Fix belongs in `db.nim` (a cap plus finalize-on-evict), not in `api.nim` |
| **T-3** | **Chat history is never trimmed.** The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE` |
| **T-4** | **`fssync.resolveStoragePath` only resolves symlinks for paths that already exist.** A new file written through a symlinked parent escapes the workspace root; separately, a symlinked `$JENOVA_WORKSPACES` makes the check reject legitimate paths. Both directions need an assertion |
| **T-12** | **`test_routes` fails 5 assertions, and has been failing.** The upstream-proxy checks — `POST /v1/chat/completions`, `/completion`, `/infill` — expect **502** with no `llama-server` running and get **500** (the pipeline threw) or **200** (something answered). **Attributed on 2026-08-31 19:23:** the working tree was stashed, `jenova-core` rebuilt from the committed baseline, and the identical five failed, so it is **pre-existing and not from the GUI work**. The other four suites pass. **`BRIEFING.md` claimed the suites passed** on the strength of Session 006 plus "not re-run since" — a claim with a disclaimer attached is still a claim, and this is rule 1 applied to a tracker rather than to a sentence. Diagnose 500-vs-502 first: a 500 means the pipeline raised before reaching the proxy, which is a different fault from the 200 |
| **T-5** | **`bin/jenova` leaves `llama-server` running on exit.** Deliberate for the agent model (not discarding a multi-gigabyte load), but the embedding server is also left with nothing attached, and a stale pidfile points at a dead process after a failed start |

## Backlog — GUI parity with the Web UI (given 2026-08-31, USER)

**The direction (D-AP):** the GUI becomes the product. The Web UI becomes what a *single* device
sees when it connects over LAN, ephemerally. **1:1 parity with the Web UI is the target** —
appearance, colouring, wallpaper/canvas, structure and feature set.

Scoped into stages in `PLANS.md`. **Nothing here is blocked** — T-1 was corrected on 2026-08-31 and
is not a gate (see above).

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

### From the 19:11 run — the USER: *"these features dont work"*

| ID | Item |
|---|---|
| **G-14** | **A note could never be created. FIXED 19:23; the id half is proven, the GUI path is unrun.** `fssync.physicalPath:149` refuses a non-UUID id, `syncNote` returns false, and **`upsert` deletes the row it just wrote** (`api.nim:221-230`). `createNote` minted `$genOid()`. **The evidence was in the database before any code was read: zero rows in `notes`, not even soft-deleted ones** — inserted and rolled back inside one call. New `fssync.newUuid()` sits beside the `isValidUuid` it must satisfy; 20 000 draws all valid and unique, and a `genOid`-shaped id confirmed rejected. **`tests/test_api_db.sh` already asserted this rule and I had run that suite without reading what it proved** |
| **G-15** | **Anything created inside a project or folder was invisible. FIXED 19:23, unrun.** `newChat(projId = id)` wrote `workspaceId=""` while `convsIn` matches on all three ids, so the row saved and matched nothing. **Pre-existing — it shipped in G-4's first half and survived the 18:55 confirmation because nothing had been created below the top level**; `createNote` inherited it. `nodeTools` now takes the container's full ancestry rather than one parent column. **A feature confirmed on screen was confirmed only for the path that was exercised** |

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
| **G-6** | **The remaining Web UI surface**, triaged against parity: notes/files/trash views, models selector, chat settings, attachments, MCP. **Not scoped — a heading, not a task** |
| **G-7** | **Syntax highlighting in code blocks.** `gtksourceview5` is installed and approved (D-AK); owlkettle has no binding, so this is a small hand-written FFI surface — its own item, not a rider on G-5 |

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
| **T-9** | `hardware-profiles/CPU/generic/jenova-setup` is entirely Linux — `cpupower`, `/sys`, `numactl`. It is the only CPU-only profile |
| **T-10** | Each `profile.conf`'s **tuning** `PROFILE_*` block contradicts the `jenova.conf` beside it — for `Vulkan/dgpu-i5-1135g7`, FIT 256 vs 128, CTX 8192 vs 16384, NGL 16 vs `all`, DRAFT 0 vs 1. Nothing reads those tuning values. Sync or delete them. **Not the whole prefix:** `PROFILE_OPT_IN` and `PROFILE_DESC` *are* read, by `detect-hardware.sh:166,302` — this item said "nothing reads them" until 2026-08-31, which would have made deleting the block look safe |

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
