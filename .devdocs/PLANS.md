# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-09-02 09:43 (Session 020)

**Write plans in plain English, then cite the ID** (**D-BA**). A step that reads
"resolve G-23" tells the reader nothing. Say what the thing is first.

**Cite the symbol. Do not cite the line.** Seventh sweep, 2026-09-01 18:07: every
finding in this file and in `TODOS.md` is **still true**, and the addresses split
cleanly by file. Every citation into `db.nim`, `fssync.nim`, `pipeline.nim`,
`theme.nim` and `lifecycle.nim` was **correct**; every citation into `gui.nim` and
`api.nim` was **wrong**, because G-40's fix and G-41 took `gui.nim` from 3,916 to
**4,019** lines. **Seven sweeps have now corrected the same two files' addresses and
all seven rotted.** The bare numbers into those two files are therefore deleted rather
than re-derived an eighth time; a reference names the symbol and stops.

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

All six suites and every self-test exercise `jenova-core`. **Nothing tests `gui.nim`.**
*(Read the self-test list out of `src/jenova_core.nim`. A count written here has been
wrong repeatedly — rule 9.)* Every GUI defect in this project's history was found by the USER looking
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

**Steps 1 to 7 are built, and Step 7c has repaired the defect Step 7 shipped with
(G-40, the window froze on any attachment). Step 8 is the next work.** Step 7d —
where attachment payloads are stored — is a decision for the USER, not scoped work.

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

**Both remaining items are settled — 2026-09-02, and 7b is closed.**

1. **PDFs — BUILT.** **libz is an approved dependency (D-BY)**, ruled by the USER
   after they had given the same answer across several sessions. New
   `src/jenova/zlib.nim` (bound as `uncompress`/`compress` only, so no versioned
   struct is mirrored — D-V) and `src/jenova/pdf.nim` (content streams and the
   four text-showing operators). `readAttachment` attaches a PDF as its extracted
   text in the Web UI's own PDF shape. **A PDF with no readable text is refused,
   never attached empty.**
2. **Audio capture — NOT BUILT and not gated (D-BZ).** Ruled by the USER: they do
   not need it. **It is not to be put to them again.** The `input_audio` *send*
   path stays under Directive 3 — it carries imported Web UI conversations, and
   not building capture is not licence to delete what already sends.

**Proof:** `attach-selftest`, **27 assertions**, five clean reds across two
rounds. The part order is asserted, so a divergence from the Web UI names itself;
so are the URI decode, the NUL-byte text test and the vision refusal in both
directions. What is *not* asserted, and cannot be from here: the picker, the
chips, the thumbnails, the drop target and the paste button are widgets.

**LaTeX maths is deliberately still open** under G-34. Tables were the half that
bites; KaTeX has no GTK equivalent and rendering maths is its own project.

---

## Step 7c — **BUILT 2026-09-01 17:51.** Attachments no longer freeze the window (G-40)

Done and out of this plan. The record is `PROGRESS.md` 2026-09-01 17:51; the cap
and the refusal are **D-BQ**.

**What was actually wrong, kept because it is the general lesson:** the thumbnail
cache built its key as `sha256(payload)` **on the line above the lookup that key
served**. The decode was cached and the key was not, so the expensive half ran on
every frame — a cache that guaranteed the cost it existed to avoid. Alongside it,
`view` re-parsed every attachment's JSON and every message's markdown per frame,
and `postConversation` re-parsed every payload again on every send.

**The rule this step establishes, and it is the durable part:** *nothing inside
`view` may do work proportional to a payload.* `view` runs on every frame; a proc
called from it may look things up and must not parse, hash, decode or copy.

**One thing the plan had wrong, recorded rather than quietly dropped.** 7c-4 said
the body build should move off the GTK thread to the stream worker. **It should
not, and the reason is worth keeping:** the worker would need the message history,
so the payloads would cross the channel instead — the same copy, in the other
direction. The real waste was that `postConversation` *re-parsed* every payload,
not that it ran where it ran. Routing it through the memo removed that; the string
build and the single channel copy stay on the GTK thread deliberately.

