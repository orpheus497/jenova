# BRIEFING

**Last updated:** 2026-09-01 16:19 (Session 017)
**Branch:** `bsd`

---

## 0. READ THIS BEFORE DOING ANYTHING

Every rule below exists because it was broken, repeatedly, and cost the USER a day.

> ### Rule 0 — **DO NOT RUN THE PRODUCT, AND DO NOT LOOK AT THE MACHINE** (**D-BJ**)
>
> Until the migration is complete: do not start `bin/jenova`, `jenova-core serve`, the
> backends, or `nimble suites` **unless the USER asks for that specific thing in that
> message**. **Building is not running** — `nimble core` and `nimble gui` are free and are
> how a change is checked.
>
> **Never enumerate processes or ports to see what the USER has open.** Nobody asked for an
> audit of their machine. Running the product seizes ports and loads gigabytes onto the
> GPU, in the middle of the USER's actual work.
>
> **T-12 is closed.** Two suites fail if something already holds the real ports. That is
> the whole of it, it has been fully diagnosed three times, and it is never diagnosed
> again. Seeing those failures: write nothing, say nothing, carry on.
>
> **The underlying pull, named so it is recognisable:** an unexplained red result creates
> an appetite to prove it, and that appetite is the bug. **Evidence is only worth
> gathering for work the USER asked for.** A stray result from an unrequested run is noise
> a session generated and then investigated.

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run** — and **never deny what plainly was run.** Both halves are the rule. If it was not executed, say "I don't know". If the USER says they ran it, they ran it. |
| **2** | **This is a Nim program using `llama-server`. That is all it is.** No shell scripts, no Lua, no C, no Makefile. Build with `nimble`. |
| **3** | **The archived old build is not work.** A broken reference to an archived file is fixed by **deleting the reference or porting it to Nim** — never by repairing it, and never by asking the USER which (**D-AZ**). Both options sit inside the standing ruling. |
| **3b** | **Everything is driven from the GUI** (**D-BC**). Anything needing a terminal, a shell script or a hand-edited file is a defect. |
| **4** | **Explain in plain English, then cite the ID.** "G-23 needs resolving" communicates nothing. Say what it is, then give the reference (**D-BA**). |
| **5** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Check the stdlib and the codebase first — including whether the API route you are about to write is already implemented and tested, because repeatedly it was. |
| **6** | **Do not rebuild old patterns.** The two-command split was rebuilt after the USER killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **7** | **Comments only where the code is not self-explanatory.** No essays above functions. Do not retroactively "improve" existing comments. |
| **8** | **Do not ask what has been answered.** `DECISIONS_LOG.md` SETTLED FACTS and its QUESTION STATUS index, first. |
| **9** | **Do not write derivable facts into these documents.** Counts and file lists rot. Point at the code. |
| **10** | **Re-check a tracker's claims against the code; do not carry them forward.** Session 013 found seven false claims. Session 015 found thirteen citations that pointed at unrelated code while every finding they described was still true. |
| **11** | **Verify a scope list against the source, not against a summary.** The "GUI parity" list carried since Session 010 named six items. The Web UI's own component listing has roughly three times that. |
| **12** | **A "not yet run" label is not durable.** It survives exactly until any evidence contradicts it — a screenshot, a defect report, or the USER saying so. Carrying it past that point has now cost two sessions. |
| **13** | **A new assertion is not believed until it has been seen to go red.** Two suites in this project have reported PASS while asserting nothing. |
| **14** | **Cite the symbol, then the line.** A bare line number is a claim with an expiry date — thirteen of them rotted inside one session because `gui.nim` grew by 750 lines while they were being written. `fssync.resolveStoragePath (fssync.nim:694)` survives that; `fssync.nim:628` does not. |
| **15** | **A green suite says the parts work, never that anything calls them.** `rag.nim` was fully asserted and completely dead for weeks — every assertion supplied its own corpus, so nothing could tell. When a feature is finished, assert the *join*, not only the parts. |
| **17** | **A compile is not evidence the application starts.** `nimble gui` exiting 0 says the widget tree is valid; the Theme setting shipped a 100% SIGABRT behind a clean compile because `gui.run` asked libadwaita a question before `adw.brew` called `adw_init`. **Run `bin/jenova --check` before handing over any GUI change** — it builds the whole window under a real GTK and exits, showing no window, starting no backend and binding no port, so it is allowed where starting the product is not (D-BJ). **Nothing in `gui.run` may touch GTK, GDK or libadwaita before `brew`.** |
| **16** | **When you corrupt the code to prove an assertion bites and it stays green, the hole is in the assertion set.** That is not a failed experiment, it is the experiment working. It has now found something three sessions running — most recently that nothing checked `custom` JSON reaching the fields the body sets for itself. **Write the missing assertion, then re-run the corruption.** |

