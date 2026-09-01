# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-09-01 11:37 (Session 014)

**Write plans in plain English, then cite the ID** (**D-BA**). A step that reads
"resolve G-23" tells the reader nothing. Say what the thing is first.

---

## What the program is

A native FreeBSD desktop application written in **Nim**, using **`llama-server`** from
llama.cpp as the inference engine. Those are the only two things in it.

- `bin/jenova` — the desktop application: window, tray, chat, backend control.
- `bin/jenova-core` — the same program without the GUI, for serving over LAN.

Build with `nimble`. **There is no Makefile, no shell script, no Lua and no C in the
product** (**D-AM**, **D-AZ**). Any reference suggesting otherwise is a leftover
pointing at the archived old build, and the fix is deletion or a port to Nim — never a
repair. See **S-1**.

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
is `TODOS.md` G-17, G-20, G-21 and G-28 … G-36.

| Works today | Missing entirely |
|---|---|
| Send a message, stream a reply | Attachments of any kind |
| **Copy, edit, delete, regenerate and continue a message** | Any settings screen — so no sampling parameters |
| **Branching — alternative versions, with a counter** | Import / export of conversations |
| **Generation statistics, context usage, model name** | **A stop button** |
| **A reasoning view for thinking models** | Tables, task lists, LaTeX maths |
| Conversations: create, rename, delete, search | A real model selector and model information |
| **Renaming a container keeps its files** | Typed errors, retry, context-overflow reporting |
| Markdown text and highlighted code blocks | Trash view, delete confirmations, a real note editor |
| Theme, canvas, Neovim page, AI reads the buffer | Recall of past chats — the index is never fed |
| Tray, LAN toggle, backend start/stop | Hardware profile detection and selection |

**Almost all of it is GUI work over backend that is already implemented and has
assertions behind it.**

---

## Standing constraint: the GUI has no test coverage

All six suites and all six self-tests exercise `jenova-core`. **Nothing tests
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

**Step 2 is the next step.**

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

## Step 4 — Make the search index chats, so the AI remembers  *(`TODOS.md` T-17)*

**What is wrong:** `rag.nim` is finished and proven by `rag-selftest` — keyword ranking,
path filtering, snippet persistence, the float32 vector round-trip and the similarity
maths all pass. **Nothing calls `indexContent` outside that self-test**, so the index is
always empty, `rag.query` short-circuits (`rag.nim:323`), and `pipeline.prepare` — which
already queries it on every chat turn — always gets nothing back.

**Scope, decided (D-BD): chats.** Index messages keyed by conversation, so the path
filter the query path already supports scopes a search to one chat or across all of
them.

**The work:**
1. Index a message as it is saved. The save sites are `gui.saveMessage` and the server-side
   path; both already have the conversation id in hand.
2. Use a stable key per conversation so re-indexing replaces rather than duplicates —
   `indexContent` is already idempotent per path (`rag.nim:213` forgets first).
3. Backfill existing history once at startup, so the feature works on day one rather
   than only for chats created after it ships.
4. Indexing must not block the turn: it is worker-thread work, and `db.nim` is already
   per-thread.

**Proof it worked:** extend `rag-selftest` — index a scratch conversation, assert a
query returns the right message, that a conversation-scoped filter confines results, and
that re-indexing the same conversation does not duplicate chunks.

---

## Step 5 — A settings screen, and with it the sampling parameters  *(`TODOS.md` G-31, G-32)*

**What is wrong:** there is **no settings surface at all**, and the consequence is
concrete — `gui.send` posts `{"messages": …, "stream": true}` and nothing else
(`gui.nim:797`), so **temperature, top_p, top_k, min_p, repeat_penalty, frequency and
presence penalty and repeat-last-n cannot be set from the desktop application.** They
are not defaulted badly; they are absent.