**A second thing worth carrying:** the memo keeps **both** the original node and
the reduced attachment list from one parse. The reduced form drops `AUDIO` and
flattens `PDF` because this window cannot draw either — so building the outbound
request from it, which was the obvious implementation, would have silently stopped
sending audio and PDF page images that an imported Web UI conversation carries
(D-BP). That is asserted in both directions now.

**Proof: 17 new assertions in `attach-selftest`, three independent corruptions,
three clean reds** — one of them (deriving the key from the payload) re-creating
the original defect exactly. **Two real bugs were caught by the new assertions as
they were written:** `for i, e in` over a `JArray` resolves to `pairs` and aborts
the process, and truncating division reported a 25.001 MB file as *"is 25 MB and
the limit is 25 MB"*. Ten self-tests pass, both binaries build ELF 64-bit FreeBSD,
`bin/jenova --check` exits 0.

**Not verified, and it is the whole point of the step:** whether the window is
actually responsive with a document attached. There is no GUI test coverage,
`--check` presses nothing, and the parse counters prove the work is not repeated
but cannot prove the frame budget is met. **That is a USER run.**

---

## Step 7c, as planned — kept for the record

**Reported by the USER 2026-09-01:** attaching a document locks the GUI up
completely and the only way out is to kill it. **This outranks Step 8.** Step 8
adds views; this one makes a feature that already shipped usable at all.

**The full mechanism, with all four contributing sites, is `TODOS.md` G-40.** In
one sentence: `view` re-parses every attachment's JSON and re-hashes every base64
payload **on every frame**, `postConversation` rebuilds and re-inlines the whole
history **on the GTK thread on every send**, nothing caps the input, and every
payload is held two or three times over.

### The rule this step establishes

**Nothing inside `view` may do work proportional to a payload.** `view` runs on
every frame; a proc called from it may look things up and must not parse, hash,
decode or copy. That is the general form of the rule the comment at
`gui.nim:3624-3627` already stated for thumbnails and that the thumbnail work then
broke. **Writing it down here is the point of the step** — G-40 is the third time
this project has shipped a per-frame cost (the canvas `redraw` at `gui.nim:1035`
and the code-block cap were the first two).

### The work, in order, smallest and most assertable first

**7c-1 — Give an attachment an identity that is not its content.**
`pipeline.Attachment` (`pipeline.nim:542`) gains a `key` field, set **once** by
`readAttachment` from the file's name, size and mtime — never from the payload.
`gui.attachmentPixbuf` then keys `thumbCache` on `$size & ":" & a.key` and the
per-frame SHA-256 disappears. A stored attachment read back from `extra` gets its
key from the row: `m.id & ":" & $index`, which is stable and already unique.

**7c-2 — Parse `extra` once per message, not once per frame.**
`gui.attachmentsOf` moves below the widget layer as `pipeline.parseAttachments`,
and behind it goes a small memo keyed by message id. `view` gets a lookup.
**The memo carries a `parses` counter**, which is what makes the fix itself
assertable rather than merely believed — see the proof section.

**7c-3 — Cap the input, and refuse rather than truncate.**
A size limit in `pipeline.readAttachment`, refused with a reason naming the limit
and the actual size. **Refusal over truncation** because a silently shortened
document changes what the model was asked about while looking like it worked —
the same class of defect as D-BK's "unset value sent as a zero". *This is the one
open product question in the step; see the bottom.*

**7c-4 — Get the body build off the GTK thread.**
`postConversation` currently builds the whole outbound body, inlining every image,
in the Send handler. The body build moves to the stream worker: the job carries
what the worker needs to build it, not the built string. This also stops the
multi-megabyte channel deep-copy at `gui.nim:1637`.

**7c-5 — Memoise `markdown.parse` for completed messages.**
Same shape as 7c-2, same memo, keyed by message id. **The live streaming turn is
excluded** — its text changes every token, so memoising it would show a stale
transcript. That exclusion is the part to get right and the part to assert.

### What proves it worked

**The honest split first: the freeze itself cannot be asserted from here.** There
is no GUI test coverage (`BRIEFING.md` §6), `--check` presses nothing, and a
timing assertion would be flaky. **Only the USER running it settles the report.**

