# TODOS

**Last updated:** 2026-09-01 13:52 (Session 016)

Only what is actually outstanding. Everything finished lives in `PROGRESS.md`.

**Every item below says what it is in plain English first.** A session that writes
"G-23 needs resolving" and stops has not communicated anything. The ID is a filing
reference, not an explanation.

**Cite the symbol, then the line.** Every line reference in this file was re-derived
against the source on 2026-09-01 at 12:08, because **thirteen of them had rotted inside
a single session**: `gui.nim` grew from roughly 1,600 lines to 2,365 while the entries
citing it were being written, and every one of those citations then pointed at unrelated
code. The finding each described was still true; only its address was wrong. A reference
that names the proc survives that. **A bare line number is a claim with an expiry date.**

---

## RULE: do not run the product, and do not go looking at the machine

**Ruled 2026-09-01 (D-BJ).** Until the migration is complete, a session does not start
`bin/jenova`, `jenova-core serve`, the backends, or `nimble suites` unless the USER asks
for that specific thing in that message. **Building is not running** — `nimble core` and
`nimble gui` produce a binary and disturb nothing.

**And never enumerate processes or ports to find out what the USER has open.** Nobody
asked for an audit of their machine. Running the product takes over ports, loads gigabytes
onto the GPU, and interrupts whatever the USER is actually doing.

**T-12 is closed as a subject.** Two suites fail if something already holds the real
ports. That is the whole of it. See the Backlog entry for the one-line fix, and do not
re-derive it a fourth time.

---

## RULE: Nim only, and everything is driven from the GUI

**Jenova is Nim plus `llama-server`. Nothing else.** No shell scripts, no Lua, no C,
no Makefiles. All of that is in `.devdocs/ARCHIVE/` because it was replaced (D-AM, D-AZ).

**Every operation must be reachable from the window** (D-BC). Anything that needs a
terminal, a shell script or a hand-edited file is a defect, not a limitation.

**A defect in an archived file is not a task.** The two outcomes are: delete the
reference, or port the behaviour to Nim. Repairing the archived thing is not one, and
neither is asking which — both already sit inside the standing ruling.

---

## Run status — settled, stop re-raising it

**The 2026-08-31 23:28 build has been run by the USER.** The Neovim page transparency
fix, the document panel, the editor-page framing and the colour work are all run.
**No appearance or rendering defect was reported from that run** — the report was that
the GUI is missing Web UI features, which is what this file is now about.

Earlier revisions carried "compiled, UNRUN on screen" against those four items and two
sessions repeated it after it had stopped being true. **A "not yet run" label lasts
only until any evidence contradicts it.** Do not re-add one here.

---

## Active — the GUI is missing most of the Web UI's features

**This is the real outstanding work and it is much larger than this file previously
said.** Sessions 010-012 triaged "GUI parity" into six items (a file browser, an
editor, file awareness, Neovim, a model selector, a trash view). **That list was wrong
by omission.** It was written from a summary, not from the Web UI's own component
tree, and it missed almost everything a user actually touches in a chat.

Enumerated 2026-09-01 by reading `jca_web/src/lib/components/app/*/index.ts` — the
barrel files that list every shipped component. That is the authoritative inventory;
check any future scope claim against it, not against a summary.

**Ordering and the work for each item is `PLANS.md`.** The mapping:
G-33, G-30, G-35, G-34 and G-36 are Step 7 · G-20, G-21 and G-17 are Step 8 ·
S-1 is Step 6. **Step 6 is next.**

**Done and gone from this file** (2026-09-01, all in `PROGRESS.md`):

- **G-31 — a settings screen, and with it every sampling and penalty parameter.**
  A floating panel over the window, six sections, **1:1 with the Web UI's
  `ChatSettings`** minus three recorded exclusions: API Key and MCP (the USER's
  instruction) and `serverUrl` (`bin/jenova` is the host — N-S6). A field whose
  feature is not built yet is drawn, stores its value and is marked *"not yet in
  effect"* with the step that turns it on (**D-BL**, superseding D-BK). This also
  **closed D-BH's deliberate divergence**: Continue is now a setting, off by
  default, matching the Web UI. **Eight small features were built to back the
  settings that govern them** — a light palette, a following transcript,
  conversation auto-titling, a code-block cap, a raw-output toggle, raw model
  names and both sidebar options.
- **G-32 — import and export of conversations**, over the transactional path that
  already existed. A file exported by the frozen Web UI is accepted too.

