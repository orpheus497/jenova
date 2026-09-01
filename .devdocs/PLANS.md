# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-09-01 16:19 (Session 017)

**Write plans in plain English, then cite the ID** (**D-BA**). A step that reads
"resolve G-23" tells the reader nothing. Say what the thing is first.

**Cite the symbol, then the line.** Every line reference below was re-derived against
the source on **2026-09-01 at 16:19**, with `gui.nim` at 3,837 lines. **This is the
fifth sweep in one day** and each was made stale by the next block of work. That is the
point rather than an embarrassment: **a reference that names the proc survives; a bare
line number does not.** Read the symbol and treat the number as a hint.

---

## What the program is

A native FreeBSD desktop application written in **Nim**, using **`llama-server`** from
llama.cpp as the inference engine. Those are the only two things in it.

- `bin/jenova` — the desktop application: window, tray, chat, backend control.
- `bin/jenova-core` — the same program without the GUI, for serving over LAN.

Build with `nimble`. **There is no Makefile, no shell script, no Lua and no C in the
product** (**D-AM**, **D-AZ**). Any reference suggesting otherwise is a leftover
pointing at the archived old build, and the fix is deletion or a port to Nim — never a
repair. **As of 2026-09-01 the product tree has no shell script left at all** — the last six were archived by Step 6.

**Finished, working and confirmed on screen:** configuration, database, threaded HTTP
server, the whole `/api/*` surface, the filesystem mirror, the retrieval *engine*, the
prompt pipeline (intents, RAG injection, personas, tool stripping, response cache),
backend supervision and watchdog, model discovery and switching, the GTK4 window,
theme and canvas, the tray, conversation persistence, the workspace tree, notes,
markdown with syntax-highlighted code blocks, the embedded Neovim page, and the
`Editor:` intent that feeds the live Neovim buffer to the model.

---

## Where the work stands

**The 2026-08-31 23:28 build has been run by the USER.** The four items built that day
— the Neovim page transparency fix, the right-hand document panel, the editor-page
framing and the colour work — are run. **No appearance defect was reported from that
run.** The report was that the GUI is missing a large number of Web UI features.

**So the outstanding work is functional, not visual.**

**The parity scope carried since Session 010 was wrong by omission.** It named six
items (a file browser, an editor, file awareness, Neovim, a model selector, a trash
view) and was written from a summary rather than from the Web UI. Re-derived
2026-09-01 by reading `jca_web/src/lib/components/app/*/index.ts` — the barrel files
that name and describe every shipped component. The real list is three times larger and
is `TODOS.md` G-17, G-20, G-21 and G-28 … G-36. G-28 … G-33 and G-39 are built.

| Works today | Missing entirely |
|---|---|
| Send a message, stream a reply | **PDF text extraction** (gated: needs zlib) |
| Copy, edit, delete, regenerate and continue a message | **Audio capture** (raise first) |
| Branching — alternative versions, with a counter | **LaTeX maths** |
| Generation statistics, context usage, model name | A real model selector and model information |
| A reasoning view for thinking models | A trash view, a real note editor |
| Conversations: create, rename, delete, search | — |
| **Stop a generation · tables · typed errors · delete confirmations** | — |
| **Attachments: picker, drag-and-drop, paste, thumbnails, preview** | — |
| Renaming a container keeps its files | — |
| Markdown text and highlighted code blocks | — |
| Recall of past chats — the index is fed | — |
| **Settings: every sampling and penalty parameter** | — |
| **Hardware profiles: detection, scoring, a screen** | — |
| **Import / export of conversations** | — |
| Theme, canvas, Neovim page, AI reads the buffer | — |
| Tray, LAN toggle, backend start/stop | — |

**Almost all of it is GUI work over backend that is already implemented and has
assertions behind it.**

---

## Standing constraint: the GUI has no test coverage

All six suites and **all nine** self-tests exercise `jenova-core`. **Nothing tests
`gui.nim`.** Every GUI defect in this project's history was found by the USER looking
at the screen, and that is the loop the steps below are meant to stop repeating.

The work ahead is mostly *logic* — branching trees, message mutation, parameter
plumbing — not layout. **Every step below names what would prove it worked**, and where
that can be an assertion rather than a screenshot, it must be. A new suite is not
believed until it has been shown to go red (**this project has twice shipped a suite
that reported PASS while asserting nothing**).