---

## 1. What this is

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does the inference; this is everything around it |
| **Binaries** | `bin/jenova` — the desktop app. `bin/jenova-core` — the same program headless, for LAN. Both link the same modules; the split exists so a server host builds without GTK |
| **Build** | `nimble`. Tasks in `jenova_core.nimble`: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| **Architecture** | `BLUEPRINT.md` |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | **Six** shell suites under `tests/`, run by `nimble suites`, plus **nine** self-test subcommands in `jenova-core` — the six older ones plus `hardware-`, `markdown-`, `error-` and `attach-selftest`. **None of them covers the GUI** — see §6 |

## 2. State

**Verified as of 2026-09-01 16:19.** Both binaries build from a clean run of `nimble core`
and `nimble gui`; the FreeBSD-only guard was confirmed to still *fire* when the target is
changed, not merely to exist; **all nine self-tests pass, and `bin/jenova --check`
exits 0 — the application reaches its first frame**, which is a thing a compile does
not tell you and which was learned the hard way at 14:02 (rule 17). Both binaries are
ELF 64-bit FreeBSD executables. The six shell suites were **not** run and did not need
to be — nothing Steps 6 and 7 touched is inside their reach.

**Those runs happened because this session's work was building them; they are not a
standing instruction.** Per Rule 0, do not run the suites or the product again without
being asked. If a run is asked for: invoke it through `nimble suites`, never the scripts
directly — `test_nvimctl.sh` needs `nim` on `PATH` and only `nimble` puts it there, and
**the same trap catches any direct `nim` call**, which fails with "command not found" and
reads as silence rather than an error. If `test_routes` or `test_lifecycle` fail, that is
T-12 and it is closed: nothing to record, nothing to investigate.

**The 2026-09-01 14:02 build has been run by the USER**, and **no defect came back
from it.** They confirmed on screen: **both themes**, the **ghost text** in the
parameter boxes, and **the full field set including the "not yet in effect"
markers**. That supersedes the 2026-08-31 23:28 record below it and settles every
open visual question from Step 5 and Step 5a — the opaque panel and its scrim, the
light palette, the placeholders and the marker. **Do not re-add an "unrun" label to
any of it** (rule 12).

The earlier **2026-08-31 23:28** build was also run by the USER with no appearance
defect reported. Both records stand; the newer one is the current state.

**The backend is in good shape.** Configuration, database, threaded HTTP server, the whole
`/api/*` surface, the filesystem mirror, retrieval **and its feed**, the prompt pipeline,
backend supervision and watchdog, model discovery and switching are implemented and
covered by tests.

## 3. Done this session

### An audit of every claim in these documents against the source (Session 017)

**No code was touched and nothing was run.** Every substantive claim in `BRIEFING.md`,
`TODOS.md` and `PLANS.md` was read back against the source.

**The findings are all true.** Every defect (T-2, T-3, T-4, T-5), every missing feature
(G-17, G-20, G-21, G-30, G-33, G-34, G-35, G-36), every backlog item (G-37, G-38, T-12)
and both shell items (S-1, S-2) were confirmed by reading the code they describe.
Everything claimed built is built: `settings.nim` (534 lines) with its parity assertion
in `jenova_core.nim:632-678`, `--check` in `jenova_gui.nim:54`, the retrieval feed
(`rag.indexExchange` called from `api.nim:798`, `api.nim:836` and `gui.nim:618`,
`rag.backfillChats` from `gui.nim:609`, `rag.forgetMessage` from `api.nim:401`), and
`AutoScroll`, the code-block cap and auto-titling in `gui.nim`. Six shell suites and six
self-tests, as stated.

