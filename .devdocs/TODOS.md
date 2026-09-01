# TODOS

**Last updated:** 2026-09-01 19:05 (Session 019)

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

**Seventh sweep, 2026-09-01 18:07 — and this one is the last, because the policy
changed instead.** Every finding in this file was re-verified against the source and
**every one is still true**. The addresses split exactly along which files the last
two steps touched: every citation into `db.nim`, `fssync.nim`, `pipeline.nim`,
`theme.nim` and `lifecycle.nim` was **correct**; every citation into `gui.nim` and
`api.nim` was **wrong**, because G-40's fix and G-41 took `gui.nim` from 3,916 to
**4,019** lines and moved `api.nim` with it.

**So bare line numbers into `gui.nim` and `api.nim` are gone from this file and from
`PLANS.md`.** A reference now names the symbol and stops there — `gui.saveNote`,
`api.handleFs`, `lifecycle.stopAll`. Line numbers survive only where they were
verified correct *and* the file is stable. This is rule 9 applied rather than
restated; six sessions of re-deriving them proved re-deriving is not the fix.

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

## NEW DIRECTION from the USER — 2026-09-01 18:29

Four instructions given in one message, and **they are one feature**: a workspace should
carry its own notes, its own files, and an editor that works on them with the AI.
Rulings **D-BS**, **D-BT**, **D-BU**, **D-BV**; the plan is `PLANS.md` **Step 10**, plus
a rescoped **8c**.

**Every claim in the four items below was verified against the source on 2026-09-01 at
18:29.** None is inferred.

**G-43, G-45, G-46 and G-21 are gone from this file because they are done**
(2026-09-01 19:05, `PROGRESS.md`). Per the completion rule their record lives in
`PROGRESS.md`, not here. In short: workspace notes and files now reach the model
via the new `workspace.nim` and `pipeline.chatBody`; the editor page loads `jvim`;
the document panel is removed; and the window has a trash view whose restore also
puts a message back in the retrieval index.

### G-44 — An uploaded file is never stored as a workspace artefact *(D-BV)*

**Nothing in the program has ever written a `fileAssets` row.** The table is created in
`db.nim`, cascaded in `api.nim`, trashed and restored in `fssync.nim`, and **never
inserted into**. An attachment therefore exists only as inline base64 in
`messages.extra` (D-BP) and is invisible both to its workspace and to G-43's context.

**Q-34 is ANSWERED — parity with the Web UI (2026-09-01 18:41):** `messages.extra` keeps
the inline base64 exactly as D-BP stores it and the artefact is written **in addition**.
Nothing about the message row changes, so a conversation still moves between this window
and the frozen `jca_web` unconverted. **Step 7d is closed and nothing here is gated.**

**This is now the obvious next piece of work.** G-43 landed 2026-09-01 19:05, so
`workspace.contextFor` already reads `fileAssets` and renders it — including the
`(Binary file, content not available for direct reading)` case — and **nothing has ever
written a row for it to find.** The reader exists; the writer does not. `PLANS.md` 10b.

### G-17 is rescoped **twice**, and is now the smallest it has ever been *(D-BW)*

**D-BT is superseded.** At 18:29 the USER directed the note editor at Neovim; at 18:41
they ruled the opposite and reduced the scope further:

> *"lets keep the default notes editor and dont replace it with neovim"* … *"instead we
> should make the notes system work well and keep the neovim and neovim config to its own
> page - the editor page - as it currently exists."*

**So G-17 is: make `gui.saveNote` and its `TextView` a good notes editor.** Not a writing
surface built from scratch (its original scope), not a second Neovim (D-BT's).

**Q-35 is answered and nothing is gated.** T-11 is **not** touched — with notes in their
own editor and Neovim on its own page there is no second writer against an authoritative
row at all, which is what Q-29 was protecting.

### G-47 — the editor page's Neovim is truncated at the bottom on a resize

**Reported by the USER 2026-09-01 18:41:** when the main display changes, the embedded
Neovim is *"slightly truncated at the bottom, so the neovim inside the vt needs to
scroll."*

**Not diagnosed — stated as reported** (rule 1). The editor page mounts
`NvimTerminal {.expand: true.}` and `vte.buildTerminal` sets a 10,000-line scrollback but
nothing about geometry. **The likely mechanism, flagged as a candidate and not a
finding:** a VTE sizes itself in whole character cells, so an allocation that is not an
exact multiple of the cell height leaves a partial row clipped at the bottom edge. That
would need confirming against the widget before anything is changed, and it is widget
behaviour, so **it is a USER run either way** — the same standing gap as G-41 and G-42.

**Not scheduled for this session.** Filed so it is not rediscovered.

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

**The Nim GUI has "Switch to instruct model" and "Switch to thinking model"** — two
hardcoded menu items in the window's model menu, and **the same two hardcoded again**
in `gui.trayMenu`. Search the two literals; do not chase a line number.

**And `models.discover` is never called from `gui.nim` at all** — verified
2026-09-01 18:07, the only `models.*` call in the whole GUI is
`models.switchModel(j.jcaHome, target)` in the control worker. So the selector has no
list to draw from today; 8a's first job is to call `discover` and put its result on
screen.

Backend exists: `models.discover` / `models.switchModel` (`src/jenova/models.nim`).

### G-17 — The note editor is a plain text box

It is a `TextView` with Save and Close — **`gui.saveNote`**, with one caller, the Save
button's `clicked`. *(Verified 2026-09-01 18:07. The line number is deliberately not
recorded — see the sweep note at the top of this file.)*