---

## Step 1 — **BUILT 2026-09-01.** Renaming a container no longer loses its files

Done and out of this plan. Renaming a workspace, project or folder now moves its
directory, a move that cannot be done rolls the row back, and a rename onto an occupied
path is refused rather than merged (**D-BE**). Proven by 17 new assertions in
`tests/test_api_fs.sh`, shown going red against the unfixed source first. The record is
`PROGRESS.md` 2026-09-01 09:58.

**The step numbers below are deliberately unchanged.** `TODOS.md`, `TESTS.md` and
`BRIEFING.md` all cite them, and renumbering to close a gap would silently re-point
every one of those references.

**Steps 1 to 7 are built. Step 8 is the next step**, with what remains of
attachments (7b) alongside it.

---

## Step 2 — **BUILT 2026-09-01.** A message carries its actions again

Done and out of this plan. Copy, edit, delete, regenerate and continue, over a `Message`
that now carries its row id — which was the change the other four rested on. The record
is `PROGRESS.md` 2026-09-01 10:17; the scoping call is **D-BF**.

**The two restrictions it shipped under were lifted the same day by Step 3** (D-BF →
D-BG): edit resends, regenerate works on any reply. Continue stays on the last turn, and
is additionally hidden on a turn carrying reasoning (**D-BH**).

**Continue shipped broken twice and was repaired the same day.** The request has to carry
**both** `continue_final_message` and `add_generation_prompt: false` — the first alone is
refused with HTTP 400. See `PROGRESS.md` 2026-09-01 11:37 and **D-BH**. The request body
now lives in `pipeline.chatBody`, below the GUI, so a self-test can see it.

---

## Step 3 — **BUILT 2026-09-01.** Conversation branching

Done and out of this plan. `App.messages` is the active path and `App.allMessages` is the
tree; `messages.parent` holds the shape and `conversations.currNode` holds the branch
being read. Prev/next arrows and a "2/3" counter appear on any turn that has more than
one version. The record is `PROGRESS.md` 2026-09-01 10:50; the behaviour is **D-BG**.

**It released both of D-BF's restrictions:** edit now resends, and regenerate works on
any reply rather than only the last.

**The tree walk went into `api.nim` as three pure functions**, not into `gui.nim`, so it
could be asserted at all — a wrong tree walk draws a plausible transcript with the wrong
turns in it. `jenova-core tree-selftest`, **26 assertions** — 15 over a hand-written fork
shape, and 11 added after the USER found that the first 15 covered only the shape
branching *creates* and never the flat shape it *inherits*.
**That makes six self-tests, not five.**

**Also built in the same pass, out of order and on the USER's instruction:** the
generation statistics half of **Step 7a** (G-33) and a **reasoning view** (G-39). See
`PROGRESS.md`. Step 7a survives, reduced to the stop button.

---

## Step 4 — **BUILT 2026-09-01.** The search index has chats in it, so the AI remembers

Done and out of this plan. **`indexContent` had no caller outside its own self-test**,
so the index was always empty, `rag.query` short-circuited on its second line, and
`pipeline.prepare` — which asks it a question on every chat turn — always got nothing
back. The engine was finished and starved. It is fed now: a completed exchange is
indexed from both surfaces, existing history is backfilled once the embedding server
answers, and a deleted turn is forgotten. The record is `PROGRESS.md` 2026-09-01 12:08;
the calls taken inside the scope are **D-BI**.

**A message occupies `chat/<convId>/<role>/<id>`**, which makes the `pathFilter` the
query path already had do the scoping — `chat` is every conversation, `chat/<convId>` is
one — with no change to `query`.

**Three things this step decided that the plan above had not** (all in D-BI): an
exchange is indexed when the **reply** lands rather than each message as it is written,
because a question indexed at save time is in the index before its own request is
answered and comes back as its own top-ranked context; the backfill waits for the
**embedding server** rather than running at startup, because indexing while it loads
stores chunks with no vector and leaves all of history keyword-only; and deletion
**forgets**, because an index that keeps answering with removed turns honours the
deletion everywhere except where the user would notice.

**Proven by 14 new assertions** — 10 in `rag-selftest` and 4 in `pipeline-selftest`,
each shown going red first. The `pipeline-selftest` four are the *wiring*, which is the
half a unit check cannot see: an indexed turn is retrieved and lands in the body sent to
the model. See `TESTS.md` §0e.