**But the fix is not therefore unprovable** — the rule-15 move is to assert the
*join*, and here the join has a natural counter:

| | What is asserted | Where |
|---|---|---|
| 7c-1 | A key is set at read time, is stable across calls, differs for different files, and **is unchanged when only the payload differs** | `attach-selftest` |
| 7c-2 | Calling `parseAttachments` for one message id **100 times increments `parses` exactly once** — this is the fix, stated as an assertion that bites | `attach-selftest` |
| 7c-3 | A file over the cap is refused, the reason names both sizes, and one under it is accepted | `attach-selftest` |
| 7c-4 | The body the worker builds is **byte-identical** to the one `postConversation` built before the move | `pipeline-selftest` |
| 7c-5 | A completed message parses once; **a message whose text changed re-parses** | `attach-selftest` |

**Every one of the above is to be shown going red first**, against the unfixed
source where that is possible and against a deliberate corruption where it is not.
The 7c-2 and 7c-5 counters are the two that matter: they are the only assertions in
this project that would catch a per-frame cost being reintroduced, and **that is
exactly how G-40 got in.**

**`bin/jenova --check` must still exit 0** before this is handed over (rule 17).

### What is deliberately not in this step

**The storage shape (mechanism D).** Payloads live inline in `messages.extra` by
D-BP, so they are copied into `allMessages`, again into `messages`, and again into
the body. The real answer is to store the bytes beside the row and keep a reference
in `extra` — but that **changes the D-BP shape the frozen Web UI reads**, and D-Z
makes `jca_web` unreadable-and-unwritable, so a conversation would stop moving
between the two surfaces unconverted. **That is a decision for the USER, not a
session**, and it is written up as **Step 7d** below rather than folded in here.

**T-3 is adjacent and stays where it is.** Untrimmed history is what makes B
unbounded, but trimming is Step 9 work with its own proof and should not be
smuggled into a defect fix.

---

## Step 7d — **CLOSED 2026-09-01 18:41.** Attachment storage: parity, inline stays

**Ruled: parity with the Web UI (Q-34, amended into D-BV).** The inline payload stays
exactly as D-BP stores it and the `fileAssets` artefact of 10b is written **in addition**,
so nothing about the message row changes and a conversation still moves between the two
surfaces unconverted. The memory and per-turn upload cost is accepted deliberately; Step
7c is what makes it tolerable and the USER has run and confirmed that. **T-3 is what
makes the per-turn cost unbounded and it is still Step 9.** The original write-up follows.

Inline payloads in `messages.extra` (D-BP) are why
a single conversation holds each image three times in memory and re-uploads it on
every turn. Storing the bytes beside the row and keeping a reference would fix all
of that — **and would diverge from the frozen Web UI's shape**, which D-BP chose
deliberately so conversations move between the surfaces without conversion.

**The trade is:** parity with `jca_web`'s storage, against memory and per-turn
upload cost. Both are real. **Raise it after Step 7c is run and seen to work** —
7c may well make the inline shape acceptable, which would settle this at no cost.

---

## Step 8 — The remaining views

**Every reference in this step was re-verified against the source on 2026-09-01 at
18:07, and is written as a symbol with no line number** — the seventh sweep found
every `gui.nim` and `api.nim` address in this file stale while every address into the
stable modules held. The policy, and the evidence for it, is the sweep note at the top
of `TODOS.md`.

**Recommended order: 8b, then 8a, then 8c.** 8b is the smallest, it is the one the
codebase already argues for in a comment of its own, and it closes a data-loss-shaped
hole that G-36 half-opened by making deletion easy and confident.

---

### 8b. **BUILT 2026-09-01 19:05.** Trash view *(G-21)*

Everything deleted is soft-deleted and currently invisible from the desktop
application. **`gui.nim` has no trash surface at all** — its only `trash` matches are
the `user-trash-symbolic` icons on four delete buttons, and a comment stating that
with no trash view a soft delete is indistinguishable from data loss. That comment is
the case for this step.