**Rescoped 2026-09-01 18:41 by D-BW: this stays and is made good.** It is not replaced by
Neovim and it is not rebuilt from scratch. See the D-BW block above.

### MCP — still deferred by you, and it is the largest item in the Web UI

Not work. Recorded only so the size is not rediscovered: it is an entire client plus
an agentic tool loop, and it touches prompts, resources, pickers, attachments and
message rendering. Do not pick it up casually.

---

## Standing gap — nothing tests the GUI

All six suites and every self-test subcommand exercise `jenova-core` — **read the list
out of `src/jenova_core.nim`, not from a number written here; it was wrong in three
files three different ways on 2026-09-01 and two more were added the same day.** They cover: routes,
database, filesystem, lifecycle, model discovery, and the Neovim buffer reader.
**Nothing tests `gui.nim` at all**, and that is still true.

**But the response is working and 2026-09-01 is the clearest evidence yet.** Four
features landed that day and the logic of all four sits below the widget layer, asserted
with no window: `workspace.contextFor` (the whole scoping ladder), `nvimctl.editorEnv`
(the editor's environment), `api.restoreEntity`/`deletedRows` (the trash listing and
undo), and `pipeline.chatBody`'s injection. **What was left in `gui.nim` was four panels
and a button** — which is layout, and layout is what a screen is for. Keep doing this. Every GUI defect in this project's history was
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
| **G-42** | **Markdown tables now render too large rather than sized to their content.** Reported by the USER 2026-09-01 18:29, on the G-41 build. **G-41 is the cause and it is a half-fix, not a regression:** a bare owlkettle `ScrolledWindow` collapsed every table to a stub, so `ContentScroll` was given `set_propagate_natural_height` **and** deliberately *not* natural width, with `policy(AUTOMATIC, NEVER)`. That stopped the collapse; nothing then constrains the result *down* to the content, so a table claims more room than its rows need. **The USER's words: "not too serious."** Cosmetic, filed, not urgent. The fix is a width/height measurement in `ContentScroll`, not another policy flag — and per D-BR neither half of G-41 is assertable, so this is a USER run either way. |
| **G-37** | *(Both halves re-verified 2026-09-01 18:07 and both addresses **held** — `theme.nim` has not been touched since. `.glow-text` is `theme.nim:253`, `paned > separator` is `theme.nim:428` and `:hover` at 432, and a grep for `glow-text` across `gui.nim` still returns **zero**.)* **Two style rules in `theme.nim` are dead.** `paned > separator` styles a widget that is not in the tree — a leftover from G-25, which shipped as a `Box` after a `Paned` crashed the app. And `.glow-text` is defined and carried by no widget: the glow effect works, but as a `text-shadow` duplicated inside `.brand` and `.conv-active`. **The second half is G-8's exact defect — a class defined and applied to nothing — recurring in the same file.** Both were found and reported on 2026-09-01 and neither was filed as work; that is why they are here. Re-verified 2026-09-01 14:19: `.glow-text` is `theme.nim:253` and **no widget in `gui.nim` carries the class** (a grep for it in `gui.nim` returns zero hits); `paned > separator` is `theme.nim:428-432`. *Re-verified 2026-09-01 17:27: the `.glow-text` address held, the separator address did not — it was written as 416-420 against a file where it is 428. Earlier revisions named 162 and 251-255, and before that named them in the opposite order.* |
| **G-38** | **A code comment in `gui.nim` describes a widget that was never used.** The main-area comment still explains itself as feeding "the `Paned` that G-25 adds". G-25 shipped as a `Box`, and the comment above the `Box` itself records why. A reader following the first comment looks for a `Paned` that does not exist. Prose only, no behaviour. **The doc comment directly above `gui.mainArea`** — *verified 2026-09-01 18:07; the address written here (2637) was wrong, as was 2560 before it, which is why no third number is being recorded.* |
| **T-12** | **A one-line fix to two test scripts. The subject is closed — do not diagnose it again (D-BJ).** `test_routes.sh` and `test_lifecycle.sh` fail if anything already holds the machine's real ports, because neither overrides `JENOVA_LLAMA_PORT` the way both already override `JENOVA_PORT`. **That is the entire finding.** It is not a product fault, it is not a mystery, and it has been fully diagnosed three separate times. **The fix:** give both scripts their own dead upstream ports. Until the USER schedules it, a session seeing those failures records nothing and says nothing. |