**The step numbers below are deliberately unchanged**, for the reason Step 1 records.

---

## Step 5 — **BUILT 2026-09-01.** A settings screen, and with it the sampling parameters

Done and out of this plan. There was no settings surface at all, so every sampling
and penalty parameter was *absent* from the request rather than defaulted badly.
There is one now — a floating panel over the window, six sections, 1:1 with the
Web UI's `ChatSettings` minus API Key and MCP (excluded by the USER) and minus the
fields whose feature does not exist here yet (**D-BK**). Import/export (G-32)
landed in the same screen. The record is `PROGRESS.md` 2026-09-01 12:55.

**The new module is `src/jenova/settings.nim`** — fields, store, validator and the
merge, all below the widget layer, which is what made the whole feature assertable
without a window. `pipeline.chatBody` takes the settings and merges them last.

**Two things this step decided that the plan above had not**, both in D-BK: **an
empty value is not sent at all** rather than sent as a zero, because a typed store
cannot tell "the user asked for 0.0" from "the user never touched it" and a
defaulted 0 on every parameter would silently override the server's own preset
while looking like a working screen; and the source indicator was worth copying
because it reuses the `/props` call already being made.

**Step 5a followed on 2026-09-01 13:52**, from the USER running the build: the
panel was transparent and unreadable, the tuneables needed real guidance, and the
field set was to be **1:1 with the Web UI's, skipping API and MCP** (**D-BL**,
superseding D-BK's narrower rule). Twelve fields added, eight of them with the
behaviour they govern built in the same pass — a light palette, a following
transcript, conversation auto-titling, a code-block cap, a raw-output toggle. The
four that need attachments are drawn, stored and marked *"not yet in effect"*
with the step that turns them on. The record is `PROGRESS.md` 2026-09-01 13:52.

**D-BH's deliberate divergence is closed here as planned:** Continue is a setting
now, off by default, matching the Web UI.

**Proven by 25 assertions**, each shown going red first, by seven independent
corruptions producing seven different sets of red. **One of them initially
passed, and that found a hole in the assertion set rather than in the code** —
nothing asserted that `custom` JSON can override the fields the body sets for
itself, which is the whole point of an escape hatch. **The parity claim is itself
asserted**, so a field dropped or renamed later goes red and names itself. See
`TESTS.md` §0g.

**The step numbers below are deliberately unchanged**, for the reason Step 1
records. **Step 6 is the next step.**

---

## Step 6 — **BUILT 2026-09-01.** Hardware profiles in Nim, driven from the window

Done and out of this plan. Choosing a profile was two shell scripts that had not run
since their `lib/` was archived, so there was no way to detect hardware or change
profile at all. There is now: **`src/jenova/hardware.nim`** — detection, the
`profile.conf` reader, the scorer and apply — a **Hardware screen** in the window, and
**`jenova-core hardware detect|list|apply`** for headless hosts. The record is
`PROGRESS.md` 2026-09-01 15:13.

**The scoring ladder was ported from `match_profile` against the script**, not against
this plan's own summary of it — which had lost the detail that a `MATCH_OS`, `MATCH_CPU`
or `MATCH_SWAP` mismatch **disqualifies** a profile rather than merely scoring it zero.

**Kernel tuning was deliberately not ported (D-BN).** Jenova applies no `sysctl` and
never writes `/etc/sysctl.conf`. All six shell scripts are archived to
`.devdocs/ARCHIVE/hardware-profiles/` and nothing replaces them; **the product tree now
contains no shell script at all.** S-2's two Linux filesystem strings were fixed in the
same pass, and the doc references telling the USER to `sudo` a `jenova-setup` were
deleted rather than repaired.

**Proven by 13 assertions in a seventh self-test, `hardware-selftest`**, with three
independent corruptions giving three different sets of red. **One corruption initially
passed** — removing the `-8` left the two candidate profiles tied at 35, and the right
one still won because it sorts first and the sort is stable. That is rule 16 working:
the hole was in the assertion set, which checked the winner's *name* and not the
*margin*. Fixed, and the corruption then went red naming the tie. See `TESTS.md` §0i.

**Two things worth carrying forward:**