**One claim was wrong and is corrected.** `DECISIONS_LOG.md` carried Q-31 and Q-32 as
`OPEN` in its second table, one screen below the table declaring both answered — the
exact defect that index was created to stop. Both rows now read ANSWERED.

**And the citation rot recurred inside Session 016.** `TODOS.md` and `PLANS.md` both
claim their line references were re-derived at 12:08; that was true, but parts two to
four then took `gui.nim` from 2,365 lines to **3,072**, and `theme.nim`, `api.nim` and
`fssync.nim` moved with it. **Eleven citations were stale by the time those files were
last written at 14:09**, including every address in the Step 9 defect table. All
re-derived at 14:19. **The lesson is not "sweep harder"** — two sweeps in one day both
rotted within hours. It is rule 14: **read the symbol, treat the number as a hint.**

### Step 5a — the panel made readable, and the settings brought to 1:1

**The USER ran the build and found two defects, both mine.**

**The panel was transparent.** It carried `.glass-panel` at 40% opacity, which is
right for the sidebar over the canvas and wrong for a panel over text. **A blur is
not available** — GTK 4.20 implements no `backdrop-filter` at all, and GSK's blur
applies to a widget's own children rather than what is behind a sibling. **The Web
UI's settings dialog is not glass either**: opaque content over a dimmed overlay,
and `.glass-panel` is on four `jca_web` components, none a dialog. Now opaque with
a scrim, which is both the fix and the parity.

**The tuneables said nothing useful.** Two placeholders could never populate —
`/props` calls Typical P `typical_p`, and `samplers` arrives as an array — and with
the backend down every box was blank. Every numeric field now carries
`llama-server`'s own compiled-in default as ghost text, which is safe to state
because Jenova passes **no sampling flags** on the command line. The help text was
the Web UI's verbatim reference text; it now gives range, direction and the value
that disables each sampler.

**The field set is 1:1** (**D-BL**, superseding D-BK on the USER's instruction,
given twice). Twelve fields added; three excluded and recorded — API Key and MCP on
instruction, `serverUrl` because `bin/jenova` is the host. **Eight of the twelve
needed a feature and got one:** a full light palette applying without a restart, a
transcript that follows a streaming reply, conversation auto-titling, a code-block
cap, a raw-output toggle, raw model names and both sidebar options. **The four
needing attachments are drawn, stored and marked "not yet in effect"** with the
step that turns them on — which is the answer to D-BK's real concern.

**10 new assertions, three corruptions, three different sets of red**, one of them
re-creating the reported `typ_p` bug. **The parity claim is asserted, not stated.**

### Previously — Step 5, the settings screen itself (G-31, G-32)

**There was no settings surface at all**, so temperature, top_p, top_k, min_p and the
penalties were *absent* from the request rather than defaulted badly. There is one now: a
floating panel over the window, six sections — General, Display, Sampling, Penalties,
Import/Export, Developer — with import and export of conversations in the same screen.

**The new module `settings.nim` sits below the widget layer**, holding the fields, the
store under `p.state`, the validator and the merge. `pipeline.chatBody` calls the merge;
`gui.nim` only draws. That is what makes the whole feature provable with no window and no
backend — **D-BH's lesson applied on purpose rather than after a second broken release.**

**Three calls taken inside the scope, recorded as D-BK:**

1. **A field whose feature does not exist here is not drawn.** The Web UI's list includes
   settings for attachments, audio, the model selector, a light theme, auto-titling,
   autoscroll and a code-block height cap — none of which this window has. A control wired
   to nothing is **G-8's defect and G-37's defect**, shipped twice already. Every omission
   is in `settings.OmittedFields` with the step that brings it back.
2. **An unset value is omitted from the request, never sent as a zero.** A typed store
   cannot tell "asked for 0.0" from "never touched", and a defaulted 0 on every parameter
   would silently override the server's own preset **while looking like a working screen**.
3. **The "Custom" badge reuses the `/props` call already being made** for the context
   size, which was the USER's condition for copying it.

**D-BH's deliberate divergence is closed:** Continue is a setting now, off by default,
matching the Web UI.

**15 assertions, four independent corruptions, four different sets of red** — and the
fourth **passed**, which found a hole in the assertion set rather than in the code. See
rule 16. `TESTS.md` §0g.

### One stale citation corrected, in the table the last sweep missed