- **G-28** — a message carries copy, edit, delete, regenerate and continue.
- **G-29 — branching.** Editing or regenerating adds an alternative version rather than
  replacing one, with a "2/3" counter to move between them. This also released the two
  restrictions G-28 shipped under: **edit now resends, and regenerate works on any
  reply** (D-BF → **D-BG**).
- **G-39 — the reasoning view.** A reasoning model's thinking is split out of the answer
  and folded away above it, open while the turn is streaming.
- **The statistics half of G-33.** G-33 remains, reduced to the stop button.

### G-30 — No attachments of any kind

The Web UI accepts images, text files, PDFs and audio, by file picker, drag-and-drop
or paste, shows them as thumbnails, previews them full-size, and validates them
against what the model can actually read (vision/audio).

**The Nim GUI has no attachment path whatsoever.** Nine Web UI components cover this:
`ChatAttachmentsList`, `ChatAttachmentPreview`, `ChatAttachmentThumbnailImage`,
`ChatAttachmentThumbnailFile`, `ChatAttachmentsViewAll`, `ChatScreenDragOverlay`,
`ChatFormActionAttachmentsDropdown`, `DialogChatAttachmentPreview`,
`DialogChatAttachmentsViewAll`.

Audio recording (`ChatFormActionRecord`) is part of this group and is the one piece
that may not be worth porting — raise it before building.

### G-33 — No way to stop a generation

**Statistics are done** (2026-09-01) — tokens in and out, tokens per second, elapsed,
cached prompt tokens, context used and remaining, and the model, per reply and live
during generation. See `PROGRESS.md`.

**What is left is the stop control.** The Web UI's send button becomes a stop button
mid-generation (`ChatFormActionSubmit`); **the Nim GUI's just greys out**, so once a
generation starts there is no way to cancel it short of quitting. Cancelling means
closing the streaming socket from the control worker, which is why the two workers are
separate.

### G-34 — Markdown is missing tables, task lists and maths

`markdown.nim` handles headings, bullets, quotes, bold, italic, inline code and fenced
code blocks. The Web UI's `MarkdownContent` additionally does **GitHub-flavoured
tables, task lists and strikethrough**, and **LaTeX maths** via KaTeX.

A model asked for a comparison answers with a table. It currently renders as raw pipes
and dashes.

### G-35 — No error reporting worth the name

The Web UI has typed error dialogs: `DialogChatError` distinguishes a **timeout** from
a **server error** and shows the prompt-token count against the context size when the
failure was a context overflow. There are also `ServerErrorSplash` (retry, API key
entry) and `ServerLoadingSplash`.

**The Nim GUI puts everything into one grey line of text** — `App.notice`
(`gui.nim:637`), written from sixteen places and rendered as one row. "the server
answered 500" is the whole diagnosis a user gets. `gui.streamOnce` (`gui.nim:164`) has
the status code in hand and turns it into that sentence.

### G-20 — The model selector is two hardcoded menu items

Still open, unchanged, and now with the scale stated. The Web UI has a searchable
model list with per-model status (loading/ready/error), capability badges, favourites,
load/unload, and a full model-information dialog showing context size, parameter
count, quantisation, vocabulary size, parallel slots, modalities and the chat template.

**The Nim GUI has "Switch to instruct model" and "Switch to thinking model"**
(`gui.nim:2032`), two hardcoded menu items.

Backend exists: `models.discover` / `models.switchModel`.

### G-21 — No trash view

Deleting anything is a soft delete and it goes somewhere. There is no way to see or
restore it from the desktop application.

Backend exists and is tested: `GET /api/fs/trash` (`api.nim:591`),
`POST /api/fs/trash/restore` (`api.nim:599`), `DELETE /api/fs/trash/empty`
(`api.nim:607`), plus `/<entity>/deleted` and `/<entity>/<id>/restore` on every table.

### G-17 — The note editor is a plain text box

It is a `TextView` with Save and Close — `gui.saveNote` (`gui.nim:968`). It is the seed
of a writing surface, not one.

### G-36 — Deleting things asks for no confirmation

Every delete in the tree and the conversation list happens on a single click.
`gui.deleteNode` (`gui.nim:1034`) is the one path, reached from the workspace tree and
from the conversation list's delete button (`gui.nim:1694`). The Web UI confirms, and
shows how many child items a cascade will take with it (`DialogConfirmation`). Deletes
here are soft, which is the argument that was used for not having a dialog — but a soft
delete with no trash view (**G-21**) is indistinguishable from data loss.

### MCP — still deferred by you, and it is the largest item in the Web UI

Not work. Recorded only so the size is not rediscovered: it is an entire client plus
an agentic tool loop, and it touches prompts, resources, pickers, attachments and
message rendering. Do not pick it up casually.