1. **A green self-test said nothing about detection against a real machine.** The first
   real run reported **no GPU at all** and matched the wrong profile, because
   `llama-server` cannot load without `LD_LIBRARY_PATH` pointing at `paths.llamaLibDir`
   — `lifecycle.start` sets it and `detectGpu` did not. **An unloadable binary and a
   machine with no GPU produce the same empty string**, so it failed silently. This is
   rule 15 in a new costume: the parts were asserted, the *join* to the environment was
   not.
2. **`applyProfile` never writes `jenova.local.conf`**, and that is asserted, because
   silently discarding the USER's machine file is the one way this feature could do real
   damage.

**Not verified: the screen itself.** `--check` builds the widget tree, but the panel's
contents are drawn only when open — the same as the settings panel. That is a USER run.

**The step numbers below are deliberately unchanged**, for the reason Step 1 records.
**Step 7 is the next step.**

---

## Step 7 — **BUILT 2026-09-01.** The rest of the chat surface

**All five parts are built.** The stop button (G-33),
markdown tables and task lists (G-34), typed errors with Retry (G-35) and delete
confirmations (G-36). The record is `PROGRESS.md` 2026-09-01 15:46.

**Two calls taken inside the scope, recorded as D-BO and D-BP.** Attachments
(7b) are built too, with two formats left that are each gated on a decision
rather than on work — see below.

**7b. Attachments *(G-30)* — built, except two formats that are each gated.**
**All three of the Web UI's routes in work**: a file picker, drag-and-drop onto
the chat column (`DropZone`, a renderable, because owlkettle exposes no way to
reach a `GtkWidget` from a `gui:` block), and paste of an image from the
clipboard. Chips carry **real thumbnails**, clicking one opens a **full-size
preview**, and a sent turn shows what was attached to it.

**The classifier moved below the widget layer** — `pipeline.readAttachment`,
`looksTextual`, `mimeForImage`, `uriToPath` — which is what made it assertable,
and was forced anyway: the drop drain runs inside the window's own timer, where a
proc taking the GUI's state type does not yet exist.

**What is left, and neither is an omission:**

1. **PDFs — gated on a dependency decision.** Extraction needs FlateDecode, i.e.
   zlib inflate. Nim's stdlib has none, so it means linking `libz` — present at
   `/usr/lib/libz.so.1`, zlib licence, which AGENTS.md permits. **Directive 1
   gates a dependency change, so this is the USER's call.** `contentFor` already
   sends a PDF that carries text or page images, which an imported Web UI
   conversation has.
2. **Audio capture — raise before building**, as this plan has said since 7b was
   written. `input_audio` parts are already emitted; nothing records. It needs
   `/dev/dsp` ioctl work or a capture library, **and no model in use has an audio
   modality**, so it may buy nothing.

**Proof:** `attach-selftest`, **27 assertions**, five clean reds across two
rounds. The part order is asserted, so a divergence from the Web UI names itself;
so are the URI decode, the NUL-byte text test and the vision refusal in both
directions. What is *not* asserted, and cannot be from here: the picker, the
chips, the thumbnails, the drop target and the paste button are widgets.

**LaTeX maths is deliberately still open** under G-34. Tables were the half that
bites; KaTeX has no GTK equivalent and rendering maths is its own project.

---

## Step 8 — The remaining views

**8a. Model selector and model information  *(G-20)*** — replace the two hardcoded menu
items (`gui.nim:3312`, `gui.nim:3316`, mirrored in the tray at `gui.nim:639,641`) with a
searchable list carrying per-model status and
capabilities, plus a details dialog (context size, parameter count, quantisation,
vocabulary, slots, modalities, chat template). Backend exists: `models.discover`,
`models.switchModel`.

**8b. Trash view  *(G-21)*** — everything deleted is soft-deleted and currently
invisible. Backend exists and is asserted, all inside `api.handleFs` (`api.nim:625`):
`GET /api/fs/trash` (`api.nim:631`), `POST /api/fs/trash/restore` (`api.nim:639`),
`DELETE /api/fs/trash/empty` (`api.nim:647`), plus `/<entity>/deleted` and
`/<entity>/<id>/restore` on every table (`api.nim:802`, over `api.restoreItem`).

**One thing this step now also has to do**, recorded here rather than left to be
rediscovered: **restoring a message from the trash does not put it back in the retrieval
index.** Deletion forgets (D-BI) and nothing undoes that, so a restored turn is
recoverable everywhere except in what the model recalls until the next start, when
`rag.backfillChats` picks it up. Restore should call `rag.indexExchange` directly.