**Why this is cheap:** `llama-server` accepts every one of them per request — that is
why **D-AF** closed the old "sampling parameters are ignored" item — and
`pipeline.prepare` passes unknown top-level keys straight through untouched
(`pipeline.nim:285` re-serialises the whole object). So the plumbing is: put the values
in the JSON body.

**The work:**
1. A settings dialog. The Web UI's `ChatSettings` is tabbed: General (system message),
   Display, Sampling, Penalties, Import/Export, Developer. Skip the API-key tab —
   this server does not authenticate — and skip MCP, which is deferred.
2. Persist to a file under `p.state`, the way `lan_mode` already is
   (`gui.nim:173-184`).
3. `gui.send` merges the stored parameters into the request body.
4. **Import/export (G-32) belongs in the same screen** and is a front end over
   `POST /api/db/import`, which is already transactional and asserted (`api.nim:401`).

**Worth copying from the Web UI:** it shows, per parameter, whether the value came from
the user, from the server's `/props`, or from an app default. That distinction is what
stops someone chasing a setting they never actually set.

**One deliberate divergence lands here, recorded so it is not rediscovered as a bug.**
The Web UI has Continue **off by default** (`enableContinueGeneration: false`). This
window shows it unconditionally on the last non-reasoning turn, because with no settings
surface an opt-in flag would make the feature unreachable rather than optional
(**D-BH**). **This step is where it becomes a setting** — and the default should match the
Web UI's once there is somewhere to change it.

**Proof it worked:** assert that a stored temperature reaches the outbound body — a
check on the body-building function, not a live generation.

---

## Step 6 — Hardware profiles in Nim, driven from the GUI  *(`TODOS.md` S-1)*

**What is wrong:** choosing a hardware profile is still two shell scripts, and both are
broken by subtraction — `detect-hardware.sh:19` sources an archived `lib/` file, and one
profile's `jenova-setup` resolves an archived `bin/` helper. Nothing invokes either, so
**there is currently no way to detect hardware or change profile at all** except editing
`etc/jenova.conf` by hand.

**Ruled at D-BC:** it becomes Nim, and it is driven from the window.

**The work:**
1. **Detection in Nim** — CPU model, GPU devices, RAM, swap, OS release. `sysctl` and
   the Vulkan device list, read directly rather than shelled out to.
2. **Scoring in Nim** — each profile's `MATCH_CPU`, `MATCH_GPU_0/1` and `MATCH_OS`
   against what was detected, reproducing the existing ladder: specific hardware beats
   the GPU fallback beats the CPU fallback, and `PROFILE_OPT_IN` profiles never
   auto-match.
3. **Apply in Nim** — write the chosen profile's `jenova.conf` to `$JCA_HOME/etc`, which
   `config.nim` already prefers over the source tree (D-AT2).
4. **A GUI screen** — list the profiles, show which one matched and the score that
   decided it, show the detected hardware beside it, and apply one. Restarting the
   backend afterwards is already a GUI action.
5. **The same as a `jenova-core` subcommand** for headless hosts.
6. **Kernel tuning becomes data.** The sysctl values in the `jenova-setup` scripts move
   into `profile.conf` and Nim applies them, reporting what it could not set without
   privilege rather than failing silently.
7. **Archive both scripts** once this lands, and fix the two Linux filesystem strings
   in the profile data (**S-2**) in the same pass.

**Proof it worked:** scoring is pure logic over data files and belongs in a suite —
feed known hardware descriptions and assert the selected profile, including that an
opt-in profile never wins automatically and that the fallback ladder holds. That is what
the archived `test_validate_arg.sh` never did.

---

## Step 7 — The rest of the chat surface

Ordered by how often it bites.

**7a. A stop button  *(G-33)*** — **statistics are done** (2026-09-01), this is the half
that is left. The send button greys out mid-generation; there is no way to cancel. The
Web UI's turns into a stop button. Cancelling means closing the streaming socket from
the control worker, which is why the two workers are separate. **Watch out for the
`umDone` path:** a cancelled reply still has to be saved with the text it reached, and
with the parent that makes it a sibling rather than an orphan (D-BG).

