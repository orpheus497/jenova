# TODOS

**Last updated:** 2026-09-01 10:17 (Session 014)

Only what is actually outstanding. Everything finished lives in `PROGRESS.md`.

**Every item below says what it is in plain English first.** A session that writes
"G-23 needs resolving" and stops has not communicated anything. The ID is a filing
reference, not an explanation.

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
G-29 is Step 3 · G-31 and G-32 are Step 5 · G-33, G-30, G-35, G-34
and G-36 are Step 7 · G-20, G-21 and G-17 are Step 8.

**G-28 is gone from this file because it is done** — a message now carries copy, edit,
delete, regenerate and continue (2026-09-01, `PROGRESS.md`, D-BF). Two parts of it are
deliberately held back until branching exists and are named in **G-29** below, not here:
edit does not resend, and regenerate and continue are offered on the last message only.

### G-29 — Conversation branching does not exist

**It now also gates two message actions.** Editing a turn, or regenerating one that has
turns after it, produces an *alternative version* of everything that follows. G-28
shipped without those cases (D-BF) because there is nowhere to put the old version, so
**Step 3 is what makes edit resend and what lets regenerate work anywhere but the end.**

Editing or regenerating a message in the Web UI creates a **sibling** — an alternative
version — and you navigate between them with prev/next arrows and a counter ("2/5").
The whole conversation is a tree, not a list.

The database already supports it: `conversations.forkedFromConversationId` exists, and
`api.nim` already implements recursive fork deletion and child reparenting
(`api.deleteConversation`). **The backend is done. The GUI models a conversation as a
flat `seq[Message]` (`gui.nim:383`) and cannot represent a branch at all.** G-28 gave
each of those messages its row id, which is the identity a sibling lookup needs, so the
remaining change is the shape rather than the contents.

Web UI: `ChatMessageBranchingControls`, `ChatMessages`' `getMessageSiblings()`.

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

### G-31 — No settings, and therefore no sampling controls

**There is no settings surface in the Nim GUI at all.** `gui.send` posts
`{"messages": …, "stream": true}` and nothing else (`gui.nim:797`), so **temperature,
top_p, top_k, min_p, repeat_penalty, frequency/presence penalty and repeat-last-n
cannot be set from the desktop application.** They are not defaulted badly — they are
absent.

The Web UI's `ChatSettings` has seven tabs: General (API key, system message), Display
(theme, badges), Sampling, Penalties, Import/Export, MCP, Developer. It also shows,
per parameter, whether the value came from the user, from the server's `/props`, or
from an app default (`ChatSettingsParameterSourceIndicator`).

**`llama-server` accepts all of these per request** (this is why D-AF closed N-25), so
this is GUI work over a path that already carries them.

### G-32 — No import or export of conversations

`ChatSettingsImportExportTab` + `DialogConversationSelection` let you pick
conversations and write them to a JSON file, or read one back.

**The backend route already exists and is tested** — `POST /api/db/import` runs
transactionally (`api.nim:401-422`) and `test_api_db.sh` asserts it. This is a GUI
front end over finished work.

### G-33 — No generation statistics, and no way to stop a generation

- **Statistics:** the Web UI shows tokens in/out, elapsed time, tokens per second, per
  message (`ChatMessageStatistics`) and live during generation
  (`ChatScreenProcessingInfo`). The Nim GUI shows none of it. The `messages.timings`
  column already exists in the schema (`db.nim:302`) and nothing writes it.
- **Stop:** the Web UI's send button becomes a stop button mid-generation
  (`ChatFormActionSubmit`). **The Nim GUI's just greys out** (`gui.nim:1548-1553`) —
  once a generation starts there is no way to cancel it short of quitting.

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

**The Nim GUI puts everything into one grey line of text** (`app.notice`,
`gui.nim:1500-1507`). "the server answered 500" is the whole diagnosis a user gets.

### G-20 — The model selector is two hardcoded menu items

Still open, unchanged, and now with the scale stated. The Web UI has a searchable
model list with per-model status (loading/ready/error), capability badges, favourites,
load/unload, and a full model-information dialog showing context size, parameter
count, quantisation, vocabulary size, parallel slots, modalities and the chat template.

**The Nim GUI has "Switch to instruct model" and "Switch to thinking model"**
(`gui.nim:1274-1280`).

Backend exists: `models.discover` / `models.switchModel`.

### G-21 — No trash view

Deleting anything is a soft delete and it goes somewhere. There is no way to see or
restore it from the desktop application.

Backend exists and is tested: `GET /api/fs/trash`, `POST /api/fs/trash/restore`,
`DELETE /api/fs/trash/empty` (`api.nim:435-462`), plus `/<entity>/deleted` and
`/<entity>/<id>/restore` on every table.

### G-17 — The note editor is a plain text box

It is a `TextView` with Save and Close (`gui.nim:1089`). It is the seed of a writing
surface, not one.

### G-36 — Deleting things asks for no confirmation

Every delete in the tree and the conversation list happens on a single click
(`gui.nim:986`, `1014`, `1052`). The Web UI confirms, and shows how many child items a
cascade will take with it (`DialogConfirmation`). Deletes here are soft, which is the
argument that was used for not having a dialog — but a soft delete with no trash view
(**G-21**) is indistinguishable from data loss.

### MCP — still deferred by you, and it is the largest item in the Web UI

Not work. Recorded only so the size is not rediscovered: it is an entire client plus
an agentic tool loop, and it touches prompts, resources, pickers, attachments and
message rendering. Do not pick it up casually.