**The backend exists and is asserted. Do not write a route.** Inside **`api.handleFs`**:
`GET /api/fs/trash` over `fssync.getTrash`, `POST /api/fs/trash/restore` over
`fssync.restoreTrash`, `DELETE /api/fs/trash/empty` over `fssync.emptyTrash`. Inside
**`api.handleDb`**: `/<entity>/deleted` and `/<entity>/<id>/restore` on every table,
over **`api.restoreItem`**, which walks parents to a depth of 8 and revives a
conversation's messages with it.

**The one piece of real logic in the step, and it is below the widget layer where it
can be asserted: restoring a message does not put it back in the retrieval index.**
Confirmed by reading `api.restoreItem` on 2026-09-01 18:07 — it flips `is_deleted`,
walks its parents, returns, and contains no `rag.*` call, while the delete path calls
`rag.forgetMessage`. Deletion forgets (D-BI) and nothing undoes it, so a restored turn
comes back everywhere except in what the model recalls — until the next start, when
`rag.backfillChats` silently repairs it, **which is exactly the shape of bug that hides
for weeks** (rule 15). `restoreItem` should call `rag.indexExchange` for a restored
message.

**What proves it worked:** the re-index is a `db-`/`rag-selftest` assertion — index an
exchange, delete it, assert `rag.query` no longer returns it, restore it, assert it
comes back **without** a `backfillChats` call. Shown going red against the unfixed
source first. The view itself is widgets and is a USER run.

---

### 8a. **SHIPPED AND WRONG — reopened 2026-09-02.** Model selector *(G-20, G-48)*

Recorded as built at 08:43; the USER ran it and it does not work. **The symptom is not
known** and is not to be guessed at (rule 1, D-AN).

**The shape is also wrong, and that is settled — D-CB.** It must draw from
`models/instruct` and `models/thinking` only, swap `models/agent`, and stop accumulating
`.old` copies. What shipped scans every subdirectory, so it offers embed and draft models
as the agent model.

**The work:**

1. Narrow `models.available` to the two source folders.
2. Replace the `.old` chain with something that does not fill the directory.
3. One switch surface in the window, not two (D-CB supersedes D-CA).
4. Find out what the reported failure actually is before changing the panel.

**In the tree now:** `models.available`, `activeAgentPath`, `switchToPath` in
`models.nim`; `gui.modelsPanel`; `models-selftest`. **`switchModel` and
`jenova-core models switch` are untouched and still work.**

**Model information was never built** — context size, quantisation, vocabulary, chat
template need `/props` plus a GGUF header read. Separate work.

The original write-up follows.

---

### 8a as planned — kept for the record. **Rewritten 2026-09-02 08:01 against the source**

Replace the two hardcoded menu items — the literals **"Switch to instruct model"** and
**"Switch to thinking model"**, which appear **twice each**: once in the window's model
menu and once again in **`gui.trayMenu`** — with a searchable list carrying per-model
status and capabilities, plus a details dialog (context size, parameter count,
quantisation, vocabulary, slots, modalities, chat template).

**The previous revision of this step was wrong about the backend, and the correction
is the whole shape of the work.** It said `discover` is a finished engine with nothing
feeding it — T-17's shape — so 8a's first job was to call it. **It is not.** Read out of
`src/jenova/models.nim` on 2026-09-02:

| What the plan assumed | What `models.nim` actually does |
|---|---|
| `discover` lists the models on disk | **`discover(jcaHome, kind)` returns ONE path** for one of three fixed roles — agent, draft, embed. An env override, else the first `.gguf` in sorted order under `models/<role>`. There is no enumeration in it; `findModel` walks a directory and throws away everything but `found[0]` |
| It is called and merely unused in the GUI | **It has no caller anywhere in the product.** Not `gui.nim`, and not `jenova-core models list`, which echoes three `config` values and never asks `models.nim` anything. It is dead code |
| `switchModel` activates a chosen model | **`switchModel` refuses any target that is not the literal `"instruct"` or `"thinking"`.** It resolves `models/<target>`, validates a temporary symlink, preserves displaced entries as `.old`, and renames into place. The safety is real and must be kept — the *target vocabulary* is what is two items wide |

**So the backend does not exist for this feature; two thirds of it has to be written.**
That is the opposite of Steps 4, 8b and 10a, where the engine was finished and starved.

