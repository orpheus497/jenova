# TODOS

**Last updated:** 2026-09-01 17:27 (Session 018)

Only what is actually outstanding. Everything finished lives in `PROGRESS.md`.

**Every item below says what it is in plain English first.** A session that writes
"G-23 needs resolving" and stops has not communicated anything. The ID is a filing
reference, not an explanation.

**Cite the symbol, then the line.** Every line reference in this file was re-derived
against the source on **2026-09-01 at 17:27**. This is the **sixth** sweep — 12:08,
14:19, 15:13, 15:46, 16:19 and now — and every one of them was made stale by the next
block of work.

**The sixth sweep is the one that settles the argument.** It was run against a *clean
working tree with no session edits in it* — nothing had changed the code since the fifth
sweep was written — and **six of the eight citations were still wrong.** They did not rot
because a session moved the code afterwards; they were **wrong when they were written**,
because they were copied forward from the previous revision instead of being read out of
the file. The fifth sweep also recorded `gui.nim` at **3,837 lines** when the file it was
describing is **3,916**.

**Every finding survived every sweep. Only the addresses moved.** That is rule 14, and
the correction to it is rule 9: **a line number is not worth writing down.** Read the
symbol.

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

**The 2026-09-01 14:02 build has been run by the USER, and nothing came back wrong.**
Confirmed on screen: both themes, the ghost text in the parameter boxes, and the full
settings field set including the "not yet in effect" markers. **Step 5 and Step 5a have
no outstanding visual question.**

**The 2026-08-31 23:28 build was also run**, and the Neovim page transparency fix, the
document panel, the editor-page framing and the colour work are all run with no
appearance defect reported. The report from *that* run was that the GUI is missing Web
UI features, which is what this file is about.

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
What is left of G-30 is Step 7b · G-20, G-21 and G-17 are Step 8.
**Steps 1-7 are built.** G-33 (the stop button), G-34 (tables, task lists,
strikethrough), G-35 (typed errors and Retry) and G-36 (delete confirmations)
are done and gone from this file — the record is `PROGRESS.md`. **Step 8 is
next**, with what remains of attachments (7b) alongside it.

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

### G-30 — Attachments: all three routes are in; two formats are not

**Built 2026-09-01** (`PROGRESS.md`). **All three of the Web UI's routes in now
work** — a file picker, **drag-and-drop** onto the chat column, and **paste of an
image from the clipboard**. Staged files show as chips with **real thumbnails**,
clicking one opens a **full-size preview**, and a sent turn shows what was
attached to it. Stored in `messages.extra` in the frozen Web UI's shape (D-BP)
and sent as OpenAI content parts by `pipeline.contentFor`.

**What is left, and both have a reason rather than an omission:**

| | |
|---|---|
| **PDFs** | **Blocked on a dependency decision — yours.** `contentFor` already *sends* a PDF carrying extracted text or page images, which is what an imported Web UI conversation has, but Jenova cannot produce either. Extraction needs **FlateDecode**, i.e. zlib inflate: Nim's stdlib has none, so it means linking `libz` (`/usr/lib/libz.so.1` is present, zlib licence, which AGENTS.md permits). **That is a dependency change and Directive 1 gates it.** Nothing else about the parser is hard |
| **Audio capture** | **Raise before building, as `PLANS.md` has said since 7b was written.** `contentFor` emits `input_audio` parts already; nothing records. It needs either `/dev/dsp` ioctl work or a capture library, **and the models in use have no audio modality**, so it may buy nothing at all |


### G-20 — The model selector is two hardcoded menu items

Still open, unchanged, and now with the scale stated. The Web UI has a searchable
model list with per-model status (loading/ready/error), capability badges, favourites,
load/unload, and a full model-information dialog showing context size, parameter
count, quantisation, vocabulary size, parallel slots, modalities and the chat template.

**The Nim GUI has "Switch to instruct model" and "Switch to thinking model"**
(`gui.nim:3389` and `gui.nim:3393`), two hardcoded menu items — and the same two
hardcoded in `gui.trayMenu` (`gui.nim:646,648`). *Re-derived 2026-09-01 17:27; the
previous addresses — 3312/3316 and 639/641 — were wrong at the moment they were
written, not rotted afterwards.*