---

## Standing gap — nothing tests the GUI

All six suites and all six self-test subcommands exercise `jenova-core`: routes,
database, filesystem, lifecycle, model discovery, and the Neovim buffer reader.
**Nothing tests `gui.nim` at all.** Every GUI defect in this project's history was
found by the USER looking at the screen.

That was tolerable while the outstanding GUI work was layout. **It is not tolerable for
the work above**, which is mostly logic — branch trees, message mutation, parameter
plumbing. `PLANS.md` names what would prove each step worked, and where that can be an
assertion instead of a screenshot it must be one. **A new suite is not believed until
it has been shown to go red** — this project has twice shipped a suite that reported
PASS while asserting nothing.

---

## Backlog — raw, unscoped, no `PLANS.md` entry yet

| ID | What it is |
|---|---|
| **G-37** | **Two style rules in `theme.nim` are dead.** `paned > separator` styles a widget that is not in the tree — a leftover from G-25, which shipped as a `Box` after a `Paned` crashed the app. And `.glow-text` is defined and carried by no widget: the glow effect works, but as a `text-shadow` duplicated inside `.brand` and `.conv-active`. **The second half is G-8's exact defect — a class defined and applied to nothing — recurring in the same file.** Both were found and reported on 2026-09-01 and neither was filed as work; that is why they are here. Re-verified 2026-09-01 12:08: `.glow-text` is `theme.nim:162` and no widget in `gui.nim` carries the class; `paned > separator` is `theme.nim:251-255`. *An earlier revision of this row named those two lines in the opposite order.* |
| **G-38** | **A code comment in `gui.nim` describes a widget that was never used.** The main-area comment still explains itself as feeding "the `Paned` that G-25 adds". G-25 shipped as a `Box`, and the comment above the `Box` itself records why. A reader following the first comment looks for a `Paned` that does not exist. Prose only, no behaviour. `gui.nim:1763` |
| **T-12** | **A one-line fix to two test scripts. The subject is closed — do not diagnose it again (D-BJ).** `test_routes.sh` and `test_lifecycle.sh` fail if anything already holds the machine's real ports, because neither overrides `JENOVA_LLAMA_PORT` the way both already override `JENOVA_PORT`. **That is the entire finding.** It is not a product fault, it is not a mystery, and it has been fully diagnosed three separate times. **The fix:** give both scripts their own dead upstream ports. Until the USER schedules it, a session seeing those failures records nothing and says nothing. |

**Noted, not work:** `jca_web/src/lib/components/app/workspace/` holds one orphan file,
`FlashModelUpload.svelte`, with an empty `index.ts` and nothing importing it. It is the
one directory under `components/app/` the barrel does not export, so it is **not** part
of the parity inventory. Recorded so it is not rediscovered and mistaken for a gap.
`jca_web` is frozen (D-Z) — this is not a licence to edit it.

---

## Active — defects in the Nim code, each verified by reading it

**Ordering is `PLANS.md`:** S-1 is Step 6 ·
T-5, T-2, T-4 and T-3 are Step 9, in that order.

**T-14 is gone from this table because it is done** — renaming a container now moves its
directory (2026-09-01, `PROGRESS.md`, D-BE). Per the completion rule, its record lives
in `PROGRESS.md` and not here.

**T-17 is gone from this table for the same reason** — the search index is fed now
(2026-09-01 12:08, `PROGRESS.md`, **D-BI**). The AI recalls past chats: a completed
exchange is indexed, existing history is backfilled once the embedding server answers,
and a deleted turn is forgotten. **Step 4 is built.**

| ID | What is wrong, in plain English | Where |
|---|---|---|
| **T-5** | **Quitting the app leaves the embedding server running.** Leaving the main model loaded is deliberate — reloading gigabytes into the GPU every start is worse. But the embedding server is left running with nothing attached to it. | `gui.run` (`gui.nim:2317`) calls `lc.startAll()`; its `defer` sends both workers the quit sentinel and joins them, and calls no `stopAll` |
| **T-2** | **A long-running server slowly leaks memory.** The database keeps a cache of compiled queries that is never trimmed, and one API route builds a different query text for every combination of fields a client sends. | The cache is `Conn.cache` (`db.nim:46`), filled by `db.prepared` (`db.nim:165`) with no eviction; the only `sqlite3_finalize` is in `db.closeConn` (`db.nim:415-418`). The route is `api.updateMessage` |
| **T-4** | **Two holes in the file-access containment check.** A *new* file written through a symlinked folder can escape the workspace root, because the symlink check only runs on paths that already exist. Separately, if the workspace root itself is a symlink, legitimate paths get rejected. | Both in `fssync.resolveStoragePath` (`fssync.nim:694`): the lexical base at `fssync.nim:700`, and the existence-gated symlink check at `fssync.nim:713` |
| **T-3** | **The whole conversation is resent to the model every single turn.** No trimming, so a long chat eventually exceeds the context window. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message. | `pipeline.prepare` (`pipeline.nim:222`) — **there is no trim step anywhere in the file** |