**The one thing that genuinely does already exist is the information half.** `gui.nim`
already reads `/props` for the context window and the loaded model's name (G-33), for
`default_generation_settings.params` (G-31) and for `modalities` (G-30), and
`routes.nim` already forwards `/props` upstream. **The details dialog is mostly a
second reader of a call the window is already making** — the same reuse that made the
settings panel's "Custom" badge free (D-BK).

#### The work, in order, smallest and most assertable first

**8a-1 — Give `models.nim` an enumerator.** A proc that walks `models/` and returns
every `.gguf` with its role directory, filename, size and whether it is the active
symlink target — the loop `findModel` already contains, without the `found[0]`. Skip
`.old`/backup entries the way `targetModel` does (`isBackup` exists). **This is new
code in `models.nim` and it is where the whole step's assertability lives.**

**8a-2 — Decide what "switch" means for a model that is neither instruct nor thinking.**
`switchModel`'s four-step safety (validate before touching, relative link target,
preserve rather than delete, atomic rename) is the part worth keeping, and its
two-literal gate is the part in the way. **The change is to take a resolved model path
rather than a role name**, with the existing two-target entry point kept as a caller of
it — Directive 3, total feature retention: `jenova-core models switch instruct` must
keep working unchanged.

**8a-3 — Rows, not widgets.** Whatever turns the enumeration plus `/props` into rows —
sorting, active/loaded status, capability badges — belongs in `models.nim`, for the
reason `settings.nim`, `hardware.nim` and `workspace.nim` are where they are. `gui.nim`
gets a list to draw and a details dialog to fill.

**8a-4 — Replace the four literals.** Two in the window's model menu, two in
`gui.trayMenu`. Search the strings; no line numbers are recorded for `gui.nim` (rule 9).

#### What proves it worked

| | What is asserted | Where |
|---|---|---|
| 8a-1 | A fixture tree of role directories yields **every** `.gguf` and **not** the `.old` backups; an empty tree yields an empty list, not an error; the active symlink is identified as active | `models-selftest` (new) |
| 8a-2 | Switching to a path outside `models/` is **refused**; a switch preserves the displaced entry rather than deleting it; **`switch "instruct"` still resolves and behaves exactly as before** | `models-selftest` |
| 8a-3 | Rows carry the loaded model marked as loaded when `/props` names it, and the same list with `/props` absent still renders every model as not-loaded rather than empty | `models-selftest` |
| 8a-4 | Nothing — it is widgets. The list, the search box and the dialog are a **USER run** | — |

**Every assertion is to be shown biting by varying the DATA — a fixture tree with and
without the backup, a `/props` payload naming a different model — never by editing the
source (D-BX, rule 16).** `bin/jenova --check` must exit 0 before handover (rule 17).

