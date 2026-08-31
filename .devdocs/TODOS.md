# TODOS

**Last updated:** 2026-08-31 15:49

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
| **T-5** | **`bin/jenova` leaves `llama-server` running on exit.** Deliberate for the agent model (not discarding a multi-gigabyte load), but the embedding server is also left with nothing attached, and a stale pidfile points at a dead process after a failed start |

## Backlog — GUI parity with the Web UI (given 2026-08-31, USER)

**The direction (D-AP):** the GUI becomes the product. The Web UI becomes what a *single* device
sees when it connects over LAN, ephemerally. **1:1 parity with the Web UI is the target** —
appearance, colouring, wallpaper/canvas, structure and feature set.

Scoped into stages in `PLANS.md`. **Nothing here is blocked** — T-1 was corrected on 2026-08-31 and
is not a gate (see above).

| ID | Item |
|---|---|
| ~~G-1 / G-2~~ | **DONE — ran 2026-08-31, USER confirmed.** Theme and canvas. Still unreported: whether the canvas reads at the right weight, and whether ~30 fps idle redraw is acceptable. `CANVAS=0` disables the frame clock |
| **G-3** | **BUILT 2026-08-31, NOT YET RUN.** `adw.Flap` panel, wordmark, logo, New Chat, search, conversation list with active row; switching refused mid-stream. Both binaries build clean. **Unverified: everything visual, plus whether the `.jenova-sidebar` rule actually beats the `.background` class owlkettle's Flap adds to the panel** — if it does not, the sidebar is an opaque slab and the canvas is hidden behind it |
| **G-3b** | **Rename and delete conversations.** Left out of G-3 on purpose: both need a confirmation dialog, and a destructive action without one is worse than not having it. Fold into G-4 |
| **G-2b** | **Fonts are not installed and typography is therefore not 1:1.** The stylesheet asks for `Inter` and `JetBrains Mono`; `fc-list` finds neither, so both fall back — to Noto Sans and Noto Sans Mono. The Web UI gets them from Google Fonts at `app.css:3`, **which is the B-01 leak**, so copying that approach would import a defect. Installing them is a **dependency addition and needs USER approval (Directive 1)** — candidates are the `x11-fonts` packages. **Until then the window renders in Noto and looks close but not identical** |
| **G-3** | **The side panel.** `adw.Flap` (`content` / `flap` / `revealed` / `foldPolicy`) is the analogue of the Web UI's `Sidebar.Provider`. Header logo block, search, then the tree. **Blocked on T-1** |
| **G-4** | **The workspace tree.** Workspace → Project → Folder → {chats, focus note, notes}, plus unassigned chats and global assets. **The gap is data, not drawing:** these rows already exist in the database and are already served over `/api/db/*`; the GUI knows only `conversations`/`messages` and needs to read the rest **in-process through `db.nim`**, not over HTTP |
| **G-5** | **Chat surface parity.** Markdown rendering and syntax-highlighted code blocks via `gtksourceview5` — already an approved dependency under D-AK and the reason D-P named it |
| **G-6** | **The remaining Web UI surface**, triaged against parity: files/notes/trash views, models selector, chat settings, attachments, MCP. **Not yet scoped — G-6 is a heading, not a task** |

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