---

## Watch — looks like a bug we already fixed, but has never been seen

| ID | Item |
|---|---|
| **T-15** | The crash fixed in Session 011 was a widget re-entering the redraw. `Entry` has the same shape: its `text` hook can trigger a redraw, and two of the three Entries have a second thing writing to them (`app.draft` cleared on send, `app.noteTitle` set on rename). **Do not rewrite them.** All eleven crashes were the quit path and none was an `Entry`. Act only if a crash actually shows one. | The tree-row rename `Entry` (`gui.nim:1392`), the note-title `Entry` (`gui.nim:1790`) and the chat-draft `Entry` (`gui.nim:2298`). *This row's addresses were stale until 2026-09-01 12:39 — they named lines 830, 1083 and 1541, which are the `umDone` index dispatch, the rename node builder and the timings formatter. Session 015's citation sweep corrected the Active tables and missed this one.* |

---

## S — the last shell in the tree, to be replaced by Nim

| ID | Item |
|---|---|
| **S-1** | **Hardware profile selection is still two shell scripts, and it must become Nim driven from the GUI** (D-BC). `detect-hardware.sh` detects the CPU, GPUs, RAM and OS, scores them against each profile's `MATCH_*` patterns and copies the winner's `jenova.conf` into place; the per-profile `jenova-setup` scripts apply kernel tuning. Both reference `lib/` and `bin/` files archived with the old build, so **neither currently runs at all** — and nothing invokes them, since `config.nim` reads `etc/jenova.conf` directly. **The work:** port detection, scoring and apply into Nim; add a GUI screen that lists the profiles, shows which matched and why, and applies one; expose the same as a `jenova-core` subcommand for headless hosts; move the kernel-tuning values into `profile.conf` as data and have Nim apply them, reporting what it could not change without privilege. Archive both scripts when it lands. |
| **S-2** | Two `profile.conf` files describe Linux filesystems (`HW_STORAGE="ext4/xfs/btrfs"`) on a FreeBSD-only project: `Vulkan/apu-ryzen7-5700u:20` and `CPU/generic:18`. Data only; fix while doing S-1. |

---

## Decisions that are yours, not a session's

| ID | Item |
|---|---|
| **T-11** | **Make the filesystem the source of truth instead of the database**, freeing the database for retrieval and memory. Your proposal, recorded at D-AQ, deliberately still open. The expensive half already exists — `fssync` already writes a directory tree, a git repo per workspace, a trash tree and metadata sidecars. What must be settled first: where an item's identity lives once database rows stop being canonical, and what replaces the database's transaction guarantee for move/rename/delete. |
| **T-7** | **How the two binaries get installed.** One decision, taken once. The archived shell installer is not the answer. |
| **T-8** | **A command-line tool**, after the above. |

---

## Closed 2026-09-01 — verified against the code and found already done

- **T-10 (profile config mismatches) — effectively closed.** This file named three
  profiles as still contradicting themselves. All three were checked key by key and
  **all three match exactly**. The only real mismatch left is on
  `Vulkan/dgpu-i5-1135g7` (which this file listed as *closed*): `FIT_TARGET` 256 vs
  128 and `HEALTH_TIMEOUT` 120 vs 90. **Both are inert** — `-fitt` is only passed when
  the layer count is `all` and this profile sets an explicit 16 (`lifecycle.nim:99`),
  and `JENOVA_HEALTH_TIMEOUT` is loaded but the watchdog hardcodes its own constants
  (`lifecycle.nim:357`). Not worth work.
- **T-16, T-18** — reclassified as **S-1**. They were archived-shell repairs and
  should never have been task items.
- **G-22 — superseded, not closed.** It was "chat settings / attachments — not named in
  the USER's scope call, raise before working". The USER has now said the GUI is
  missing Web UI features, which settles it: **attachments are G-30 and settings are
  G-31**, both in scope and both on the plan. G-22 is retired as a heading.
- **G-23, G-24, G-25, G-27 — built and run.** See the run-status note at the top of this
  file. No appearance defect came back.
- **T-6, T-1, T-13, G-1…G-16, G-19, G-26** — see `PROGRESS.md`.