**8c. A real writing surface  *(G-17)*** — the note editor is a `TextView` with Save and
Close — `gui.saveNote` (`gui.nim:1252`). It is the seed, not the thing.

---

## Step 9 — Stability, none of it urgent

In this order, smallest first:

| | Work | Proof |
|---|---|---|
| **T-5** | Stop the embedding server on exit. `gui.run` (`gui.nim:3713`) starts both backends and its `defer` (`gui.nim:3724-3728`) only sends the workers the quit sentinel, joins them and closes the channels — `lifecycle.stopAll` (`lifecycle.nim:329`) already exists and is reached only from the tray's stop/restart actions (`gui.nim:681`, `685`), never from exit. Leaving the *agent* model loaded is deliberate — reloading gigabytes into VRAM every start is worse — so stop only the embed backend, and clear a pidfile whose process is dead | `jenova-core backends status` after a GUI exit: agent up, embeddings down, no stale pid |
| **T-2** | Cap the database's prepared-statement cache. It is a plain `Table` that never evicts — `Conn.cache` (`db.nim:46`) filled by `db.prepared` (`db.nim:165-174`) — and the only `sqlite3_finalize` is the shutdown loop in `db.closeConn` (`db.nim:415-419`), while `api.updateMessage` builds a different SQL string per field combination. **The fix belongs in `db.nim`** — a cap plus finalize-on-evict — not in the caller | A suite issuing many distinct field combinations, asserting the cache stays capped. Prove it can go red first |
| **T-4** | Both directions of the file-containment check, both inside `fssync.resolveStoragePath` (`fssync.nim:694`). The symlink check runs only on paths that already exist (`fssync.nim:713`), so a *new* file written through a symlinked parent escapes; and the base is compared lexically (`fssync.nim:700`), so a symlinked workspaces root rejects legitimate paths. Resolve the deepest existing ancestor and compare against a resolved base | `test_api_fs.sh`: a write through a symlinked parent is refused **403**; a legitimate write under a symlinked root succeeds |
| **T-3** | Trim chat history. The whole conversation is resent every turn — `pipeline.prepare` (`pipeline.nim:223`) has no trim step and neither does anything else in the file — so a long chat eventually exceeds the context. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message | A unit check on the trim function at a small budget — not a live generation |

---

## Waiting on a decision from the USER

**Nothing in Steps 1-9 is blocked.** Q-31 and Q-32 were answered on 2026-09-01 (D-BD,
D-BC) and became Steps 4 and 6.

Three product decisions remain parked, none of them on the critical path:

- **Filesystem as the source of truth** (`TODOS.md` T-11, D-AQ). The expensive half
  already exists. Must not be entangled with the GUI work above.
- **How the binaries get installed** (T-7).
- **A CLI** (T-8), gated by D-AI.

---

## Standing rules for whoever picks this up

- **If it was not executed, it is not stated — and if it was executed, do not deny it.**
  A "not yet run" label lasts until the first evidence against it. Carrying one past
  that point has cost two sessions.
- **Explain, then cite.** Never hand over a plan whose steps are bare IDs (**D-BA**).
- **Everything is driven from the GUI** (**D-BC**). A feature that needs a terminal, a
  shell script or a hand-edited file is not finished.
- **The archived shell/Lua build is not work.** Delete the reference or port it to Nim
  (**D-AZ**). Do not put "archive or port?" to the USER — both sit inside the standing
  ruling and the choice is the session's.
- **Check whether it already exists before writing it.** `std/json`, `upstream.nim`,
  `paths.nim`, and — repeatedly — an API route that is already implemented and tested.
- **Verify a scope against the source, not a summary.** The old six-item parity list is
  why this plan had to be rewritten.
- **A compile is not verification for layout** (**D-AR**). `nimble gui` exiting 0 says
  the widget tree is valid, never that it is right.
- **A new suite must be proven able to fail** before it is believed.
- **Sizing APIs are minimums.** `min-width`, `sizeRequest` and a flap's `width` each set
  a floor. To make something small, make the thing itself small.
- **`Box`'s adder defaults to `expand: true`**, and in a vertical Box that is `vexpand`.
  Annotate every child.