---

## Standing gap — nothing tests the GUI

All six suites and all five self-test subcommands exercise `jenova-core`: routes,
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
| **G-37** | **Two style rules in `theme.nim` are dead.** `paned > separator` styles a widget that is not in the tree — a leftover from G-25, which shipped as a `Box` after a `Paned` crashed the app. And `.glow-text` is defined and carried by no widget: the glow effect works, but as a `text-shadow` duplicated inside `.brand` and `.conv-active`. **The second half is G-8's exact defect — a class defined and applied to nothing — recurring in the same file.** Both were found and reported on 2026-09-01 and neither was filed as work; that is why they are here. Verified again 2026-09-01: `theme.nim:162`, `theme.nim:251-255` |
| **G-38** | **A code comment in `gui.nim` describes a widget that was never used.** The main-area comment still explains itself as feeding "the `Paned` that G-25 adds". G-25 shipped as a `Box`, and the comment above the `Box` itself records why. A reader following the first comment looks for a `Paned` that does not exist. Prose only, no behaviour. `gui.nim:1053` |
| **T-12** | **Two suites fail whenever the desktop application is actually running, and the trigger is now identified after two sessions of it appearing and vanishing.** Both assume nothing is listening on the machine's real ports. **`test_routes.sh`:** five assertions post to the proxied routes and expect **502**, meaning "the pipeline completed and no `llama-server` answered". The script pins `JENOVA_PORT` for its own core but never overrides `JENOVA_LLAMA_PORT`, so that core forwards to the default **8081**, where the running app's real backend answers — the five then see 200 or 500. **`test_lifecycle.sh`:** it pins `JENOVA_PORT` for its `serve` cases (`:92,98,110`) but runs `backends health` (`:120`) and `backends start` (`:125`) with **no port override at all**, so `health` succeeds when it asserts failure, and `start` refuses with "port 8081 is already in use" instead of the expected missing-model message. **Proven 2026-09-01, dated on both sides:** all six suites passed three times between 09:56 and 09:58; `bin/jenova` was started at **10:01:13**; the failures appear only after. `test_routes` passes **13/13** on the same binary, with the application still running, when given `JENOVA_LLAMA_PORT=<dead port>`. **Neither is a product fault** — the product's "port already in use" refusal is it working correctly. **The fix:** give both scripts their own dead upstream ports, the way they already give themselves their own `JENOVA_PORT`. Not done — a change to test files, outside the approved scope. **Until then, run `nimble suites` with the desktop application closed.** |

**Noted, not work:** `jca_web/src/lib/components/app/workspace/` holds one orphan file,
`FlashModelUpload.svelte`, with an empty `index.ts` and nothing importing it. It is the
one directory under `components/app/` the barrel does not export, so it is **not** part
of the parity inventory. Recorded so it is not rediscovered and mistaken for a gap.
`jca_web` is frozen (D-Z) — this is not a licence to edit it.

---

## Active — defects in the Nim code, each verified by reading it

**Ordering is `PLANS.md`:** T-17 is Step 4 · S-1 is Step 6 ·
T-5, T-2, T-4 and T-3 are Step 9, in that order.

**T-14 is gone from this table because it is done** — renaming a container now moves its
directory (2026-09-01, `PROGRESS.md`, D-BE). Per the completion rule, its record lives
in `PROGRESS.md` and not here.

| ID | What is wrong, in plain English | Where |
|---|---|---|
| **T-17** | **Nothing feeds the search index, so the AI has no recall of past chats.** The search half is finished and proven; the indexer half was never written, so `rag.query` gives up on an empty index. **Scope is decided (D-BD): index chat messages, keyed by conversation, as they are saved, plus a backfill of existing history at startup.** | `rag.nim:323`; the only callers of `indexContent` are in the self-test, `jenova_core.nim:350-356`. Save sites: `gui.nim:296` and the pipeline path |
| **T-5** | **Quitting the app leaves the embedding server running.** Leaving the main model loaded is deliberate — reloading gigabytes into the GPU every start is worse. But the embedding server is left running with nothing attached to it. | `gui.nim:1579` starts them, `gui.nim:1588-1592` stops nothing |
| **T-2** | **A long-running server slowly leaks memory.** The database keeps a cache of compiled queries that is never trimmed, and one API route builds a different query text for every combination of fields a client sends. | `db.nim:46`, `165-175`, `383-389` |
| **T-4** | **Two holes in the file-access containment check.** A *new* file written through a symlinked folder can escape the workspace root, because the symlink check only runs on paths that already exist. Separately, if the workspace root itself is a symlink, legitimate paths get rejected. | `fssync.nim:628`, `641` |
| **T-3** | **The whole conversation is resent to the model every single turn.** No trimming, so a long chat eventually exceeds the context window. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message. | `pipeline.nim:222-286` — there is no trim step |

---

## Watch — looks like a bug we already fixed, but has never been seen

| ID | Item |
|---|---|
| **T-15** | The crash fixed in Session 011 was a widget re-entering the redraw. `Entry` has the same shape: its `text` hook can trigger a redraw, and two of the three Entries have a second thing writing to them (`app.draft` cleared on send, `app.noteTitle` set on rename). **Do not rewrite them.** All eleven crashes were the quit path and none was an `Entry`. Act only if a crash actually shows one. | `gui.nim:830`, `1083`, `1541` |

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