**Noted, not work:** `jca_web/src/lib/components/app/workspace/` holds one orphan file,
`FlashModelUpload.svelte`, with an empty `index.ts` and nothing importing it. It is the
one directory under `components/app/` the barrel does not export, so it is **not** part
of the parity inventory. Recorded so it is not rediscovered and mistaken for a gap.
`jca_web` is frozen (D-Z) — this is not a licence to edit it.

---

## Active — defects in the Nim code, each verified by reading it

**Ordering is `PLANS.md`:** T-5, T-2, T-4 and T-3 are Step 9, in that order.

**G-40 is gone from this table because it is done *and now confirmed on screen*** —
attachments no longer freeze the window (2026-09-01 17:51, `PROGRESS.md`, **D-BQ**).
**The USER ran it 2026-09-01 18:29: uploading attachments works as intended.** Step 7c's
one outstanding item — "whether the window is actually responsive with a document
attached", which nothing here could assert — **is closed by that run.** Per rule 12 do
not re-add an unverified label to it. Per the completion rule its
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
| **T-5** | **Quitting the app leaves the embedding server running.** Leaving the main model loaded is deliberate — reloading gigabytes into the GPU every start is worse. But the embedding server is left running with nothing attached to it. | **`gui.run`** calls `lc.startAll()`; its `defer` sends the three workers the quit sentinel, joins them and closes the channels — **and calls no `stopAll`**. `lifecycle.stopAll` (`lifecycle.nim:329`, verified) exists and is reached **only** from the control worker's stop/restart jobs. *Read in full 2026-09-01 18:07: the `defer` body is four statements and none of them is a `stopAll`. Line numbers into `gui.nim` deliberately not recorded — see the sweep note.* |
| **T-2** | **A long-running server slowly leaks memory.** The database keeps a cache of compiled queries that is never trimmed, and one API route builds a different query text for every combination of fields a client sends. | The cache is `Conn.cache` (`db.nim:46`), filled by `db.prepared` (`db.nim:165`) with no eviction; the only `sqlite3_finalize` is in `db.closeConn` (`db.nim:415-418`). The route is `api.updateMessage` |
| **T-4** | **Two holes in the file-access containment check.** A *new* file written through a symlinked folder can escape the workspace root, because the symlink check only runs on paths that already exist. Separately, if the workspace root itself is a symlink, legitimate paths get rejected. | Both in `fssync.resolveStoragePath` (`fssync.nim:694`): the lexical base at `fssync.nim:700`, and the existence-gated symlink check at `fssync.nim:713` |
| **T-3** | **The whole conversation is resent to the model every single turn.** No trimming, so a long chat eventually exceeds the context window. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message. | `pipeline.prepare` (`pipeline.nim:223`) — **there is no trim step anywhere in the file**; the only `trim`-shaped call in it is `text.strip` on an intent prefix (`pipeline.nim:105`) |

---

## Watch — looks like a bug we already fixed, but has never been seen

| ID | Item |
|---|---|
| **T-15** | The crash fixed in Session 011 was a widget re-entering the redraw. `Entry` has the same shape: its `text` hook can trigger a redraw, and two of them have a second thing writing to them (`app.draft` cleared on send, `app.noteTitle` set on rename). **Do not rewrite them.** All eleven crashes were the quit path and none was an `Entry`. Act only if a crash actually shows one. | **Four `Entry` widgets plus one `SearchEntry` — count confirmed 2026-09-01 18:07** by enumerating the widget declarations in `gui.nim`. They are, in file order: the tree-row rename, the note-title, the settings panel's generic text field (rebuilt per setting from `optsDraft`, added by G-31), the conversation `SearchEntry`, and the chat-draft. **This row has now had its addresses rewritten four times and been wrong four times** — 1887/2592/3655/2938, then 1964/2669/3015/3732/3497, and both sets are wrong against the current file. **No fifth set is being recorded.** Grep the declarations. |


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