`TODOS.md` T-15 named the three `Entry` widgets at `gui.nim:830`, `1083` and `1541`; those
lines are unrelated code. The real sites are `gui.nim:1392`, `1790` and `2298`. Session
015 corrected the Active tables and never touched the Watch table.

### Previously — Step 4, the search index has chats in it (T-17)

**The retrieval engine was finished, proven, and completely dead.** `indexContent` had no
caller outside its own self-test, so the index was always empty, `rag.query`
short-circuited on its second line, and `pipeline.prepare` — which had been asking it a
question on every chat turn since it was written — always got nothing back. Every test
passed throughout, because every assertion supplied its own corpus.

**A message is now a document at `chat/<convId>/<role>/<id>`**, which makes the
`pathFilter` the query path already had do the scoping: `chat` is every conversation,
`chat/<convId>` is one. No change to `query`.

**Three calls taken inside the scope, recorded as D-BI:**

1. **The unit is a completed exchange, not a message.** The pipeline queries this index
   with the user's own words *on the way to the model*, so a question indexed when it is
   saved is in the index before its own request is answered and comes back as its own
   top-ranked context. The reply and the turn it answers are indexed together when the
   reply lands. Both surfaces run that one rule — the window from its control worker,
   never the GTK thread; the HTTP path on an assistant row.
2. **The backfill waits for the embedding server.** Indexing while it loads stores chunks
   with no vector, and all of history would have been permanently keyword-only — which
   looks like working retrieval until someone asks in different words. It is incremental
   and self-healing: a message is skipped only when it is indexed **and** carries a vector.
3. **Deletion forgets**, after the commit, so a rolled-back delete cannot strip the index.

**14 assertions, all shown going red first** — 10 in `rag-selftest`, and **4 in
`pipeline-selftest` for the wiring**, which is the half a unit check cannot see. Four
independent corruptions gave four different sets of red, and the wiring corruption left
the feed assertion green. `TESTS.md` §0f.

### Thirteen stale citations corrected

Every finding in `TODOS.md` and `PLANS.md` still held; thirteen of their addresses did
not, because `gui.nim` grew by 750 lines during the session that wrote them. Corrected,
and the convention changed to **name the symbol, then the line** (rule 14).

### The USER ruled on running the product (D-BJ) — this is Rule 0

After the work was done, an unrequested `nimble suites` run came back red and I enumerated
the USER's processes and ports, reported their own open application back to them as an
anomaly, and started probing endpoints — chasing a discrepancy nobody had asked about, on
a machine they were working on. **Parts of four sessions have now gone into a subject with
one sentence in it.** The ruling is Rule 0 above, and the phrasing that invited it —
"run `nimble suites` with `bin/jenova` closed", which was in three files — is gone.

## 4. What is actually missing — the honest list

**The desktop application has the shape of the Web UI and not all of its function.**

| Works | Missing entirely |
|---|---|
| Send a message, stream a reply | **PDF text extraction** — gated on a zlib dependency decision, yours (G-30) |
| Copy, edit, delete, regenerate, continue a message | **Audio capture** — to be raised before it is built (G-30) |
| Branching — alternative versions, with a counter | **LaTeX maths** — the half of G-34 left |
| Statistics: tokens, tok/s, context used and left, model | **A real model selector** (G-20), **trash view** (G-21) |
| A reasoning view for thinking models | **A real note editor** (G-17) |
| **Stop a generation, keeping the partial answer** (G-33) | — |
| **Markdown tables, task lists, strikethrough** (G-34) | — |
| **Typed errors, Retry, context-overflow reporting** (G-35) | — |
| **Delete confirmations naming the cascade** (G-36) | — |
| **Attachments: picker, drag-and-drop, paste, thumbnails, preview** (G-30) | — |
| Recall of past chats — the index is fed | — |
| **Settings — 1:1 with the Web UI, minus API Key, MCP and `serverUrl`** (G-31) | — |
| **Import / export of conversations** (G-32) | — |
| **Hardware profile detection, scoring and selection** (S-1) | — |
| **Light / dark / system theme, a following transcript, auto-titled chats** | — |
| Conversations: create, rename, delete, search | — |
| Workspace / project / folder tree, notes — renaming keeps its files | — |
| Markdown text and highlighted code blocks | — |
| Theme, canvas, glass panel, wordmark | — |
| Neovim page + AI reads the live buffer | — |
| Tray, LAN toggle, backend start/stop | — |