Backend exists: `models.discover` / `models.switchModel`.

### G-21 — No trash view

Deleting anything is a soft delete and it goes somewhere. There is no way to see or
restore it from the desktop application.

Backend exists and is tested, all inside `api.handleFs` (`api.nim:625`):
`GET /api/fs/trash` (`api.nim:631`), `POST /api/fs/trash/restore` (`api.nim:639`),
`DELETE /api/fs/trash/empty` (`api.nim:647`), over `fssync.getTrash`,
`fssync.restoreTrash` and `fssync.emptyTrash`. Plus `/<entity>/deleted` and
`/<entity>/<id>/restore` on every table (`api.nim:802`, over `api.restoreItem`).

### G-17 — The note editor is a plain text box

It is a `TextView` with Save and Close — `gui.saveNote` (`gui.nim:1329`). It is the seed
of a writing surface, not one.

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
| **G-37** | **Two style rules in `theme.nim` are dead.** `paned > separator` styles a widget that is not in the tree — a leftover from G-25, which shipped as a `Box` after a `Paned` crashed the app. And `.glow-text` is defined and carried by no widget: the glow effect works, but as a `text-shadow` duplicated inside `.brand` and `.conv-active`. **The second half is G-8's exact defect — a class defined and applied to nothing — recurring in the same file.** Both were found and reported on 2026-09-01 and neither was filed as work; that is why they are here. Re-verified 2026-09-01 14:19: `.glow-text` is `theme.nim:253` and **no widget in `gui.nim` carries the class** (a grep for it in `gui.nim` returns zero hits); `paned > separator` is `theme.nim:428-432`. *Re-verified 2026-09-01 17:27: the `.glow-text` address held, the separator address did not — it was written as 416-420 against a file where it is 428. Earlier revisions named 162 and 251-255, and before that named them in the opposite order.* |
| **G-38** | **A code comment in `gui.nim` describes a widget that was never used.** The main-area comment still explains itself as feeding "the `Paned` that G-25 adds". G-25 shipped as a `Box`, and the comment above the `Box` itself records why. A reader following the first comment looks for a `Paned` that does not exist. Prose only, no behaviour. `gui.nim:2637`, above `gui.mainArea` — *not 2560, which was wrong when written.* |
| **T-12** | **A one-line fix to two test scripts. The subject is closed — do not diagnose it again (D-BJ).** `test_routes.sh` and `test_lifecycle.sh` fail if anything already holds the machine's real ports, because neither overrides `JENOVA_LLAMA_PORT` the way both already override `JENOVA_PORT`. **That is the entire finding.** It is not a product fault, it is not a mystery, and it has been fully diagnosed three separate times. **The fix:** give both scripts their own dead upstream ports. Until the USER schedules it, a session seeing those failures records nothing and says nothing. |

**Noted, not work:** `jca_web/src/lib/components/app/workspace/` holds one orphan file,
`FlashModelUpload.svelte`, with an empty `index.ts` and nothing importing it. It is the
one directory under `components/app/` the barrel does not export, so it is **not** part
of the parity inventory. Recorded so it is not rediscovered and mistaken for a gap.
`jca_web` is frozen (D-Z) — this is not a licence to edit it.

---

## Active — defects in the Nim code, each verified by reading it

**Ordering is `PLANS.md`:** T-5, T-2, T-4 and T-3 are Step 9, in that order.

**G-40 is gone from this table because it is done** — attachments no longer freeze
the window (2026-09-01 17:51, `PROGRESS.md`, **D-BQ**). Per the completion rule its
record lives in `PROGRESS.md`. **One piece of it was deliberately left and is now
`PLANS.md` Step 7d:** payloads still live inline in `messages.extra` (D-BP), so each
one is held in `allMessages`, again in `messages`, and again in the outbound body.
That is a storage-shape decision for the USER, not a defect.

**T-14 is gone from this table because it is done** — renaming a container now moves its
directory (2026-09-01, `PROGRESS.md`, D-BE). Per the completion rule, its record lives
in `PROGRESS.md` and not here.

