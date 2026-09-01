# BRIEFING

**Last updated:** 2026-09-01 14:02 (Session 016)
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
| **Tests** | **Six** shell suites under `tests/`, run by `nimble suites`, plus **six** self-test subcommands in `jenova-core` (`db-`, `serve-`, `rag-`, `pipeline-`, `sha256-`, `tree-selftest`). **None of them covers the GUI** — see §5 |

## 2. State

**Verified as of 2026-09-01 14:02.** Both binaries build from a clean run of `nimble core`
and `nimble gui`; the FreeBSD-only guard was confirmed to still *fire* when the target is
changed, not merely to exist; **`pipeline-selftest` passes, and `bin/jenova --check`
exits 0 — the application reaches its first frame**, which is a thing a compile does
not tell you and which was learned the hard way at 14:02 (rule 17). Both binaries are ELF 64-bit
FreeBSD executables. The suites were **not** run this session and did not need to be —
nothing outside `pipeline-selftest`'s reach changed.

**Those runs happened because this session's work was building them; they are not a
standing instruction.** Per Rule 0, do not run the suites or the product again without
being asked. If a run is asked for: invoke it through `nimble suites`, never the scripts
directly — `test_nvimctl.sh` needs `nim` on `PATH` and only `nimble` puts it there, and
**the same trap catches any direct `nim` call**, which fails with "command not found" and
reads as silence rather than an error. If `test_routes` or `test_lifecycle` fail, that is
T-12 and it is closed: nothing to record, nothing to investigate.

**The 2026-08-31 23:28 build was run by the USER**, and no appearance or rendering defect
came back from it. The outstanding work is **functional, not visual**. Do not re-add an
"unrun" label to those features.

**The backend is in good shape.** Configuration, database, threaded HTTP server, the whole
`/api/*` surface, the filesystem mirror, retrieval **and its feed**, the prompt pipeline,
backend supervision and watchdog, model discovery and switching are implemented and
covered by tests.

## 3. Done this session

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
| Send a message, stream a reply | **Attachments** of any kind — image, text, PDF, audio (G-30) |
| Copy, edit, delete, regenerate, continue a message | **A stop button** — the other half of G-33 |
| Branching — alternative versions, with a counter | **Tables, task lists, LaTeX maths** (G-34) |
| Statistics: tokens, tok/s, context used and left, model | **A real model selector and model information** (G-20) |
| A reasoning view for thinking models | **Typed errors, retry, context-overflow reporting** (G-35) |
| Recall of past chats — the index is fed | **Trash view** (G-21), **delete confirmations** (G-36), **a real note editor** (G-17) |
| **Settings — 1:1 with the Web UI, minus API Key, MCP and `serverUrl`** (G-31) | **Hardware profile detection and selection** — currently impossible from anywhere (S-1) |
| **Import / export of conversations** (G-32) | — |
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

- **There is no way to detect hardware or change profile at all** (S-1). It was two shell
  scripts and both are broken by subtraction. It becomes Nim with a GUI screen (D-BC),
  Step 6.
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

## 8. Next

**A screen run — the USER's, when it suits them, and not something a session initiates or
asks after** (Rule 0). Three things have never been seen working. None is a suspicion;
they are simply unobserved, and they stay unobserved until the USER happens to look:

1. **The repairs from Session 014** — existing conversations reading as transcripts again
   with no version arrows on ordinary turns, and Continue extending an answer rather than
   restarting it.
2. **Session 015's recall, against a live backend.** Everything was verified with the
   embedding server **down**, so the semantic half of ranking on real embeddings is
   unproven. The feed, the filter, the forget, the backfill and the injection into the
   outbound body are all asserted. On a start with the embedder up, the window says
   "indexed N past messages for recall" once, and a later question about an earlier chat
   should reach the model with that chat attached.
3. **The settings panel, and it is the largest unseen change in the project.** Its
   layout, the opaque panel and its scrim, the "Custom" badge — and above all **the
   light palette**, which touches every widget, the canvas, the terminal and the
   code-block scheme. The gear is in the top bar, right of the document-panel button;
   Theme is the first field under General. Also unseen: the transcript following a
   streaming reply, and the code-block cap — that one is the change nearest G-11's
   collapse defect, and it is capped by an explicit height *because* owlkettle's
   ScrolledWindow reports a near-zero minimum without one, but that is reasoning and
   not a screenshot.
4. **The icons**, still unconfirmed: `view-refresh-symbolic`,
   `media-playback-start-symbolic`, `go-previous-symbolic`, `go-next-symbolic` and this
   session's `emblem-system-symbolic` and `window-close-symbolic` are all standard Adwaita
   symbolics, but a missing one renders as a broken placeholder rather than failing the
   build.

Then **`PLANS.md` Step 6 — hardware profiles in Nim, driven from the window** (S-1, ruled
at D-BC). Choosing a hardware profile is still two shell scripts and **both are broken by
subtraction**: `detect-hardware.sh:19` sources an archived `lib/detect-env.sh` and one
profile's `jenova-setup` resolves an archived `bin/` helper. Nothing invokes either, so
**there is currently no way to detect hardware or change profile at all** except editing
`etc/jenova.conf` by hand — which D-BC makes a defect, not a limitation. The work is
detection, scoring and apply ported to Nim, a screen that lists the profiles and shows
which matched and why, the same as a `jenova-core` subcommand for headless hosts, the
kernel tuning moved into `profile.conf` as data, and both scripts archived. **The scoring
is pure logic over data files and belongs in a suite** — feed known hardware, assert the
selected profile, including that an opt-in profile never wins automatically and that the
fallback ladder holds. Fix S-2's two Linux filesystem strings in the same pass.

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