**Almost all of it is GUI work over a backend that is already finished and tested** — the
message-update route, the recursive fork cascade, `/api/db/import`, the trash routes and
`models.switchModel` all exist with assertions behind them.

Full detail with mechanisms and references: `TODOS.md`. Ordered plan: `PLANS.md`.

## 5. Known broken in the Nim code

**T-17 was built in Session 015 and G-31/G-32 this session.** What remains:

- **S-1 is built** (15:13) — hardware detection, scoring and profile selection are Nim,
  with a screen and a subcommand. Gone from this list.
- A leaked embedding server on exit (T-5), an unbounded statement cache (T-2), two holes
  in the file-containment check (T-4), untrimmed chat history (T-3) — real but not urgent,
  and all Step 9.
- Two cosmetic defects in the `TODOS.md` Backlog: two dead style rules in `theme.nim`
  (G-37) and a code comment in `gui.nim` describing a `Paned` that was never used (G-38).
- **One filed this session:** restoring a message from the trash does not put it back in
  the retrieval index, because deletion forgets and nothing undoes it. It is written into
  `PLANS.md` Step 8b, where the trash view is built, rather than left to be rediscovered.

## 6. The gap: the GUI has no test coverage

All six suites and all six self-tests exercise `jenova-core`. **Nothing tests `gui.nim` at
all.** Every GUI defect in this project's history was found by the USER looking at the
screen.

**The response is working and should be continued.** Branching's tree walk went into
`api.nim`, the request body into `pipeline.chatBody`, and this session the chat indexer
into `rag.nim` — all below the widget layer, all asserted, none of them requiring a
window. **Where a GUI feature's behaviour can be moved below the widget layer, move it
there and assert it.** What is left in `gui.nim` is then layout, which is what a screen is
actually for.

## 7. Waiting on the USER

**Nothing in the plan is blocked.** Three product decisions remain parked, none on the
critical path: filesystem as the source of truth (T-11), deployment (T-7), a CLI (T-8).

## 8. Unobserved from earlier phases — awaiting a USER screen run

**A screen run — the USER's, when it suits them, and not something a session initiates or
asks after** (Rule 0). **The settings work is done and confirmed** (item 3). What remains
below is unobserved rather than suspected, and stays that way until the USER happens to
look:

1. **The repairs from Session 014** — existing conversations reading as transcripts again
   with no version arrows on ordinary turns, and Continue extending an answer rather than
   restarting it. **Continue is now off by default** (D-BH closed at Step 5), so it has to
   be switched on under Settings → General to be seen at all.
2. **Session 015's recall, against a live backend.** Everything was verified with the
   embedding server **down**, so the semantic half of ranking on real embeddings is
   unproven. The feed, the filter, the forget, the backfill and the injection into the
   outbound body are all asserted. On a start with the embedder up, the window says
   "indexed N past messages for recall" once, and a later question about an earlier chat
   should reach the model with that chat attached.
3. **The settings panel is run and confirmed** — both themes, the ghost text and the
   whole field set. Nothing about it is outstanding.

   Three of its behaviours need a *live generation* or a *long answer* to appear at
   all, so they were not necessarily exercised by that run — stated as scope, not as
   suspicion: the transcript **following a streaming reply** (`AutoScroll`), the
   **code-block cap** on an answer over 24 lines, and the **"Custom" badge and server
   placeholders**, which need a backend up to have any `/props` values to compare
   against. With the backend down every box shows the built-in default instead, which
   is what the USER saw and is the designed behaviour.
4. **Four icons still unconfirmed**: `view-refresh-symbolic`,
   `media-playback-start-symbolic`, `go-previous-symbolic` and `go-next-symbolic` — the
   regenerate, continue and version-arrow controls, which only appear on a branched or
   continuable turn. All are standard Adwaita symbolics, but a missing one renders as a
   broken placeholder rather than failing the build. **`emblem-system-symbolic` is
   confirmed** — the USER opened the settings panel with it — and
   `format-text-rich-symbolic` only appears once the raw-output toggle is switched on.

## THE PHASE JUST FINISHED — Step 7, the chat surface. **Complete at 16:19.**