**T-17 is gone from this table for the same reason** — the search index is fed now
(2026-09-01 12:08, `PROGRESS.md`, **D-BI**). The AI recalls past chats: a completed
exchange is indexed, existing history is backfilled once the embedding server answers,
and a deleted turn is forgotten. **Step 4 is built.**

| ID | What is wrong, in plain English | Where |
|---|---|---|
| **T-5** | **Quitting the app leaves the embedding server running.** Leaving the main model loaded is deliberate — reloading gigabytes into the GPU every start is worse. But the embedding server is left running with nothing attached to it. | `gui.run` calls `lc.startAll()` (`gui.nim:3790`); its `defer` (`gui.nim:3801-3806`) sends the workers the quit sentinel, joins the three threads and closes the channels — **and calls no `stopAll`**, which exists as `lifecycle.stopAll` (`lifecycle.nim:329`) and is only ever reached from the control worker's stop/restart jobs (`gui.nim:735`, `gui.nim:739`). *Re-derived 2026-09-01 17:27; every address in the previous revision — 3713, 3724-3728, 681, 685 — was wrong.* |
| **T-2** | **A long-running server slowly leaks memory.** The database keeps a cache of compiled queries that is never trimmed, and one API route builds a different query text for every combination of fields a client sends. | The cache is `Conn.cache` (`db.nim:46`), filled by `db.prepared` (`db.nim:165`) with no eviction; the only `sqlite3_finalize` is in `db.closeConn` (`db.nim:415-418`). The route is `api.updateMessage` |
| **T-4** | **Two holes in the file-access containment check.** A *new* file written through a symlinked folder can escape the workspace root, because the symlink check only runs on paths that already exist. Separately, if the workspace root itself is a symlink, legitimate paths get rejected. | Both in `fssync.resolveStoragePath` (`fssync.nim:694`): the lexical base at `fssync.nim:700`, and the existence-gated symlink check at `fssync.nim:713` |
| **T-3** | **The whole conversation is resent to the model every single turn.** No trimming, so a long chat eventually exceeds the context window. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message. | `pipeline.prepare` (`pipeline.nim:223`) — **there is no trim step anywhere in the file**; the only `trim`-shaped call in it is `text.strip` on an intent prefix (`pipeline.nim:105`) |

---

## Watch — looks like a bug we already fixed, but has never been seen

| ID | Item |
|---|---|
| **T-15** | The crash fixed in Session 011 was a widget re-entering the redraw. `Entry` has the same shape: its `text` hook can trigger a redraw, and two of them have a second thing writing to them (`app.draft` cleared on send, `app.noteTitle` set on rename). **Do not rewrite them.** All eleven crashes were the quit path and none was an `Entry`. Act only if a crash actually shows one. | **Four `Entry` widgets, plus a `SearchEntry`.** The tree-row rename `Entry` (`gui.nim:1964`), the note-title `Entry` (`gui.nim:2669`), the settings panel's generic text field (`gui.nim:3015`, rebuilt per setting from `optsDraft`, added by G-31), the chat-draft `Entry` (`gui.nim:3732`), and the conversation `SearchEntry` (`gui.nim:3497`), which the previous revisions never counted. *Re-derived 2026-09-01 17:27; the previous set — 1887, 2592, 3655, 2938 — was wrong in all four, and was itself the third revision of this row.* |


---

## S — **empty. There is no shell left in the product tree.**

**S-1 and S-2 were built on 2026-09-01 15:13 and are gone from this file** per the
completion rule; the record is `PROGRESS.md`. Hardware detection, scoring, the profile
screen and `jenova-core hardware` are Nim (`src/jenova/hardware.nim`), the six shell
scripts are in `.devdocs/ARCHIVE/hardware-profiles/`, and `hardware-profiles/` holds
data only.

**`tests/*.sh` are the six test harnesses, not product code.** They are the only shell
files left anywhere outside `external/` and `.devdocs/ARCHIVE/`.

**Kernel tuning was deliberately not ported (D-BN)** — Jenova never applies a `sysctl`
and never writes `/etc/sysctl.conf`. Nothing replaces those scripts, and that is the
finished state, not a gap.

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