**Not in this step:** downloading or deleting models, and per-model *loading* (the Web
UI's load/unload). `llama-server` holds one model and `lifecycle` restarts it; a
load/unload surface implies a model server this program does not have. Raise it if the
USER wants it — do not infer it from the Web UI's button.

---

### 8c. Make the notes editor good *(G-17)* — rescoped **again**, 2026-09-01 18:41 by **D-BW**

**Rescoped twice in one session and it is now the smallest it has ever been.** It began
as "build a real writing surface", became "point the embedded Neovim at the workspace"
(D-BT), and the USER has now ruled: **keep the existing notes editor, do not replace it
with Neovim, and keep Neovim on its own page.**

> *"lets keep the default notes editor and dont replace it with neovim"* … *"instead we
> should make the notes system work well and keep the neovim and neovim config to its own
> page - the editor page - as it currently exists."*

**So 8c is: make `gui.saveNote` and its `TextView` a good notes editor.** Not a second
Neovim, not a document panel. **Q-35 is answered and T-11 is not touched** — with notes
in their own editor and Neovim on its own page there is no second writer against an
authoritative row at all, which is the outcome Q-29 was trying to protect.

**Scope it against the Web UI's notes surface when it is picked up** (rule 11), and note
that the notes *data* work is 10a — a note that reaches the model is worth more than a
note that is pleasant to type.

---

## Step 10 — **NEW, 2026-09-01 18:29.** The workspace becomes a working context

Three USER instructions given together, and they are one feature: **a workspace should
carry its own notes, its own files, and an editor that works on them with the AI.**
Rulings **D-BS**, **D-BT**, **D-BU**, **D-BV**.

**Everything below was verified against the source on 2026-09-01 at 18:29** before it
was written down.

---

### 10a. **BUILT 2026-09-01 19:05.** Workspace artefacts reach the model *(D-BU)*

**`pipeline.nim` contains no reference to notes at all.** Meanwhile the `notes` table
carries `isFocusNote`, `fileAssets` carries `content` and `type`, `conversations`
carries `folderId`/`projectId`/`workspaceId`, and `api.nim` round-trips `isFocusNote`.
**The entire data model exists and nothing reads it.** That is T-17 for the third time:
a finished, tested store with nothing feeding it, and every test green because each
supplies its own data (rule 15).

**The insertion point already exists.** `pipeline.injectSystem` appends `webContext`,
`editorContext` and `ragContext` to the persona. **Workspace context is a fourth of
identical shape** — so it lives below the widget layer and is provable with no window,
the same move that made settings, hardware and the attachment classifier provable.

**Parity is taken from the source, not a summary** (rule 11):
`jca_web/src/lib/services/workspace.service.ts`, `WorkspaceService.getWorkspaceContext`,
injected by `chat.service.ts` under the heading `[CURRENT WORKSPACE ARTIFACTS (Notes &
Files)]`. The behaviour a summary loses, and which **is** the step:

1. Scope is the conversation's **deepest** set id — folder, else project, else workspace,
   else *global*, which selects only artefacts with **no** container.
2. Regular notes at **folder** level are **strictly isolated to that folder**. At project
   level they include child folders; at workspace level, everything nested.
3. **A FOCUS note escapes its level** and applies across the whole workspace tree. This is
   the part every summary drops and it is why the flag exists.
4. **Files follow regular-note scoping and have no FOCUS concept.**
5. The format is **literal**: `--- FOCUS / RULES ---` with `[Folder|Project|Workspace] Title`,
   `--- NOTES ---` with `Title:`/`Content:`, `--- FILES ---` with
   `File: <name> (Type: <type>)` and either `Content:` or exactly
   `(Binary file, content not available for direct reading)`.
6. A FOCUS note with blank content contributes nothing.

**Carried over knowingly:** the upstream has a standing `TODO` that there is **no token
budget**, so a large workspace can overflow the context by itself. Jenova inherits that
by taking parity. **Not fixed here — it is T-3's problem** and fixing either alone buys
nothing.

**What proves it worked:** a `pipeline-selftest` section over a hand-built tree —
workspace, two projects, two folders, regular and FOCUS notes at every level, plus files.
Assert **scope isolation** (a folder chat does not see its sibling's notes), **FOCUS
escape** (a workspace-root FOCUS note reaches a folder chat), **the global fallback**,
the **exact** output strings, and the **join** — that the text lands in the system message
of the body actually sent (rule 15; this is the assertion T-17 proved a project can go
weeks without). Every one shown going red first.

---

### 10b. **BUILT 2026-09-02 07:51.** An uploaded file becomes a workspace artefact *(D-BV)*

Done and out of this plan. `gui.fileAttachmentsAsArtefacts` writes a `fileAssets` row per
attachment through `api.putEntity`, so `fssync.syncFileAsset` mirrors the bytes and the
same cascades apply as on the HTTP surface. The inline base64 in `messages.extra` is
untouched (Q-34, parity). A chat with no workspace, project or folder files nothing —
a global artefact would be visible to every unassigned chat. The record is `PROGRESS.md`
2026-09-02 07:51. The original write-up follows.



**Nothing in the program has ever written a `fileAssets` row** — verified: the table is
created in `db.nim`, cascaded in `api.nim`, trashed and restored in `fssync.nim`, and
**never inserted into**. So an attachment is invisible to the workspace it was dropped
into, and invisible to 10a's context builder.

**The work:** attaching a file to a chat that belongs to a workspace/project/folder also
writes a `fileAssets` row at that level and mirrors the bytes through `fssync`, so it
appears in the tree and trashes and restores with its container.

**Q-34 is ANSWERED — parity with the Web UI (2026-09-01 18:41).** `messages.extra` keeps
the inline base64 exactly as D-BP stores it and the artefact is written **in addition**.
Nothing about the message row changes, so a conversation still moves between this window
and the frozen `jca_web` unconverted. **Step 7d is closed** — it existed only to ask this.
**Nothing in 10b is gated any more.**

**Proof:** an `attach-selftest`/`db-selftest` assertion that an attachment on a scoped
conversation produces a `fileAssets` row at the right level, that it is picked up by
10a's context, and that deleting the container cascades it.

---

### 10c. **BUILT 2026-09-01 19:05.** The editor page's Neovim loads `jvim` *(D-BS)*

**Scope narrowed 2026-09-01 18:41 by D-BW:** there is **one** embedded Neovim now, the
editor page's. The document panel and its second instance are removed by Step 11, so
`vte.configureDoc`/`newDocTerminal` are not wired to anything — they are deleted.

**`vte.nim` spawns `nvim --listen <socket> --cmd <TransparentBackground>` with
`envv = nil`.** So `NVIM_APPNAME` is never set, jvim's configuration is never loaded,
and `JENOVA_ROOT`, `JENOVA_PORT` and `JENOVA_LAN_MODE` — which
`jvim/lua/jenova/endpoints.lua` reads, and which its own `has_jvim_env` tests for — are
never passed. **The editor page runs stock Neovim today.** Passing an environment to
`vte_terminal_spawn_async` is the whole of it.

**Nothing needs building on the server.** `endpoints.lua` wants `/v1/chat/completions`
and `/infill` on port 8080 and `/api/storage/<path>`; `routes.nim` already routes
`/infill` and `server.nim` already handles `/api/storage`. Verified, not assumed.

**What this unlocks is the reason it is worth doing:** `jvim/lua/jenova/` already ships
FIM completion, a chat drawer, LAN discovery, backend telemetry, and an `agent/` tree
with buffer read/write/edit/grep/glob/ls, LSP, shell and `vim_cmd` tools plus memory and
context compaction. **10c is the line of wiring that turns 8c's panel into that.**

**Proof:** the spawn's environment is built by a proc that can be asserted without a
terminal — assert `NVIM_APPNAME=jvim` and the three `JENOVA_*` values are present and
correct. Whether jvim actually loads is a USER run.

---

---

## Step 11 — **BUILT 2026-09-01 19:05.** The document side panel is removed *(D-BW)*

**The USER called it a gimmick and instructed its removal.** Directive 3 permits this
because it was explicitly instructed; that is recorded so it is never cited as licence to
remove anything else.

**Footprint, read out of the source 2026-09-01 18:41 — it is well bounded:**

| Where | What |
|---|---|
| `gui.nim` state | `AppState.panelOpen`, `panelDoc`, `panelDir`, `panelDocs` |
| `gui.nim` procs | `docDir`, `refreshDocs`, `openDoc`, `newDoc`, `closePanel`, `isNoteMirror` |
| `gui.nim` widgets | the panel block and its `sizeRequest` swap, the toggle button, the `DocTerm` renderable |
| `vte.nim` | `configureDoc`, `newDocTerminal`, and the `docSockPath`/`docCwd`/`docFile` triple |
| `nvimctl.nim` | `docSocketPath` |
| `theme.nim` | `.doc-panel` and `.doc-panel-closed` |

**The per-chat `document.md` stops being created.** Existing ones on disk are **not**
deleted — they are the USER's files in their own workspace tree, and removing a Jenova
surface is not licence to delete user data.

**Two simplifications fall out and both are the point:**

1. **`pipeline.configureEditor` is set once in `gui.run` and never re-aimed.** The re-aim
   in `openDoc` and the restore in `closePanel` go with the panel. **Q-30 is moot** — it
   asked which of two instances `Editor:` reads, and there is one.
2. **`isNoteMirror` goes, but its reasoning does not.** It existed to keep `fssync`'s note
   mirrors out of the panel switcher so no file had two writers. `fssync` still mirrors
   notes and the editor page can still open them — that is the USER's own editor, not a
   surface Jenova built. **Do not add the exclusion back somewhere else.**

**What proves it worked:** `nimble core` and `nimble gui` build, every self-test passes,
and **`bin/jenova --check` exits 0** — which is exactly the check rule 17 exists for,
because removing a widget block is precisely the change that compiles and then fails to
build a window. Nothing else here is assertable; it is deletion.

---

## What Session 019 built — 2026-09-01 19:05

**Step 11, 10c, 10a and 8b are done**, in that order, which is the order set at 18:41.
Both binaries build, **twelve self-tests pass**, `bin/jenova --check` exits 0.

| Step | What landed |
|---|---|
| **11** | The document panel is gone — four `AppState` fields, six procs, the widget block, the toggle, the `DocTerm` renderable, `vte.configureDoc`/`newDocTerminal`, `nvimctl.docSocketPath`, two `theme.nim` rules. `pipeline.configureEditor` is now set **once**, in `gui.run`, and never re-aimed — **Q-30 is moot**. No `document.md` on disk was touched |
| **10c** | `nvimctl.editorEnv` builds the editor's environment; `vte.configure` takes it and the spawn passes it. **New self-test `nvim-env-selftest`** |
| **10a** | **New module `src/jenova/workspace.nim`** — the scoping ladder and the format, ported from `WorkspaceService.getWorkspaceContext` by reading it. `pipeline.chatBody` injects it; `gui.postConversation` supplies the scope. **New self-test `workspace-selftest`, 32 assertions** |
| **8b** | `api.restoreItem` re-indexes a restored message; `api.restoreEntity` and `api.deletedRows` added; a **trash panel** in the window over both. Three new assertions in `pipeline-selftest` |

### Three things worth carrying forward

1. **`editorEnv` returns the WHOLE environment, and that is not a detail.** VTE's `envv`
   *replaces* the child environment rather than extending it, so returning only the
   `JENOVA_*` keys spawns an editor with no `PATH` — which fails as "nvim: not found"
   and reads as a missing dependency rather than as the function's bug. Same class as the
   `detectGpu` `LD_LIBRARY_PATH` failure: an unreachable thing and an absent thing
   produce the same silence.
2. **`XDG_CONFIG_HOME` and `NVIM_APPNAME` are both needed, and it was verified rather
   than assumed** — `stdpath('config')` was read back under them. `NVIM_APPNAME` alone
   sends Neovim to `~/.config/jvim`, a symlink the user would have to make by hand, which
   is D-BC's defect.
3. **A self-test assertion that could not fail was written and caught.**
   `check("no key is duplicated", true)` is unconditionally true — the exact defect this
   project has shipped twice. It was replaced with an exact count derived from
   `envPairs()`, and a second assertion (`env.len > 8`) that also could not bite was
   replaced for the same reason.

---

## Ordering — set 2026-09-01 18:41

**Done: Step 11, 10c, 10a, 8b, and — 2026-09-02 — Step 7b (PDF), confirmed on screen.**
What remains, in order:

**G-48 first** — the model switcher, rebuilt to D-CB. It is the only thing in the tree
that is broken rather than absent.

**Then 8c** — make the notes editor good (G-17, D-BW). The last unbuilt item of Step 8
and the smallest that item has ever been.

**Then the two open defects, both widget behaviour and both a USER run:** **G-42**
(markdown tables now render larger than their content) and **G-47** (the editor page's
Neovim truncated at the bottom on a resize, reported 18:41, **not diagnosed**).

**Then Step 9's four stability items**, in the order T-5, T-2, T-4, T-3.

## Step 9 — Stability, none of it urgent

In this order, smallest first:

| | Work | Proof |
|---|---|---|
| **T-5** | Stop the embedding server on exit. **`gui.run`** starts both backends and its `defer` only sends the three workers the quit sentinel, joins them and closes the channels — **`lifecycle.stopAll`** (`lifecycle.nim:329`, verified 18:07) already exists and is reached only from the control worker's stop/restart jobs, never from exit. Leaving the *agent* model loaded is deliberate — reloading gigabytes into VRAM every start is worse — so stop only the embed backend, and clear a pidfile whose process is dead | `jenova-core backends status` after a GUI exit: agent up, embeddings down, no stale pid |
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