| | |
|---|---|
| **A stop button** (G-33) | Cancelling needs a **file descriptor**, not just a flag: the worker lives blocked in `recvLine`, and `shutdown(2)` is what ends that read. The partial answer is kept. **D-BO** |
| **Tables, task lists, strikethrough** (G-34) | A real `Grid` — Pango has no table — scrolling inside itself, with `:---:` alignment. **LaTeX still open** |
| **Typed errors and Retry** (G-35) | `streamOnce` now **reads the error body it used to throw away**, which is where the prompt and context sizes live. An overflow names both and is **not** offered a Retry |
| **Delete confirmations** (G-36) | One dialog over all three call sites, **naming the cascade**, counted by rewriting the same `Cascades` statements the delete runs |
| **Attachments** (G-30) | **All three of the Web UI's routes**: picker, drag-and-drop, and paste of a clipboard image. Chips carry **thumbnails**; clicking one opens a **full-size preview**; a sent turn shows what it carried. Stored in the frozen Web UI's shape and sent in its part order (**D-BP**) |

**Nine self-tests, all passing.** `attach-selftest` is 27 assertions, `markdown-`
17, `error-` 15, plus 5 on `cascadeCount`. **Eight clean reds across the day's
corruptions.**

**Reuse paid off twice, which is rule 5 working:** thumbnails needed **no** new
GTK proto because `loadPixbuf` already wraps
`gdk_pixbuf_new_from_file_at_scale`, and the paste path writes a PNG and hands it
to **the same queue a dropped file uses** — one attachment implementation, three
ways in.

**Two honest notes kept from the day:** one markdown corruption stayed green and
was a *weak* corruption rather than a hole, and was replaced with one that bites;
one attachment corruption **crashed** instead of going red and is not counted as
a red.

## What is left of Step 7 — two decisions, not two jobs

- **PDF text extraction needs a dependency decision, and it is yours.** It
  requires FlateDecode — zlib inflate — which Nim's stdlib does not have, so it
  means linking `libz` (`/usr/lib/libz.so.1`, zlib licence, permitted by
  AGENTS.md). **Directive 1 gates a dependency change.** Nothing else about the
  parser is hard, and `contentFor` already *sends* a PDF that carries text or
  page images.
- **Audio capture is the raise `PLANS.md` has always called for.** `input_audio`
  parts are already emitted; nothing records. It needs `/dev/dsp` ioctl work or a
  capture library — **and no model in use has an audio modality**, so it may buy
  nothing at all.

## Next — `PLANS.md` Step 8, the remaining views

**8a. A real model selector** (G-20) — two hardcoded menu items today, in the
window and in the tray. Backend exists: `models.discover`, `models.switchModel`.
**8b. A trash view** (G-21) — everything deleted is invisible; the routes exist
and are asserted. G-36 landed first and the two answer each other, so this is now
the more pressing half. **8c. A real note editor** (G-17). Then Step 9's four
stability items.

**Unseen, and it is now a large surface:** the stop button, table rendering,
attachment chips and thumbnails, the drop target, the paste button, the preview
panel, the confirmation dialog and the Retry button. `--check` builds the widget
tree and presses nothing.

**Still outstanding from earlier phases:** the Session 014 repairs, Session 015's
recall against a *live* backend, three settings behaviours needing a live
generation, and four Adwaita icons that only appear on a branched turn.

## 9. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Language** | Nim only, plus `llama-server`. No shell, no Lua, no C, no Makefile |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Retrieval** | Indexes chats (D-BD), fed per completed exchange (D-BI) |
| **Settings** | The window has one, **1:1 with the Web UI's minus API Key, MCP and `serverUrl`** (D-BL). Every other field is drawn; one whose feature is not built yet is marked *"not yet in effect"* with the step that turns it on, never left silently dead. An unset value is **omitted** from the request, never sent as a zero (D-BK) |
| **Unused files** | Archive to `.devdocs/ARCHIVE/`, never delete, never leave in the root |
| **MCP** | Deferred by the USER. Largest thing in the Web UI — do not pick it up casually |
| **Virtual file explorer** | Cancelled by the USER (D-AW). The Neovim page is the browser |
| **`jca_web`** | Frozen (D-Z). Read it to establish parity; never edit it |