**7b. Attachments  *(G-30)***
Images, text, PDFs, by file picker, drag-and-drop and paste; thumbnails; full-size
preview; validation against what the model can actually read. Nine Web UI components
cover it. **The storage side already exists** — `fileAssets` rows carry `content`,
`size`, `type` and `uploadDate`, and `fssync.syncFileAsset` already decodes `data:`
base64 payloads to bytes (`fssync.nim:310-337`). Audio recording is the one piece that
may not be worth porting; raise it before building.

**7c. Real error reporting  *(G-35)***
Everything currently lands in one grey line (`app.notice`, `gui.nim:1500`). The Web UI
distinguishes a timeout from a server error and, on a context overflow, shows the
prompt-token count against the context size. `streamOnce` already has the status code
in hand (`gui.nim:130`) and throws it away into a sentence.

**7d. Markdown tables, task lists and maths  *(G-34)***
`markdown.nim` does headings, bullets, quotes, emphasis, inline code and fences. A
model asked to compare things answers with a table, which currently renders as raw
pipes. LaTeX is the larger piece and may reasonably be deferred; tables are not.

**7e. Delete confirmations  *(G-36)***
Every delete in the tree and conversation list fires on one click (`gui.nim:986`,
`1014`, `1052`). The argument for having no dialog was that deletes are soft — but a
soft delete with no trash view (**G-21**) is indistinguishable from data loss, so this
and G-21 answer each other.

---

## Step 8 — The remaining views

**8a. Model selector and model information  *(G-20)*** — replace the two hardcoded menu
items (`gui.nim:1274-1280`) with a searchable list carrying per-model status and
capabilities, plus a details dialog (context size, parameter count, quantisation,
vocabulary, slots, modalities, chat template). Backend exists: `models.discover`,
`models.switchModel`.

**8b. Trash view  *(G-21)*** — everything deleted is soft-deleted and currently
invisible. Backend exists and is asserted: `GET /api/fs/trash`,
`POST /api/fs/trash/restore`, `DELETE /api/fs/trash/empty` (`api.nim:435-462`), plus
`/<entity>/deleted` and `/<entity>/<id>/restore` on every table.

**8c. A real writing surface  *(G-17)*** — the note editor is a `TextView` with Save and
Close (`gui.nim:1089`). It is the seed, not the thing.

---

## Step 9 — Stability, none of it urgent

In this order, smallest first:

| | Work | Proof |
|---|---|---|
| **T-5** | Stop the embedding server on exit. `gui.run`'s `defer` joins threads and stops nothing (`gui.nim:1588`); `lifecycle.stopAll` already exists. Leaving the *agent* model loaded is deliberate — reloading gigabytes into VRAM every start is worse — so stop only the embed backend, and clear a pidfile whose process is dead | `jenova-core backends status` after a GUI exit: agent up, embeddings down, no stale pid |
| **T-2** | Cap the database's prepared-statement cache. It is a plain `Table` that never evicts (`db.nim:46`, `165`) and finalizes only at connection close (`db.nim:383`), while the message-update route builds a different SQL string per field combination. **The fix belongs in `db.nim`** — a cap plus finalize-on-evict — not in the caller | A suite issuing many distinct field combinations, asserting the cache stays capped. Prove it can go red first |
| **T-4** | Both directions of the file-containment check. The symlink check only runs on paths that already exist (`fssync.nim:641`), so a *new* file written through a symlinked parent escapes; and `normBase` is lexical (`fssync.nim:628`), so a symlinked workspaces root rejects legitimate paths. Resolve the deepest existing ancestor and compare against a resolved base | `test_api_fs.sh`: a write through a symlinked parent is refused **403**; a legitimate write under a symlinked root succeeds |
| **T-3** | Trim chat history. The whole conversation is resent every turn (`pipeline.nim` has no trim step), so a long chat eventually exceeds the context. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message | A unit check on the trim function at a small budget — not a live generation |

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
