# TODOS

**Last updated:** 2026-09-03 07:24 (Session 023 — the three-part audit)

Only what is actually outstanding. Everything finished lives in `PROGRESS.md`.

> **Session 023 added the A-series below.** A three-part audit — Web UI parity, a claim-by-claim
> validation of all ten trackers against the source, and a mechanism analysis of the implemented
> features. **No code was changed and nothing was run.** **Every A-row carries `[V]` or `[A]`** —
> read that marker before scheduling work on it (**D-CG**).
>
> **A-1 and A-2 were built on 2026-09-03 09:02** and are gone from this file per the completion
> rule; the record is `PROGRESS.md`. **Test and check work is left until last from here on** —
> the USER's instruction, filed as **A-68** in Backlog.
>
> **`A-67` is a traceability index** mapping each of the 64 sweep findings to its A-row. It exists
> because the first pass of this section **dropped five of them** and mis-stated `A-52`'s severity;
> both are corrected and the index has been verified to resolve for all 64. **Check coverage
> against A-67 rather than trusting this section.**

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

**T-12 is fixed** (2026-09-03 09:02, `PROGRESS.md`). The two suites no longer collide with the
machine's real ports. Nothing here to re-derive.

---

## RULE: Nim only, and everything is driven from the GUI

**Jenova is Nim plus `llama-server`. Nothing else.** No shell scripts, no Lua, no C,
no Makefiles. All of that was replaced (D-AM, D-AZ).

> **Corrected 2026-09-03.** This line said the replaced material "is in `.devdocs/ARCHIVE/`".
> **That directory does not exist.** The USER deleted it deliberately in commit `349a9b5b`
> (2026-09-01) and has confirmed the deletion was theirs. The material is recoverable from git
> history at `349a9b5b~1` and nowhere else on disk. **Nine trackers carried a pointer to that
> path**; they are corrected in this pass. See **D-CE**.

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

**G-21, G-43, G-44, G-45 and G-46 are gone from this file because they are done**
(`PROGRESS.md`, 2026-09-01 19:05 and 2026-09-02 07:51). Per the completion rule
their record lives in `PROGRESS.md`, not here. Workspace notes and files reach the
model, an upload is filed as a `fileAssets` artefact, the editor page loads `jvim`,
the document panel is removed, and the window has a trash view whose restore also
puts a message back in the retrieval index.

**G-17 is built and gone from this file** (`PROGRESS.md`, 2026-09-02 11:53). D-BW's
rescoping — keep the notes editor, do not replace it with Neovim, keep Neovim on the
editor page — is what was built. **T-11 was never touched by any of it**, which is the
point: with notes in their own editor and Neovim on its own page there is no second writer
against an authoritative row at all, which is the outcome Q-29 was protecting.

### G-47 — the editor page's Neovim is truncated at the bottom on a resize

**Reported by the USER 2026-09-01 18:41:** when the main display changes, the embedded
Neovim is *"slightly truncated at the bottom, so the neovim inside the vt needs to
scroll."*

**Still not diagnosed, and it was looked at properly on 2026-09-02 rather than left
alone** (rule 1). `vte.nim` and the editor page were both read in full. The page mounts
`NvimTerminal {.expand: true.}` in a vertical `Box`; `vte.buildTerminal` sets colours, a
10,000-line scrollback and a font scale, and **nothing whatever about geometry**.

**Two candidates, and both are candidates rather than findings:**

1. **Cell rounding.** A VTE sizes itself in whole character cells, so an allocation that
   is not an exact multiple of the cell height leaves a partial row at the bottom.
2. **`.nvim-term` carries `padding: 8px`** (`theme.nim`). GTK4 CSS padding shrinks a
   widget's content box, and **whether VTE's row computation accounts for it is not
   knowable from this tree.**

**Why it stops there.** VTE's size allocation lives in `libvte`, not in this repository —
the header gives prototypes, not behaviour. Settling it needs three numbers from the
running widget: the allocation height, VTE's `char_height`, and the row count Neovim
believes it has. **So no change is being made on a guess** (D-AN), and the padding is
deliberately left alone: altering it to see what happens is exactly the move the ruling
forbids. **It is a USER run either way** — the same standing gap as G-41.

---

## Active — the GUI is missing most of the Web UI's features

> **THE ACTIVE ITEM IS A-59, the parity backlog** — chosen by the USER 2026-09-03 09:10, scoped
> 09:48 as **`PLANS.md` Step 13**. **13a and 13b were built 2026-09-03 10:21** and their record is
> `PROGRESS.md`: the composer is a `TextView`, and the three `data-services` gaps — markdown
> export/import, the conversation fork, and the mirror's `pull` half — are closed and asserted.
> **What is left of A-59 is 13c**, the 866 single-agent verdicts across the other eight areas, each
> verified against the source on pickup per **D-CG**.

**This is the real outstanding work and it is much larger than this file previously
said.** Sessions 010-012 triaged "GUI parity" into six items (a file browser, an
editor, file awareness, Neovim, a model selector, a trash view). **That list was wrong
by omission.** It was written from a summary, not from the Web UI's own component
tree, and it missed almost everything a user actually touches in a chat.

Enumerated 2026-09-01 by reading `jca_web/src/lib/components/app/*/index.ts` — the
barrel files that list every shipped component. That is the authoritative inventory;
check any future scope claim against it, not against a summary.

**Ordering and the work for each item is `PLANS.md`.** Steps 1-7 are built, Step 7b is
closed (PDF, confirmed on screen), and **Step 8 is complete — 8b, 8a and 8c are all
built**, 8a and 8c-1/8c-2 confirmed on screen. G-33, G-34 (minus LaTeX), G-35, G-36 and
G-30 are done; the record is `PROGRESS.md`.

> **Corrected 2026-09-03.** This said "what is left in this file is two widget defects and
> **Step 9**". **Step 9 was built on 2026-09-02 12:19** — T-5, T-2, T-4 and T-3 — and the
> "Active — defects in the Nim code" section below says so itself, so the file contradicted
> itself two screens apart. What is actually left is **G-47** (undiagnosed), the two cosmetic
> Backlog rows, LaTeX as G-34's open half, model information, and **the A-series added this
> session**, which is larger than everything above it put together.

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
- **G-33 — both halves. CLOSED 2026-09-03 12:12 and gone from this file** per the completion rule.
  This line said "G-33 remains, reduced to the stop button". **The stop button is built and wired**
  — `gui.cancelStream`, whose two-variables-not-one design is documented above it *because a flag
  alone cannot interrupt a worker blocked inside a socket read*, with its caller at
  `if app.streaming: cancelStream()` in the chat form. Found by the EXAMINER PEER while examining
  `chat-form`, verified here by reading both. **A row survived for days describing as outstanding a
  feature that was finished** — which is rule 10 in the direction nobody checks, since a stale
  *open* item costs a session that picks it up rather than a session that trusts it.

**G-30 is gone from this file because it is done** (`PROGRESS.md`, 2026-09-02 08:43),
and **the USER confirmed it on screen at 09:36 — uploading a PDF works, "basic".**
Per the completion rule its record lives in `PROGRESS.md`. **Audio capture is not
built and is not gated (D-BZ)** — ruled by the USER; the `input_audio` *send* path
stays under Directive 3 because it carries imported Web UI conversations.

**G-20 and G-48 are gone from this file because they are done** — reshaped to D-CB at
2026-09-02 10:43 and **confirmed on screen by the USER at 10:53: switching and folder
resolution work as intended.** Per the completion rule the record is `PROGRESS.md`. The
list draws from `models/instruct` and `models/thinking` only, a displaced link is removed
rather than kept as `.old`, and the window has one switch surface (the tray keeps its
pair — a reading of D-CB, overrulable).

**Two things stated plainly rather than dressed up.** **Which of the three changes fixed
the reported failure was never diagnosed**, because the symptom was never known; it is not
claimed now that it is gone. And **loading a switched model into the backend has not been
exercised** — the USER had not started it — so that is *unobserved*, not suspect, and it
sits in `BRIEFING.md` §8 rather than here. **Do not file it as a defect and do not re-add
an unverified label to the two halves that were confirmed** (rule 12).

**What is left of G-34: LaTeX maths.** Tables, task lists and strikethrough are
built; KaTeX has no GTK equivalent and rendering maths is its own project.

**G-17 is gone from this file because it is built** (`PROGRESS.md`, 2026-09-02 11:53).
Per the completion rule its record lives there. **Step 8 has no unbuilt item left.** A note
reads as rendered markdown and edits as text, Cancel restores, unsaved work cannot be
dropped without being asked, delete is on the note and refused on a FOCUS rule, and a note
can be marked FOCUS from the window at all. **The one thing left of the original scope is
LaTeX maths, which belongs to G-34 and not here** — KaTeX has no GTK equivalent.

**Unseen, and it is what a screen run would show:** the rendered view, the Edit/Cancel
switch, the unsaved-changes dialog on all three of its doors, and the delete button
refusing a pinned note.

**G-49 and G-50 are gone from this file because they are built** (`PROGRESS.md`,
2026-09-02 11:21). Per the completion rule their record lives there. A note keeps its FOCUS
flag through a save or a rename — **fixed as a class, not an instance:** `api.putEntity`
merges a partial node onto the stored row, so any column the window omits is carried
forward, which also closes T-13's shape for good (**D-CC**). And the note header now
carries a pin toggle, so a FOCUS note can be made from the window at all, which it never
could before. **Unseen, and it is what a screen run would show:** the toggle itself.

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
| **G-51** | **The constraint is bounded and it is exactly one widget — surveyed 2026-09-02 11:43.** `Button.shortcut` is the **only** property in owlkettle whose update hook can abort the process from a child-count change. The other assert-only hooks are `Paned`'s `resize`/`shrink`/child-type, and **no `Paned` is built anywhere in `gui.nim`** — it is also G-37's and G-38's subject. *(Corrected 2026-09-03 11:35: this said "zero hits". A search now returns **three**, and all three are comments explaining why the widget is a `Box` and not a `Paned` — the substance holds, the wording invited a reader to conclude a search would prove it.)* Every other assertion in owlkettle is an internal invariant, not a positional-diff trap. **So the rule is: `gui.fullscreenButton` must be the last child of its row and nothing may be inserted before it — no more than that.** Adding a child in a container that also holds a keyboard-shortcut button crashes the application on the next redraw. Found 2026-09-02 11:30 by causing it: putting a fourth button in the note editor's header row aborted the process on opening a note, with `widgets.nim(920) state.shortcut == widget.valShortcut [AssertionDefect]`. **The mechanism, verified in owlkettle's source and not inferred:** owlkettle diffs a `Box`'s children **by index** and reuses a child's state whenever the type matches (`widgetdef.nim`, the type-id compare in the generated `update`), and **`Button.shortcut` has no update path at all** — its `build` hook installs a `GtkShortcutController` and its `update` hook only asserts the value never changed, with owlkettle's own `# TODO` on the assertion. So a shortcut-carrying `Button` that lands on the index of a `Button` built without one aborts. **`gui.fullscreenButton` (`shortcut = "F11"`) is the only such widget in this program**, and it is the last child of all three branches of the chat/note/editor header row, whose counts are 3, 3 and 5. **This is a live trap, not an open defect** — the code is correct as it stands and a comment at the note pane records it. The durable fix, if the constraint ever becomes inconvenient, is to move F11 off the button and onto the window as a real shortcut controller; that is not scheduled. **`bin/jenova --check` cannot catch this class:** it builds each branch once and the assertion only fires on an *update*, which needs a branch to change. |
| **G-37** | *(**Re-verified 2026-09-03 11:35. Both findings still hold and the addresses rotted a fourth time** — Step 13a added `.draft-view` and `.draft-placeholder` to `theme.nim`, so `paned > separator` is now **`theme.nim:447`** with `:hover` at **451**, not 417/421. `.glow-text` is still **`theme.nim:253`** and a search for it across `gui.nim` still returns **zero**. Search the selectors.)* *(Re-verified 2026-09-02 08:01. **Both findings hold. The claim written beside them did not.** The previous revision said "`theme.nim` has not been touched since" — Step 11 deleted `.doc-panel` and `.doc-panel-closed` from it that same evening, so the separator rule moved: it is **`theme.nim:417`** with `:hover` at **421**, not 428/432. `.glow-text` is still **`theme.nim:253`** and a grep for it across `gui.nim` still returns **zero**. **Search the selectors; the numbers here are a hint and have now rotted three times.**)* **Two style rules in `theme.nim` are dead.** `paned > separator` styles a widget that is not in the tree — a leftover from G-25, which shipped as a `Box` after a `Paned` crashed the app. And `.glow-text` is defined and carried by no widget: the glow effect works, but as a `text-shadow` duplicated inside `.brand` and `.conv-active`. **The second half is G-8's exact defect — a class defined and applied to nothing — recurring in the same file.** Both were found and reported on 2026-09-01 and neither was filed as work; that is why they are here. Re-verified 2026-09-01 14:19: `.glow-text` is `theme.nim:253` and **no widget in `gui.nim` carries the class** (a grep for it in `gui.nim` returns zero hits); `paned > separator` is `theme.nim:428-432`. *Re-verified 2026-09-01 17:27: the `.glow-text` address held, the separator address did not — it was written as 416-420 against a file where it is 428. Earlier revisions named 162 and 251-255, and before that named them in the opposite order.* |
| **G-38** | **A code comment in `gui.nim` describes a widget that was never used.** The main-area comment still explains itself as feeding "the `Paned` that G-25 adds". G-25 shipped as a `Box`, and the comment above the `Box` itself records why. A reader following the first comment looks for a `Paned` that does not exist. Prose only, no behaviour. **The doc comment directly above `gui.mainArea`** — *verified 2026-09-01 18:07; the address written here (2637) was wrong, as was 2560 before it, which is why no third number is being recorded.* |
| **A-75** | `[V]` **A comment in `gui.nim` says the attachment strip shows no thumbnails, and the code directly beneath it renders one.** The comment at the pending-attachment strip explains that it shows name, type and size *"because a GTK thumbnail means decoding the image on the GTK thread"* — **and eleven lines down sits `app.attachmentPixbuf(a, 40)`, cached by digest, under its own `G-30:` comment saying a real thumbnail is what the Web UI does.** G-30 reversed the decision and the first comment stayed. **This is G-38's exact class — a comment describing a decision the code no longer implements — at a new site.** Prose only, no behaviour. |
| **A-74** | `[V]` **Neither attachment strip can overflow.** Both the pending strip and the sent-turn chip row in `gui.messageBody` are a plain `Box(orient = OrientX)` with **no scroller, no wrap and no cap** — attach enough files and the chips run off the window edge with no way to scroll or see the rest. **One cause, two sites**, because the Web UI draws both surfaces from one `ChatAttachmentsList` and the GUI hand-rolled two strips. **Record the caution with the row: do NOT reach for `ContentScroll` reflexively.** Its `halign = START` and natural-width propagation are deliberate for G-42's tables and are **exactly what collapsed the composer to a sliver in 13a** — that cost two failed repairs from the USER's screen. |
| **A-72** | `[V]` **One conversation cannot be exported as JSON — sharing a single chat means handing over the entire database.** `api.exportAll*` (`api.nim:871`) is a `SELECT … WHERE is_deleted=0` across all seven tables with **no filter parameter of any kind**, and `gui.exportConversations` (`:3489`) goes straight to a `FileChooserDialog` with no selection step. **"Export this chat…" exists but is markdown** (13b, `convmd.nim`) and does not round-trip through the JSON importer, so there is no way to hand someone one conversation in the format this program can read back. Needs a selection list plus either an id filter on `exportAll` or a sibling that takes ids. **Count it once:** this one boundary is also what `DialogConversationSelection`, `misc/ConversationSelection.svelte` and `ChatSettingsImportExportTab`'s whole confirm flow exist for — **three components, two parity areas, one cause**, which is 13c's counting rule working. Found by the EXAMINER PEER, verified here. |
| **A-73** | `[V]` **The composer's send/newline rule is undiscoverable.** 13a built Enter-to-send and Shift+Enter-for-newline into `DraftView`, and **nothing anywhere on screen says so.** The Web UI prints it — `ChatFormHelperText`, *"Press Enter to send, Shift + Enter for new line"* — so a user who wants a multi-line draft in the window has no way to learn that it is possible. **One `Label` under the composer; `gui.nim` only.** Found by the EXAMINER PEER in `chat-form`. **Record its caveat with it:** that pass examined the area's components and actions and **did not enumerate the thirty verdict rows**, so "almost nothing left in chat-form" is a statement about causes and **must not be read as a row count.** |
| **A-71** | `[V]` **Nothing can put the settings back.** `settings.initSettings` is the defaults constructor (`settings.nim:382`) and `settings.load` already falls back to it — **and no action anywhere calls it.** Verified: every caller in the tree is either `pipeline.chatBody`'s default parameter or a self-test. **So the USER cannot undo a settings experiment** except by remembering every field they touched, or by deleting `settings.json` by hand — which is terminal, and which **D-BC**/L5 makes a defect rather than a limitation. **The gap is a caller, not a mechanism:** one assignment behind the confirmation dialog G-36 already establishes. `gui.nim` only; `settings.nim` needs nothing. **The smallest item on the board.** Found by the EXAMINER PEER, verified here. |
| **A-68** | **The test scripts and checks are left until last.** Given by the USER 2026-09-03 09:05. They come up every session while the main work is unfinished, and they are likely to keep failing until it is done. Raw and unscoped — no `PLANS.md` entry, and none is to be written without the USER asking for one. |

---

## Backlog — the 2026-09-03 audit (A-series)

**Where these came from.** The USER commissioned a three-part audit on 2026-09-02: a Web UI ↔ GUI
feature cross-reference, a validation of every `.devdocs/` claim against the source, and a
mechanism analysis of the implemented features. It ran as multi-agent sweeps over the whole of
`src/`. **No code was changed and nothing was run** (Rule 0 held throughout).

**Read the verification column before acting on any row.** `[V]` means *this session read the
cited code and confirmed the finding first-hand*. `[A]` means an agent reported it and a second
agent failed to refute it, but **no human-equivalent read has confirmed it** — treat an `[A]` row
as a lead, not a fact, and verify before scheduling work. This distinction exists because one
agent citation had already rotted when it was written (`nvimctl.alive` was cited at `:350` in a
196-line file), which is rule 14's failure mode inside the audit that was hunting for it.

> ### `[A]` SWEEP — **COMPLETE, 2026-09-03 12:45. 34 rows: 24 confirmed, 1 refuted, 1 merged away, 1 needing a runtime probe.**
>
> **D-CG's blockage on the A-series is cleared except A-51.** Seven rows remain `[A]` and are a
> cluster with one session — **A-6, A-28, A-32, A-33, A-39, A-42, A-43** — reconciled mechanically
> against this file's own markers, nothing doubled, nothing dropped.
>
> **What the sweep was worth, which is the case for ever running one:**
>
> - **A-64 REFUTED** — "no backend tuning value is reachable from the window" is false; **Step 6's
>   profile Apply writes a whole `jenova.conf`.** The row is **replaced, not deleted**, with the
>   narrower true claim: no *individual* value can be set. *Refutations are recorded as prominently
>   as confirmations.*
> - **A-61 PROMOTED to a data-integrity defect of A-3's class — because its stated mechanism was
>   wrong.** It described partiality *within* a stream, which cannot happen; the real partiality is
>   **across** streams, and a PDF whose streams partly fail is attached as though whole.
> - **A-49 deleted** into Step 12g; **A-9/A-10/A-45 collapsed** into Step 12h; **A-44/A-47 rescoped**
>   as Step 12i under a title that does not misdirect; **A-56 reclassified as a constraint**, not a
>   unit; **A-19 escalated, built and closed the same hour.**
> - **Five row texts corrected against the source**, three severities restated, and **two counts
>   corrected — one of which was itself wrong** (A-57).
>
> **Two groupings were dissolved and both dissolutions are recorded in `PLANS.md`**, because a wrong
> grouping misdirects a builder more expensively than no grouping at all.
>
> **The sweep's own lesson, and it is the second of its kind today.** The session that wrote A-19's
> reachability bound **did not re-check it against work that landed after it wrote it** — the bound
> was invalidated by A-16, which went green that morning. **That is the same class of error as
> trusting a dated tracker entry, committed inside the pass whose entire purpose was to catch dated
> tracker entries.**
>
> **D-CG bars an `[A]` row from being scoped until verified**, and that was roughly a third of the
> audit. **Batch 1 (7) and batch 2 (9) are done: A-9, A-10, A-12, A-14, A-15, A-19, A-22, A-23,
> A-30, A-35, A-36, A-37, A-45, A-50 upgraded `[A]`→`[V]`.** 7 rows are with one session, **11 left
> with the other** — A-13, A-41, A-44, A-46, A-47, A-55, A-56, A-57, A-61, A-63, A-64.
>
> **Cross-checked mechanically rather than trusted, 12:38** — `grep -c` over this file's own
> markers: **32 `[V]`, 18 `[A]`, 52 rows.** The 18 remaining are **A-6, A-13, A-28, A-32, A-33,
> A-39, A-41, A-42, A-43, A-44, A-46, A-47, A-55, A-56, A-57, A-61, A-63, A-64** — which matches
> both assignment lists exactly, with no row assigned twice and none dropped. **That is A-67's
> traceability principle applied to the sweep: check the coverage against the file, do not trust the
> count in the message.**
>
> **`A-51` is explicitly NOT swept and must not be counted as swept** — it needs a runtime probe and
> is entry one on `PLANS.md`'s runtime-probes list. **A-55, A-56 and A-57 may join it.**
>
> **What the sweep changed, which is why it is worth its cost:** **A-49 was deleted** — confirmed,
> then recognised as the same finding as Step 12g from the other direction, and *leaving both would
> have given one file two owners*. **A-50 folded into 12g-1.** **A-19 was escalated** and its
> recorded bound falsified by a fix that shipped this morning. **A-9, A-10 and A-45 collapsed into
> one unit** (Step 12h). **Three rows had their severity restated** because a builder reading them
> would have fixed the wrong thing. **Five row texts were corrected against the source.**
>
> **Record refutations as prominently as confirmations.** The A-series was written in one pass and
> the tree has moved a long way since — **nothing has been refuted yet, and that is a fact about
> 16 rows, not a prediction about the remaining 18.**
>
> **One practice worth naming, because it is why these verdicts are usable.** A verifier reached
> **A-35**, which sits in `http.nim` — a file it had itself edited that morning. **It verified
> against the *original* mechanism and declared the conflict rather than passing silently.** That is
> the difference between a sweep and a rubber stamp.
>
> ### Re-derived against the source 2026-09-03 11:35 — **every finding checked still holds; every `gui.nim` address in them was wrong.**
>
> **Every claim below was read out of `src/` this session and not one finding was refuted.**
> *(This opened "Twenty-two claims" and then listed twenty-three. The numeral is dropped rather
> than corrected to 23 — it is the self-test count's exact failure mode, one screen away from the
> paragraph that diagnoses it.)*
> Confirmed first-hand: **A-3** (`trimHistory` measures `($m).len`, budget `perSlot * 4 div 2`),
> **A-4** (25 MiB before base64, 32 MiB on `Content-Length`), **A-5**, **A-7** (`cacheStore`'s only
> caller is `pipeline-selftest`), **A-16** (`restoreItem` contains no `fssync` call), **A-17**,
> **A-18** (one caller each, all in `api.handleFs`), **A-20** (no `begin`/`commit`), **A-21**,
> **A-24**, **A-25**, **A-26**, **A-27**, **A-31** (`OmittedFields` names three), **A-34**,
> **A-40**, **A-48** (zero `href` in `src/`), **A-52**'s `make llama` pair, **A-53**
> (`prepare` still takes no `Settings`), **A-62**, **A-69**, **G-37** and **G-38**.
>
> **What did not hold is the addressing, and it is a policy breach rather than drift.** The sweep
> note at the top of this file records the seventh sweep's ruling: **bare line numbers into
> `gui.nim` and `api.nim` are deleted rather than re-derived, because they have rotted every single
> time.** The A-series was written with them anyway, and **every `gui.nim` address checked this
> session was wrong.** So they are replaced with symbols below, not renumbered.
>
> > **The ledger that stood here is deleted, 2026-09-03 11:52, and deleting it is the point.** It
> > listed fourteen corrected addresses — `A-5 :2679→:2908`, `A-26 :3066→:3323`, `A-27 :2486→:2715`
> > and so on — inside the very paragraph arguing that line numbers into `gui.nim` must be deleted
> > rather than re-derived. **It then rotted inside fifteen minutes**, because the A-5 and A-26
> > edits landed in `gui.nim` at 11:45 and moved every one of them again: `:2908`→`:2933`,
> > `:3323`→`:3348`, `:2715`→`:2732`. A session offered to supply the new numbers. **Recording
> > them would have been the ninth sweep**, and the seventh already ruled that re-deriving is not
> > the fix. **Cite the symbol. There is no correct line number to write here, only one that has
> > not rotted yet.**
>
> **The count that did hold:** the dispatch in `src/jenova_core.nim` carries **sixteen**
> `of "…-selftest"` cases and `jenova_core.nimble`'s `SelfTests` const lists the same sixteen, so
> nothing added since is unrun. Read them there, never from a number written here.

### A-1 and A-2 — **BUILT 2026-09-03 09:02 and gone from this file.**

Per the completion rule their record lives in `PROGRESS.md`. `nimble suites` runs every
self-tests, and every `SKIP … exit 0` guard is `FAIL … exit 1`. **T-12 was fixed in the same pass.**

> ### A-3, A-4, A-5 and A-26 are **BUILT and gone from this file** — 2026-09-03 11:51.
>
> Per the completion rule their record is `PROGRESS.md`: **Step 12c** (A-3, A-4, with A-5 alongside)
> and **Step 12e-1** (A-26). **Green was established by a session other than the one that wrote
> each** — `nimble core` 0, `nimble gui` 0, `bin/jenova --check` 0, and `markdown-`, `pipeline-`,
> `attach-`, `error-` and `fs-selftest` all PASS. **12c's author never compiled its own work**; it
> was instructed not to build and said so plainly, which is why it was verified before it was
> recorded rather than after.
>
> **A-17, A-16, A-20 and A-24 are built too** and gone from this file with them (`PROGRESS.md`,
> 11:55 and 11:58). **A-17's mechanism was not what this file said:** `getTrash` enumerated
> `<workspaces>` as a list of workspaces and met `.trash` itself among them — the row described the
> symptom. **A-20 is recorded as built and UNASSERTED, deliberately:** atomicity cannot be asserted
> without injecting a fault, and injecting one means damaging product code (**D-BX**), so no
> non-discriminating assertion was written to make the row look covered.
>
> **A-18 upgraded `[A]` → `[V]` 2026-09-03 11:58** — re-verified first-hand: `fssync.getTrash`,
> `restoreTrash` and `emptyTrash` still have exactly one caller each and all three are in
> `api.handleFs`. The window offers none of them. **It is now the only open half of 12f.**
>
> **A-48 is built too** — 12:02, `PROGRESS.md`, Step 12e-2, with a scheme allowlist and 24 new
> assertions. *(It sat in `b830bfca` as committed-but-unasserted for twenty minutes, which is
> exactly the distinction a commit erases and the reason its builder asked to be left open in this
> file rather than closed by the commit that swept it up.)*
>
> **Open: **A-18** (12f-2's window surface) and **12d**, which is planned in full (`PLANS.md`) and
> **deliberately not started**.
>
> **Full green at the commit point `b830bfca`, run by the `.devdocs` session** rather than taken on
> report: `nimble core` 0, `nimble gui` 0, `bin/jenova --check` 0, and **fourteen self-tests each
> exit 0** — db, sha256, markdown, error, tree, attach, workspace, nvim-env, models, fs, hardware,
> composer, convmd, pipeline. **`serve-` and `rag-selftest` were not run**, and the omission is
> recorded rather than hidden by "all green": they may bind ports, which is Rule 0's territory.
>
> **`src/jenova_core.nim` is a token held by the `.devdocs/` session** (`BRIEFING.md` §0a).
> All the assertion work lands in that one file — `pipeline-`, `error-` and `attach-selftest` for
> 12c, `markdown-selftest` for A-26, `fs-selftest` for A-17 — and nothing else locks it.

### A-6 — high severity. **A-3, A-4 and A-5 were here and are built** (`PROGRESS.md`, Step 12c)

| ID | V | What it is |
|---|---|---|
| **A-6** | `[V]` | **The G-40 memos removed the per-frame parse but not the per-frame copy.** `markdown.blocksFor`'s hit path is `return memo.blocks[id]` (`src/jenova/markdown.nim:232`) and `pipeline.entryFor`'s builds a tuple from `memo.atts[id]` (`src/jenova/pipeline.nim:859`); both read out of a table that retains ownership, so under ARC the value is `=copy`'d — deep-copying every string, and for an image attachment the whole base64 payload. Both are called from `view` (`gui.messageBody`, `gui.mainArea`). **If this holds, `view` still does work proportional to the transcript on every frame — the complexity L7 forbids — and only the constant fell.** The instrument aimed at it is blind: `parses` counts parses, not copies, so `attach-selftest`'s `mm.parses == 1` stays green regardless. **`[A]` and it matters:** this rests on Nim ARC copy semantics for a table-owned lvalue, was not confirmed by a second read, and would be settled by reading the generated C or by a counter on the copy path. |

### A-7 … A-51 — medium severity, grouped by subsystem

**Retrieval, pipeline and workspace context**

| ID | V | What it is |
|---|---|---|
| **A-8** | `[V]` | **`Prepared.trimmed` is computed and thrown away, so history loss is invisible everywhere.** `pipeline.prepare` sets `result.trimmed = trimHistory(...)` (`src/jenova/pipeline.nim:361`); the field is declared at `:50` and **has no reader anywhere in `src/`**. There is no log line, no response header (the `extraHeaders` mechanism already exists and is used for `X-Cache`), and nothing in the window. Combined with A-3, where a trim can remove everything at once, a legitimate mitigation becomes an unexplained behaviour change. |
| **A-9** | `[V]` | **Retrieval silently degrades to keyword-only and tells nobody.** `rag.embed` returns an empty sequence when the embedding server does not answer (`src/jenova/rag.nim:147`), `haveSemantic` goes false and the hybrid score collapses to BM25 alone. That degradation is real, deliberate and declared in the module header. What is **not** declared is that nothing at runtime distinguishes the two modes: `rag.formatContext` emits the identical `--- REPOSITORY CONTEXT ---` header either way, `rag.available` reports only FTS5 and its sole caller is `rag-selftest`, and the window has no retrieval status at all. **Asymmetric failure:** `backfillChats` is gated on `lc.healthy(beEmbed)` (`src/jenova/gui.nim:819`) but the live `indexExchange` at `:830` is not, so a turn written while the embedder is down is stored keyword-only until a later start re-picks it up. |
| **A-10** | `[V]` | **Changing the embedding model silently disables semantic retrieval for ever.** `rag.dot` returns `0.0` on a dimension mismatch (`src/jenova/rag.nim:127`), every chunk then falls below `SemanticFloor` (0.3) and is skipped. `MODEL_EMBED` is resolved by config or directory discovery, so swapping the GGUF is a supported one-file operation. **No dimension is recorded in `rag_chunks`, nothing re-embeds, nothing warns.** |
| **A-11** | `[V]` | **`pathFilter` is applied after the keyword search has already been truncated globally.** `rag.query` runs the FTS5 query with `LIMIT 200` over the whole index (`src/jenova/rag.nim:464`) and first calls `passesFilter` forty lines later (`:503`). When the index holds more than 200 better global matches from outside the scope, **a project-scoped query returns no keyword hits at all** while matching chunks exist inside the scope — and returns them with no sign a limit was reached. The semantic half is unaffected, so the failure is partial and harder to spot. |
| **A-12** | `[V]` | **Every semantic query unpacks and scores every stored vector, with an O(n²) per-path fold and no limit.** `rag.query` issues `SELECT path, start_line, vec FROM rag_chunks WHERE vec IS NOT NULL` with no `LIMIT` and no predicate (`src/jenova/rag.nim:476`), then dot-products each in Nim with a linear scan of `best` inside the loop (`:484-490`). This runs on the completion worker for every retrieving turn, and since D-BD the store grows with the user's message count and is never pruned. The module header indicts `search.lua` for exactly this read shape without noting the replacement shares it. |
| **A-13** | `[V]` | **The workspace artifact block is unbounded and lands where `trimHistory` will never touch it.** `workspace.nim:39-44` declares "there is no token budget" and says it is not fixed because it is the same problem as T-3. **T-3 has since been built and the two halves do not meet:** `pipeline.chatBody` folds the block into `messages[0]` when that is a system message (`src/jenova/pipeline.nim:427-434`) and `trimHistory` skips system messages unconditionally (`:283-285`). A workspace whose notes exceed the context fails on every turn, and `classifyError`'s advice — "start a new chat, or raise the context size" — cannot help. Both halves are declared; their interaction is not. |
| **A-14** | `[V]` | **Web search reports a broken scrape as the positive statement that the engine found nothing.** `websearch.ddgHtmlSearch` returns an empty sequence for a non-zero `fetch` exit, a short body, a markup change or a bot interstitial served with HTTP 200 (`src/jenova/websearch.nim:81-96`), and `formatContext` turns empty into "Web search returned no results. The search engine did not return matching results for this query." (`:145-152`). The module carefully distinguishes "no HTTPS client on this host" and calls that distinction load-bearing; **the third state — the request or the parse failed — is folded into the one that asserts success.** The model is then told to state that no results were found. **SEVERITY RESTATED 2026-09-03 12:35 — this is a TRUTHFULNESS defect, not a UX one, and the row read as the latter.** The empty sequence is returned both when search is blocked **and when the scrape selectors miss — the ordinary way a scraper dies when DuckDuckGo renames a class** — and `formatContext` has no third state, so both become *"The search engine did not return matching results for this query"*, **which the model relays to the USER as fact.** The proc's own docstring calls the distinction load-bearing and then does not carry it. **A builder reading the old row would improve a message; what is needed is the third state.** |
| **A-15** | `[V]` | **Web search pairs titles to snippets by array index.** `ddgHtmlSearch` extracts the two lists in independent passes and zips them positionally, additionally dropping any snippet under 10 characters (`src/jenova/websearch.nim:87-96`). DuckDuckGo does not guarantee a `result__snippet` per `result__a`. **One missing snippet misattributes every result after it**, and the block goes to the model as fact. **THE TRIGGER IS THE ASYMMETRIC THRESHOLD AND THIS ROW BURIED IT (restated 2026-09-03 12:35):** titles are kept on `clean.len > 0` and snippets on `clean.len > 10`, then paired by index — **so one short snippet shifts every subsequent pair by one**, and titles print against other results' snippets. `min(titles.len, snippets.len)` truncates the tail and **cannot realign anything.** **Someone reading this row as "titles and snippets can misalign" would fix the truncation and ship the bug.** The two thresholds must agree, or the pairing must not be positional. |

**Data layer, filesystem and the trash**

| ID | V | What it is |
|---|---|---|
| **A-21** | `[V]` | **`db.queryBlob` treats a SQLite error as end-of-rows, and it is the vector-search path.** `db.query` distinguishes `SQLITE_ROW` / `SQLITE_DONE` / else-raise (`src/jenova/db.nim:303-311`); `db.queryBlob` collapses that to `if rc != SQLITE_ROW: break` (`:255-256`). `SQLITE_BUSY` after the timeout, `SQLITE_CORRUPT` and `SQLITE_IOERR` are all indistinguishable from a clean finish. **Its one caller is `rag.query`'s full vector scan**, so a mid-scan error silently returns a partial vector set and retrieval ranks against a fraction of the index with no error anywhere. |
| **A-22** | `[V]` | **There is no schema versioning and no migration mechanism.** `db.Schema` is nine `CREATE TABLE IF NOT EXISTS` statements (`src/jenova/db.nim:321-360`), every one a no-op on an existing database including for a table whose definition changed. There is no `PRAGMA user_version`, no `schema_migrations`, no `ALTER TABLE` anywhere. **Adding a column to any entity — the change `api.Entities` is designed to make cheap — takes effect on a fresh install and never on an existing one**, and would then 500 on every read of that entity with no repair path short of hand-editing the database. `db.migrateMessageParents` is a careful one-off with no framework behind it. **TWO CORRECTIONS 2026-09-03 12:35, both verified here — the finding holds and the row overstated its case twice.** `db.Schema` is **eight** `CREATE TABLE IF NOT EXISTS` statements, **not nine** (counted). And *"no record that it has run"* is the wrong complaint: **`migrateMessageParents` is called unconditionally from the open path (`db.nim:408`), so it is idempotent by design** — a better position than this row implied, and the thing actually missing is a versioning mechanism for migrations that *cannot* be idempotent. |
| **A-23** | `[V]` | **Export/Import through the window round-trips rows and leaves the workspace mirror unwritten.** `api.importData` calls `upsert(..., mirror = false)` (`src/jenova/api.nim:603`) — correct and commented for the HTTP route, where the workspace tree travels alongside the dump, and wrong for the desktop Export/Import pair, which moves a single JSON file. Re-importing on a clean tree gives back every note and asset row with no `.md`, no asset file and no git history. Notes self-heal on the next save; **file assets have no editor and therefore no re-save path, so their files never appear.** **CORRECTED 2026-09-03 12:35: "no re-save path" overstates it.** A **rename** is one — `commitRename` upserts with `mirror = true`, and `putEntity`'s merge (**D-CC**) carries `content` forward, so the file is written. **So a re-imported asset is recoverable — by an action no USER would ever think to perform to recover a file.** The substance holds; the absolute did not. |

**The window, rendering and settings**

| ID | V | What it is |
|---|---|---|
| **A-25** | `[V]` | **The documented off-switch for the only continuous GPU/CPU load in the application does not work.** The comment above the canvas timer in `gui.run` says the particle canvas is "Disabled by `CANVAS=0`", and the gate is `st.cfg.get("CANVAS", "1") != "0"`. **`CANVAS` is not in `config.Keys`** (`src/jenova/config.nim:33-54`), and `Config.get` reads only `Config.values`, which `evalConfFiles` fills strictly from `Keys`. The lookup always misses, the default always wins, **and no conf file, no environment variable and no setting can turn the animation off** — there is no canvas entry in `settings.Defs` either. The canvas is the `Overlay`'s main child and therefore window-sized, and a 33 ms timer invalidates all of it for the life of the window. Under L5 this is a defect on its own terms. |
| **A-27** | `[V]` | **Copy is Wayland-only and swallows its own failure.** `gui.copyToClipboard` spawns `wl-copy` inside `except CatchableError: discard`. On X11, or on a host without wl-clipboard, every Copy affordance — the per-message button and the copy button on each fenced code block — does nothing with no notice, no log line and no visual change. **The toolkit route was already available and was bypassed:** the same file binds `gdk_display_get_clipboard` for the image-paste path. `p.waitForExit()` also runs on the GTK thread, so a wedged `wl-copy` blocks the window. Note `BLUEPRINT.md` lists `wl-copy` as a base-system tool; wl-clipboard is a port, so this is also an undeclared install-time requirement. |
| **A-28** | `[V]` | **`gui.mdBlock` runs `countLines` over every code block on every frame, inside `view`.** The cap decision is `b.text.countLines > CodeCapLines` (`src/jenova/gui.nim:2576`), and `strutils.countLines` walks the whole string. The memo prevents re-*parsing*; the parsed `Block` still carries the full code text and this scan runs afresh per block per frame while a reply streams. The value is a pure function of `b.text` and could be computed once in `markdown.parse` and stored on the `Block` — **which is exactly what `aligns` already does for the table case**, for the stated reason that the widget layer should apply it without re-parsing. |
| **A-29** | `[V]` | **Four settings fields are drawn, stored, and wired to nothing, and the reason shown to the user is stale.** `pasteLongTextToFileLen`, `copyTextAttachmentsAsPlainText` and `pdfAsImage` carry `awaiting: "attachments — PLANS.md Step 7b (G-30)"` (`src/jenova/settings.nim:108`, `:115`, `:128`) and `autoMicOnEmpty` carries `"audio capture — PLANS.md Step 7b (G-30)"` (`:161`). **Step 7b is closed and confirmed on screen**, and **D-BZ rules audio capture will never be built.** So the panel tells the user three settings are waiting on a milestone that has already landed and one on a feature that has been cancelled. `pdfAsImage` in particular cannot ever work as written: `pipeline.contentFor` sends page images only when a stored attachment already carries `processedAsImages`, which only an imported Web UI conversation has. **D-BL's rule — say which step turns it on rather than presenting a control that silently does nothing — is broken by its own bookkeeping.** |
| **A-30** | `[V]` | **The settings self-test's word "only" is not what it asserts.** `check("only the attachment and audio fields are marked pending", …)` (`src/jenova_core.nim:2062`) checks that two named fields have an `awaiting` and two named fields do not. **It never walks `Defs`**, so a fifth pending field would not be caught. **AND A SECOND PROBLEM THIS ROW DOES NOT NAME (added 2026-09-03 12:35, verified):** **four fields carry `awaiting`** — `settings.nim:108`, `:115`, `:128`, `:161` — **and the assertion names two.** So it does not even cover the pending set that exists *today*, let alone a future fifth. **Sits under A-68 with all other test work.** |
| **A-31** | `[V]` | **`OmittedFields` records three exclusions and there are seven.** The Web UI draws 47 settings keys (`jca_web/.../ChatSettings.svelte:41`, the authority `settings.nim:22` names) against 41 in `settings.Defs`. `apiKey`, `mcpServers` and `serverUrl` are recorded; **`agenticMaxTurns`, `agenticMaxToolPreviewLines`, `alwaysShowAgenticTurns` and `showToolCallInProgress` are absent and unrecorded.** All four are MCP/agentic and legitimately excluded — the parity claim itself holds — but the bookkeeping does not name them. |
| **A-32** | `[V]` | **The window's SSE reader does not de-chunk.** `gui.streamOnce` skips headers and then reads with `recvLine`, keeping lines that begin with `data:` (`src/jenova/gui.nim:295-310`). llama-server streams with `Transfer-Encoding: chunked`; this works only because hex size lines do not start with `data:`. **When one SSE event exceeds a chunk, the size line is injected mid-line, `parseJson` throws and the `except … continue` at `:303-305` discards the token with no counter and no sign.** The same gap degrades G-35: a chunked error body has size lines spliced into it, so `classifyError` cannot parse it and the context-overflow numbers that are the point of the feature are lost. The identical shortcut two procs below is honestly declared in `httpGetLocal`'s docstring; the streaming path carries no such note. |
| **A-33** | `[V]` | **Sidebar filters allocate a lowercased copy of every name on every frame, and `convsIn` re-runs the whole conversation filter once per tree node.** `gui.visibleConvs` (`src/jenova/gui.nim:1663`) either copies `app.convs` wholesale or allocates `c.name.toLowerAscii` per conversation; `convsIn` calls it once per invocation and `view` invokes it at four nesting levels. Not large today, and recorded only because the module is otherwise scrupulous about this exact rule. |

**HTTP, server and lifecycle**

| ID | V | What it is |
|---|---|---|
| **A-34** | `[V]` | **`http.parseRequest` understands only `Content-Length`; a chunked request body is read as empty.** `transfer-encoding` is never consulted anywhere in `src/jenova/http.nim` — the only reference is `content-length` at `:71`. A client sending `Transfer-Encoding: chunked`, which is legal and is what many HTTP libraries do for a streamed body, gets `clen = 0` and an unframed body. **`upstream.buildRequest` does strip the header outbound as correct hop-by-hop handling**, so the header was thought about on one side and not the other. Only keep-alive is declared as a known incompleteness (N-16). |
| **A-35** | `[V]` | **A truncated request body is accepted silently and handed on as complete.** The body loop breaks on `n <= 0` and returns, with no comparison of `result.body.len` against `clen` (`src/jenova/http.nim:76-80`). For `/api/db/*` the short JSON usually 400s; **for `/api/storage` POST it does not — `handleStorage` checks only `req.body.len == 0` and then writes the truncated bytes over the existing file**, answering `{"status":"ok"}`. This is the thing D-BQ and D-BK both forbid: a short read that looks complete. |
| **A-36** | `[V]` | **`server.peekPath` gives a client ~35 ms, while its docstring promises the socket timeout.** The loop is eight attempts with `sleep(5)` between them (`src/jenova/server.nim:124-132`); only the first `recv` blocks. If a request line is split across segments with a gap longer than that, `peekPath` returns empty and the acceptor closes the connection with no status line, no error and no log. Unreachable on loopback; reachable over LAN to a phone on a poor link, which `routes.nim:13-19` names as the intended second device. |
| **A-37** | `[V]` | **HEAD is honoured only on the static route.** `serveStatic` threads `headOnly` into every response and its comment names serving a body to a HEAD as "a protocol violation" (`src/jenova/server.nim:145-148`). `handle`'s other five branches never inspect `req.meth` for HEAD, so `HEAD /api/db/conversations` runs the query and returns every row. |
| **A-38** | `[V]` | **The socket hand-off mechanism is vestigial.** `server.handle` opens `result = false` (`src/jenova/server.nim:170`) and **no `result = true` exists anywhere in the proc**; both `upstream.forward` calls are `discard`ed (`:208`, `:211`). So `handedOff` is unconditionally false and the docstring describing an ownership contract has no implementation. Current behaviour is correct; a future change to `forward` would have no effect because of the `discard`. |
| **A-39** | `[V]` | **Quitting while a reply streams can hang the process for up to 300 seconds.** The Quit path sets `quitting`, calls `closeWindow` and returns (`src/jenova/gui.nim:1115-1125`); **it never calls `cancelStream`**. `run`'s `defer` then joins the stream worker, which is blocked in `sock.recvLine(timeout = 300_000)` (`:304`). `cancelStream` has exactly one caller, the Stop button. |
| **A-40** | `[V]` | **Closing the window from the title bar leaves every timer armed against a tree GTK is tearing down.** `quitting = true` is written in exactly one place — the in-app Quit action — and the 3 s poll and 33 ms canvas timers, both in `gui.run`, guard on it. *(Re-verified 2026-09-03 11:35: one write, two guards, unchanged.)* A window-manager close sets nothing, so the 40 ms drain would still call `st.redraw()` and the canvas timer would still queue a draw on `canvas.area`, a module global never nulled. **This is the after-close diff the project's own investigation identified as the cause of ten SIGBUS cores.** |
| **A-41** | `[V]` | **`cancelStream` races the worker's own close.** It reads `streamFd.load()` and then calls `shutdown` on it (`src/jenova/gui.nim:243-248`) with no synchronisation against the `finally` that closes the same socket (`:352-355`). If the worker closes in between and the descriptor is immediately reused — the embedded server accepts constantly — **Stop shuts down an unrelated live connection.** |
| **A-42** | `[V]` | **Restoring from the Trash panel performs embedding HTTP round trips on the GTK thread.** `gui.restoreFromTrash` runs on the GTK thread (`src/jenova/gui.nim:3419`) and `api.restoreItem` re-indexes; for a restored *conversation* it loops every assistant turn calling `rag.indexExchange`, each an HTTP POST with a 30-second client timeout (`src/jenova/rag.nim:151`). **Restoring a long conversation with the embedder slow or down freezes the window for turns × up to 30 s.** |
| **A-43** | `[V]` | **`workspace.contextFor` reads every note's and every file asset's full content on the GTK thread, on every send.** Called from `gui.postConversation` (`src/jenova/gui.nim:1741-1745`), with `allNotes` and `allFiles` both selecting `content` (`src/jenova/workspace.nim:79-91`). Because `fileAttachmentsAsArtefacts` files each chat attachment as a `fileAssets` row, **this set grows with use and nothing bounds it**, so Send gets progressively more expensive. |
| **A-44** | `[V]` | **Every note save and every filed attachment forks a synchronous `git` subprocess on the GTK thread** before `send` even builds the body — `api.putEntity` → `upsert` → `mirrorUpsert` → `fssync.gitAdd` (`src/jenova/fssync.nim:144`). `send` does this once per staged attachment. |
| **A-45** | `[V]` | **`rag.configureEmbed` writes threadvars and the HTTP server's completion workers never call it.** `pipeline.prepare` runs `rag.query` → `rag.embed` on those threads, which falls back to a hard-coded `127.0.0.1:8082` (`src/jenova/rag.nim:149-150`). **On a deployment that moved `LLAMA_EMBED_PORT`, every retrieval served through :8080 silently degrades to keyword-only.** The identical hazard is recognised and worked around for `ctlWorker` (`src/jenova/gui.nim:733-736`) and not for the server pool. |
| **A-46** | `[V]` | **`lifecycle.start` does non-async-signal-safe work between `fork()` and `execv()`** — `getEnv`, two `putEnv` calls and `allocCStringArray` all allocate (`src/jenova/lifecycle.nim:236-265`). On the Restart path the caller is multi-threaded. If another thread holds the allocator lock at fork time the child can deadlock before exec, leaving a pidfile pointing at a wedged process. The first start in `gui.run` happens before the threads exist and is safe; **the Restart button is not.** |
| **A-47** | `[V]` | **Five of six `hardware.nim` probes are still unbounded.** The module diagnoses this class itself at `:162-172` — "`execCmdEx` has no timeout, and that cost a hang" — and `runBounded` (`:177`) is applied to exactly one call site, the GPU probe (`:228`). Bare `execCmdEx` remains at `:141` (sysctl), `:248` (`swapinfo -k`), `:259` (`zpool list`), `:267` (`swapinfo`) and `:274` (`nvmecontrol devlist`). **`zpool list` on a suspended pool and `nvmecontrol devlist` against a wedged controller are the realistic hangs**, and `detect` calls them all in sequence on the worker the shutdown path joins. `detectStorage` is also the one probe with no `try` at all. |

**Markdown and content rendering**

| ID | V | What it is |
|---|---|---|
| **A-51** | **NOT SWEPT — needs a runtime probe. Do not count it as verified.** *(The mechanism half is confirmed from our source: `LangAliases` lists only labels that differ from a GtkSourceView id, and `resolveLanguage` passes everything else through, so an unlisted non-id label silently resolves to nothing and the block renders unhighlighted. **But the claim needs the installed library's id list and it cannot be read** — `/usr/local/share/gtksourceview-5/language-specs/` holds **no `.lang` files at all**, only `language.dtd` and two `.rng` schemas, confirmed here; the specs are compiled into a GResource. Enumerating them means calling `gtk_source_language_manager_get_language_ids()`, which is **running code, not reading it.** The suggested missing labels — `rb`, `jsx`, `tsx`, `csharp`, `dockerfile` — are recorded as **suspicion attached to a probe, not as a finding**, and the marker was deliberately not upgraded. **First entry on the runtime-probes list, `PLANS.md`.**)* | **The syntax-highlighting alias table misses several common fence labels.** Coverage is otherwise a strength — `sourceview.resolveLanguage` passes an unmapped label straight through as a GtkSourceView id, so roughly 180 languages work. The 14-entry `LangAliases` (`src/jenova/sourceview.nim:216-223`) misses `dockerfile` (id is `docker`), `golang` (`go`), `tsx`, `jsonc`, `json5`, and **`svelte` and `vue` — the exact pair the Web UI goes out of its way to alias onto XML.** Each renders as an uncoloured block. Honestly declared in two places in the code, which is why it is low-impact. |

### A-52 — dead code, stale comments and declared shortcuts, recorded together

**One entry, several findings, none lost.** These are grouped because each is small and none
changes behaviour on its own — **not because they are all low severity.** *Corrected in the same
pass that wrote them: the first draft of this heading said "fifteen findings … all cosmetic, dead
or declared", and that was wrong on both counts. Several of the items below were rated **medium**
by the sweep that found them — the dead-proc census, the unbounded caches, the `make llama`
strings, the `lanAddress` shell pipelines — and the count was not fifteen. Writing a tidy number
and a tidy severity over an untidy list is rule 9's failure mode, committed inside the audit that
exists to catch it.*

All are `[A]` except the dead-symbol census and the `make llama` strings, which this session
confirmed by search.

- **Dead exported procs with no caller anywhere in `src/`** `[V]` — `fssync.scopeDir` (whose own
  doc comment still claims the document panel needs it, three months after D-BW deleted the panel),
  `models.countDevices` (whose doc names `lifecycle.nim` as its caller, while `lifecycle` uses its
  own private `deviceCount` with *different* semantics for an empty field), `db.columnNames`,
  `pipeline.parseAttachments`, `rag.indexFile`, `nvimctl.alive` (at `nvimctl.nim:158`, **not** the
  `:350` an agent cited into a 196-line file), `tray.isRegistered`, and `pipeline.forget` — the
  eviction hook for `ParseMemo`, never called, which is why A-53 below is unbounded.
- **Unbounded caches with no eviction** — `gui.thumbCache` (a decoded pixbuf per attachment per
  size, including the 900px preview entry, for the life of the process), `pipeline.ParseMemo` and
  `markdown.BlockMemo` (both retaining parsed JSON and full base64 payloads across conversation
  switches and past deletion). `BlockMemo` has no eviction proc at all.
- **Two diagnostics tell the user to run `make llama`** and there is no Makefile — and L4 forbids
  adding one. `src/jenova_core.nim:114` and `:2656`. *(Re-checked 2026-09-03 09:48: the count is
  **two**. This row said seven, counting five `run: make core` lines in `tests/*.sh`; Session 024's
  test pass changed all five to `run: nimble core`.)* `docs/install.md` and `README.md` both state
  flatly that there is no Makefile.
- **Stale comments describing deleted code** — `server.nim:83-85` describes an in-process
  model-loading fallback deleted under D-AF, attached to the acceptor's shutdown flag;
  `vte.buildTerminal`'s `file` parameter is a dead branch left by D-BW's removal of the second
  terminal; three `libdbus` functions are bound against the module's explicit no-dead-surface
  claim; `tray.appendItemProps` declares a `DBusMessageIter` it never uses and `discard`s it to
  quiet the compiler.
- **`hardware.detectStorage` prints a two-valued guess as a detected fact** — `if zpool list
  succeeds: "ZFS" else "UFS"` (`src/jenova/hardware.nim:259`), never inspecting a mount or the root
  device, displayed under a heading that says "Detected". `detectMemory` truncates downward, so a
  16 GB machine reads "15 GiB". Both are display-only — `scoreProfile` reads neither.
- **`http.urlDecode` and `server.jsonEscape` re-implement `std/uri` and `std/json`** in modules
  that already import the alternative. Both are small, both look correct, both are on cold paths.
  Recorded only because `PROGRESS.md:1592` records deleting exactly this class from `gui.nim` once.
- **`gui.lanAddress` composes `sh -c` pipelines with embedded `awk`** (`src/jenova/gui.nim:477-486`)
  **fourteen lines below `runCapture`'s doc comment stating that commands are "invoked with an
  argument vector, never a shell string"** and that this removes the need for a quoting helper —
  while `lanAddress` uses `quoteShell(iface)`. It is the only `awk` in the tree.

### A-61 … A-65 — findings this file failed to record on the first pass

**These five were produced by the audit and were missing from the A-series until a self-check on
2026-09-03 caught them.** Recorded here rather than renumbered into place, because renumbering
would break every reference already written into `PLANS.md`, `BRIEFING.md` and `DECISIONS_LOG.md`.
**The omission is worth stating plainly:** an audit whose whole subject is claims that do not match
reality dropped 5 of its own 64 findings on the way into the tracker.

| ID | V | What it is |
|---|---|---|
| **A-61** | `[V]` | **PDF extraction accepts a partial decode and presents it as the document's text.** `pdf.textFrom` runs `looksReadable` per content stream and appends only the streams that pass, returning whatever accumulated (`src/jenova/pdf.nim:184-192`). **The documented contract is all-or-nothing** — "a PDF with no readable text is refused, never attached empty" appears in `pdf.nim`'s header, in `readAttachment`'s refusal message and in four `.devdocs/` files — but that holds only when *every* stream fails. **A document where some streams decode and others do not attaches the readable fraction with no marker and no warning to the model.** Two mechanisms widen the silently-failing set: the filter test reads the *last* `<<` before `stream` (`:170-177`), so a dictionary with a nested `/DecodeParms <<…>>` never matches `FlateDecode` and its compressed bytes are added verbatim then dropped; and the body is delimited by string-searching `endstream` rather than honouring `/Length` (`:167`), so compressed bytes containing that sequence truncate the stream. The honestly-declared limits — no layout, no reading order, no page images, Identity-H rejected — are **not** the finding; the undeclared half is that the refusal is per-document only in the total-failure case. **PROMOTED 2026-09-03 12:40 to a data-integrity defect of A-3's and A-4's class — and finding this row's mechanism WRONG is what promoted it.** The row described partiality *within* a stream, **which does not happen** — `zlib.inflate` returns ok only on `ZOk`. **The real partiality is *across* streams**, and it is simpler and worse: `pdf.nim:174-175` is `let r = zlib.inflate(raw)` / `if r.ok: result.add r.data` **with no `else`**, and the loop then continues at `i = e + 9` — **so a stream that fails to inflate, or exceeds `MaxInflatedBytes`, is silently skipped and extraction proceeds.** Verified here. `textFrom`'s docstring promises the caller it "refuses on all three rather than attaching a blank"; **it refuses only when the document is TOTALLY empty.** A 70%-decoded PDF is attached as though it were the document. **This breaks D-BQ — a stated project rule — by a path D-BQ never considered.** |
| **A-62** | `[V]` | **Six path keys are evaluated out of the conf files and never consulted.** `config.Keys` opens with `JCA_HOME`, `JENOVA_STATE`, `LOG_DIR`, `CACHE_DIR`, `PID_FILE`, `LLAMA_SERVER` (`src/jenova/config.nim:35`) and `evalConfFiles` sources both conf files to read them back. **Nothing asks the `Config` for any of them** — `paths.resolve` reads each one with `getEnv` and a derived default instead (`src/jenova/paths.nim:71`, `:88-90`, `:94`, `:97`), and because the confs are evaluated in a *child* `/bin/sh` their `export`s die with it. **So `etc/jenova.local.conf:5`'s `LLAMA_SERVER=…` does nothing**, while `config.render` still prints it back to the operator as though it were live. `config.nim:30-33` states the opposite — "an unlisted key is a key nothing consumes" — which reads as a guarantee that listed keys *are* consumed. **Two silently divergent precedence rules for the same six settings.** |
| **A-63** | `[V]` | **Six further conf keys have no consumer anywhere**, including the three documented agent limits. `API_URL`, `LLAMA_URL`, `LLAMA_EMBED_URL`, `MAX_TURNS`, `MAX_ACTIONS` and `TIMEOUT` appear nowhere in `src/` outside `config.Keys` — not as `c.get`, not as `getEnv`, not as a literal. `etc/jenova.conf` presents three under a `# --- Agent ---` heading with real-looking values and computes the three URLs across `:42-46` including a loopback-substitution branch. **All of it is dead:** the upstream addresses are derived from `LLAMA_PORT`/`LLAMA_EMBED_PORT` and a hard-coded `127.0.0.1`, and there is no turn or action limiter in the tree. `JENOVA_HEALTH_TIMEOUT` is a seventh and is the only one whose inertness is written down. **A user reading the conf has no way to tell the live keys from the ornamental ones.** **CORRECTED 2026-09-03 12:40: it is SEVEN dead keys, not six** — `API_URL`, `LLAMA_URL`, `LLAMA_EMBED_URL`, `MAX_TURNS`, `MAX_ACTIONS`, `TIMEOUT` **and `JENOVA_HEALTH_TIMEOUT`**, which this row had noted separately as "a seventh whose inertness is written down" rather than counting. **And record how it was established, because it is the right method: the search was validated against a control** — six other keys were run through the same search and each returned exactly one consumer, **so the method is not simply failing to find things.** A negative result from an unvalidated search is not a finding; this one is. |
| **A-64** | **REFUTED as written, 2026-09-03 12:40 — replaced, not deleted, so it is not rediscovered.** *(The row said "no backend tuning value is reachable from the window". **That is false.** `gui.nim:4075` sends `ControlJob(action: "apply_profile")`, handled at `:894`, calling `hardware.applyProfile` (`hardware.nim:399`), which copies a profile's whole `jenova.conf` into `$JCA_HOME/etc/` — `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `DEVICES`, `TENSOR_SPLIT` and the rest. **Step 6 built this and the row did not account for it.** **First refutation of the sweep**, and it is why refutations are recorded as prominently as confirmations.)* **The narrower claim that survives, and it is still a real gap:** **no *individual* tuning value can be set from the window — it is profiles wholesale or nothing.** A user who wants one different `CTX_SIZE` must hand-edit a file, which is what **D-BC** calls a defect. Seventeen live keys appear in none of `settings.Defs`' 41 fields. | **No backend tuning value is reachable from the window.** Seventeen live keys — `DEVICES`, `TENSOR_SPLIT`, `FIT_TARGET`, `NGL_AGENT`, `CTX_SIZE`, `NUM_SLOTS`, `KV_CACHE_TYPE`, `THREADS`, `THREADS_BATCH`, `BATCH_SIZE`, `UBATCH_SIZE`, `JENOVA_DRAFT`, `DRAFT_DEVICE`, `HOST`, `PORT`, `LLAMA_PORT`, `LLAMA_EMBED_PORT` — appear in none of `settings.Defs`' 41 fields, and the Hardware screen offers only a whole-profile Apply. Under **D-BC** a value that needs a hand-edited file is a defect. **Scope note:** the original finding also argued that Apply is partly inert because `jenova.local.conf` overrides it. **That half is withdrawn** — one verification lens refuted it and the USER has ruled that file their own in-use config, out of scope (**D-CF**). What survives is the first half only: there is no GUI surface for backend tuning at all. |
| **A-65** | `[V]` | **The dependency audit found nothing proprietary and two undeclared runtime dependencies.** Full external set read from `jenova_core.nimble` and every `passL`/`passC`/`dynlib` pragma: Nim (MIT), owlkettle (MIT), gtk4/libadwaita/gtksourceview-5 (LGPL-2.1), vte-2.91-gtk4 (LGPL-3.0), dbus (AFL-2.1/GPL-2), libz (zlib), sqlite3 (public domain), llama.cpp/ggml (MIT), vulkan-loader (Apache-2.0), cmake (BSD-3). **Nothing proprietary; nothing non-FOSS.** Two were absent from `BLUEPRINT.md`'s table and **have been added in this pass**: `cairo` (via `owlkettle/cairo`, `canvas.nim`) and `libpcre` (via `std/re`, imported by `hardware.nim`) — the latter matters because a Nim `dynlib` that fails to load terminates the process, so on a host without libpcre the failure lands when the Hardware screen first scores a profile. **The AGENTS.md Directive 2 tension is not a finding** — D-X settled it and `BLUEPRINT.md` §6 records the reasoning; it is noted only so a fourth session does not re-derive it. |

### A-53 … A-57 — coverage gaps the audit found in itself

**A completeness critic re-read the audit's own coverage.** These are areas nothing examined, and
they are recorded so the next session does not mistake silence for a clean bill.

| ID | V | What it is |
|---|---|---|
| **A-53** | `[V]` | **The desktop settings do not govern a LAN request.** `settings.applyTo` has exactly one caller in the tree — `pipeline.chatBody` (`src/jenova/pipeline.nim:442`). The LAN path is `server.handle` → `pipeline.prepare`, **and `prepare` takes no `Settings` parameter at all** (`:289`). So the ~20 `inRequest` keys — temperature, top_k, top_p, min_p, typ_p, the xtc and dry families, max_tokens, samplers and the whole penalties section — apply only to bodies the window itself builds. A LAN client supplies its own, so this may be correct by design; **nothing in the window says so, and `BLUEPRINT.md` §5's wording implies it is universal.** Needs a USER ruling — see the open question in `PLANS.md`. |
| **A-54** | `[V]` | **`docs/` is stale in ways that contradict the shipped product.** `docs/context-and-retrieval.md:85-99` is a section headed **"Why it returns nothing today"** asserting that nothing fills the retrieval index, that `indexContent`/`indexFile`'s only callers are `rag-selftest`, and that `--- REPOSITORY CONTEXT ---` never appears in a real request. **All false since T-17 was closed:** `rag.indexExchange` has five production call sites — `api.nim:462`, `:474`, `:881`, `:919` and `gui.nim:830`. Sections 5, 6 and 7 are titled "— the Web UI only" for workspace context and per-message attachments; the window has both. `docs/architecture.md` and `docs/usage.md` were not read by anything. **`docs/` is user-facing and outside `.devdocs/`, so correcting it is product work and gated by Directive 1.** |
| **A-55** | `[V]` | **`--lan` publishes an unauthenticated read/write filesystem and database surface, and the blast radius is written down nowhere.** `--lan` binds `0.0.0.0`. On that port `api.handleStorage` serves GET (read any file under the workspaces root), POST (write arbitrary bytes to any contained path) and DELETE, and `api.handleDb` is full CRUD. **No credential is required for any of it.** The absence is deliberate and recorded — `settings.OmittedFields` says "this server does not authenticate" and `docs/privacy.md` has a section titled "No authentication" — but containment bounds the damage without eliminating it: **anything on the LAN can plant files that the embedded Neovim and the note editor will open, and can rewrite or delete notes and conversations.** T-4 and A-19 hardened containment without anyone asking what it protects against. **CODE HALF CONFIRMED 2026-09-03 12:40:** zero hits for `Authorization`, `api_key`, `apiKey`, `bearer` or `Bearer` across `server.nim`, `api.nim` and `routes.nim` — **there is no authentication of any kind on any route.** **A-19's lexical containment was on that surface and is now CLOSED** (12f-3, asserted, including the escape through `restoreMirror`). **DOCUMENTATION HALF — answered by the `.devdocs` session, which owns it, and it is mostly a REFUTATION.** The blast radius **is** written down, clearly, where a careful reader would look: `docs/privacy.md:38-45` has a section headed **"No authentication"** stating that access control is the bind address and the firewall "and nothing else", and that `--lan` is *"reachable by **anyone on your network**, with full access to your workspaces, files and inference"*, followed by "Only enable LAN mode on a network you trust." `README.md:47-49` and `docs/architecture.md:49` cover the port story. **So the standing claim that the blast radius is "written down nowhere" is false and this row should stop saying it.** **What survives is narrow and real: the section that *invites* the user to switch it on carries no warning and no pointer.** `README.md:76-81` — "LAN mode" — describes reaching your workspace "from a phone, tablet or second machine" and says the window and tray toggle the same thing, **with nothing about authentication and no link to `privacy.md`.** The warning is in the document people read when they are already worried; the invitation is in the document people read when they are deciding. **The fix is one cross-reference, and it is `docs/` work, so it is product work gated by Directive 1 (see A-54).** |
| **A-56** | `[V]` | **There is no unicode awareness anywhere in `src/`.** A search for `std/unicode`, `Rune`, `runeLen` and `validateUtf8` returns nothing. Every string operation is byte-indexed — `markdown.inlineSpan` slices `s[start+delim.len ..< stop]`, the heading handlers slice `t[4 .. ^1]`, `trimHistory` measures bytes, `http.urlDecode` reassembles escapes — and the result goes to a Pango Label with `useMarkup = true`. **A byte slice landing mid-UTF-8-sequence produces a string GTK refuses to render**, and this is arbitrary model output including CJK, emoji and accented Latin. Escaping *is* handled (`markdown.escape`), so this is an encoding bug and not a markup-injection one. |
| **A-57** | `[V]` | **There is nowhere for a failure to go.** Neither binary writes an application log: `lifecycle.logFileFor` produces two paths and both are llama-server's own stdout/stderr redirected before exec. The GUI contains one `echo` in 4,515 lines, behind `--check`. The only other diagnostic is `stderr.writeLine` in `jenova_gui.nim:74`, invisible when launched from the `.desktop` file. **Against that, 32 sites across 11 modules swallow an exception with `discard`** — `hardware.nim` alone has 10. A-14, A-21, A-27 and A-35 are four separate silent-failure findings that **share this root cause**, and fixing them one at a time will keep producing more. There is a tracked `var/log/.gitkeep` implying a log directory nothing writes to. **TWO CORRECTIONS 2026-09-03 12:40, and the second corrects the correction — this row's number has now been wrong twice.** *(1)* The row said **58** discard sites; a verifier counted **32** one-line `except X: discard`; **counted here it is 30**, with the exact `except CatchableError: discard` form being **18** and multi-line blocks whose body is a lone `discard` on top of that. **Write it as "roughly 50 silent-discard sites across three syntactic forms — count them, do not quote a figure from this file."** *(2)* **The claim "exactly one diagnostic sink in the entire product" is FALSE** — there are **six** `stderr.writeLine` sites: `server.nim:345`, `jenova_gui.nim:74`, and four in `jenova_core.nim` (`:257`, `:263`, `:3585`, `:3593`). **What IS exact, and is the finding: there is no logger, no log file and no `proc log` anywhere in `src/` — zero hits.** `lifecycle.logFileFor` produces the *backend's* log, not Jenova's. **A count was corrected with another wrong count, inside the row about things failing silently. That is rule 9's ninth appearance in this file and the reason the figure is now a word rather than a number.** |

### A-58 — first-run and empty-state behaviour is untraced

`[A]` Nobody established what the window does when the database does not exist, when no `.gguf` is
installed under `models/agent` (`models.nim:150` raises), when `llama-server` is not built
(`jenova_core.nim:114` tells the user to run a command that does not exist — see A-52), or when
`public/` is empty. **Each of these is the state of a fresh clone**, and `public/` is gitignored and
untracked, so a clone that runs `nimble gui` gets a window and a static route serving nothing until
`nimble web` has run an npm dependency graph. Under L5 every one of these states must be recoverable
from the window; at least one demonstrably is not.

### A-66 — the remaining coverage gaps, recorded so silence is not mistaken for a clean result

`[A]` The completeness critic named these and nothing examined them. **They are not findings —
they are known-unexamined areas**, and the distinction matters: no one has looked, so no one should
claim they are fine.

- **HTTP input validation and the resource envelope.** `http.parseRequest` enforces no method
  whitelist, no path-length cap, no header-count cap and no per-header size cap; `readHead` tests
  `data.len > MaxHeadBytes` only *after* appending a chunk, so a head can overshoot by one chunk.
  And `MaxBodyBytes` is a 32 MiB **fully-buffered** read per connection against 14 handler threads
  — roughly 450 MiB of resident body buffer in the worst case. A-34 and A-35 covered framing
  correctness; nobody costed this, and on an unauthenticated LAN port (A-55) it is the reachable side.
- **The self-test bodies were never read.** Roughly 900-1,100 lines of `src/jenova_core.nim` —
  the `tree-`, `attach-`, `error-`, `markdown-`, `nvim-env-`, `models-`, `hardware-` and the head of
  `rag-selftest` — were grep-sampled, not read. **Nobody has verified that a `check(...)` in them
  can actually fail:** that the conditions are non-trivial, that no fixture is built by the code
  under test, that `bad` is incremented on the paths that matter. The pattern is sound where it was
  sampled. **"Sound where sampled" is not "these tests test something"** — *(the second half of this
  bullet said "per A-1 nothing runs them anyway"; A-1 is closed and they do run now, which makes
  this gap sharper rather than softer: the assertions execute, so whether they discriminate is the
  only remaining question)*. **Deferred with all test work under A-68.**
- **Time and timezone handling.** Ordering and identity depend on wall-clock in several places:
  `fssync.epochPrefix` names trash entries `$int(epochTime())` at **one-second resolution**, which
  is a collision waiting to happen for a multi-file delete; `fssync` seeds its UUID RNG from
  `epochTime()`; `rag` stamps chunks the same way; and `api.nim` writes `strftime('%s','now')` from
  SQLite — **two different clocks writing into one database.** Nothing was checked about what the
  transcript displays as a message time, or in which zone.
- **`theme.nim`'s generated CSS body** (~430 lines) was skimmed by three agents and read by none.
  It is the only region of `src/` genuinely unread by everyone. **The check that matters is
  mechanical and nobody ran it:** every `StyleClass(...)` name attached in `gui.nim` must have a
  matching rule here, and a rule with no widget is dead. G-37 is two known instances of exactly
  that; the correspondence as a whole is unverified.
- **`.gitignore`'s headline comment is false and asks the USER to decide something already
  decided.** It opens by describing `bin/jenova` as "listed below AND tracked in git … a ~2 MB
  binary re-committed on every build", and asks the USER to choose. **`git ls-files bin` returns
  only `bin/jenova.desktop`** — the binary was untracked in `495855c0`. Prose only, in a tracked
  file, and it is L9-adjacent: a derivable fact written down instead of read from the tree.
- **`public/` is not in the repository and half the advertised product lives there.** It is
  gitignored and `git ls-files public` returns nothing, yet `routes.nim` gives the static class the
  largest thread pool, `README.md` advertises KaTeX, MCP, PDF viewing and think-blocks as product
  features, and the only way to obtain any of it is `nimble web` running `npm install`. **A fresh
  clone that runs `nimble gui` gets a window and a static route serving an empty directory.** What
  `:8080` answers in that state was never traced (see A-58).

### A-67 — traceability: where each of the 64 findings landed

**Written so this file's coverage can be checked mechanically rather than trusted.** The audit's
sweeps used their own IDs; this maps every one to its A-row. **A self-check on 2026-09-03 found
five had been dropped on the first pass** — `SIM-04`, `R-02`, `R-03`, `R-08`, `R-13` — which is
why this index exists.

| Sweep ID | A-row | | Sweep ID | A-row |
|---|---|---|---|---|
| S-01, SIM-01 | A-7 | | HTTP-BODY-CAP-MISMATCH | A-4 |
| S-02 | A-16 | | HTTP-NO-CHUNKED-REQ | A-34 |
| S-03, R-09 | A-52 | | HTTP-SHORT-BODY-SILENT | A-35 |
| S-04, S-05, S-11 | A-52 | | SRV-PEEKPATH-WINDOW | A-36 |
| S-06, SIM-07, SET-STALE-AWAITING | A-29, A-30 | | SRV-HEAD-STATIC-ONLY | A-37 |
| S-07 | A-17 | | SRV-HANDOFF-DEAD | A-38 |
| S-08, R-04 | A-27 | | GUI-SSE-NO-DECHUNK | A-32 |
| S-09, RAG-FULL-SCAN-PER-QUERY | A-12 | | GUI-COUNTLINES-IN-VIEW | A-28 |
| S-10 | A-23 | | DB-NO-MIGRATION-MECHANISM | A-22 |
| S-12 | A-18 | | DB-QUERYBLOB-SWALLOWS-ERRORS | A-21 |
| S-13 | A-52 | | API-CASCADE-NOT-ATOMIC | A-20 |
| S-14, S-15, S-16, S-17 | A-52 | | API-DELETEDROWS-NO-ORDER | A-24 |
| SIM-02 | A-5 | | FS-RESTORE-LEXICAL-CONTAINMENT | A-19 |
| SIM-03 | A-14 | | RAG-FILTER-AFTER-TRUNCATION | A-11 |
| SIM-04 | **A-61** | | RAG-DIM-MISMATCH-SILENT | A-10 |
| SIM-05, PIPE-TRIMMED-UNREPORTED | A-8 | | WS-BUDGET-UNTRIMMABLE | A-13 |
| SIM-06 | A-9 | | WEB-SNIPPET-PAIRING | A-15 |
| SIM-08 | A-52 | | SV-ALIAS-COVERAGE | A-51 |
| MD-LINKS | A-48 | | R-01 | A-6 |
| MD-BLOCKS | A-49 | | R-02 | **A-62** |
| MD-EMPH-GREEDY | A-50 | | R-03 | **A-63** |
| PIPE-ATTACH-NUKES-HISTORY | A-3 | | R-05, R-12 | A-52 |
| R-06 | A-47 | | R-08 | **A-64** |
| R-07 | A-26 | | R-13 | **A-65** |
| R-10 | A-33 | | R-11 | **G-51**, already in Backlog above |

**`R-14` is deliberately absent.** It examined `config.nim` evaluating the conf files through
`/bin/sh` and **concluded it is by design, not a circumvention** — the conf files genuinely are
shell, a hand-written parser for a shell subset would return a plausible wrong answer, and
positional parameters mean no path is interpolated into the script text. `BLUEPRINT.md` §6 already
scopes `/bin/sh` exactly that way. **Recorded here so it is not "rediscovered" as a defect.** The
two consequences that *are* real are A-62 and the note in **D-CF**.

**Beyond the 64:** A-1, A-2 and A-53 … A-58 and A-66 came from the completeness critic; A-25
(`CANVAS=0`), A-39 … A-46 came from the seven mechanism analyses; A-31 and A-60 were found by this
session directly; A-59 is the parity inventory.

### A-59 — the Web UI ↔ GUI parity inventory. **ACTIVE — it is `PLANS.md` Step 13.**

**The authoritative inventory this project has never had.** 1,095 Web UI features were enumerated
from `jca_web/src` — component sources and barrel files both — against the six-item scope list
Sessions 010-012 wrote from a summary. **Rule 11 is now satisfiable:** check a scope claim against
this inventory.

> **Corrected 2026-09-03 11:38. This said "Full per-feature verdicts are in the session record" and
> they are not in any record.** A search of all twelve trackers returns the nine-row table below and
> nothing else; Session 023's `SESSION_HANDOFF.md` entry records the *counts*, not the verdicts.
> **So 13c has no work list** — the 866 leads exist nowhere and cannot be picked up as written. The
> source is intact (`jca_web/src/lib/components/app/` holds thirteen component directories and
> `lib/services` fourteen modules), so the recovery is to re-derive one area at a time from it,
> exactly as `data-services` was re-derived first-hand on 2026-09-03 09:48 — which is also the pass
> that turned 147 features into three real gaps. **Budget for that re-derivation when scoping 13c;
> it is not a lookup.**

The shape of the inventory is:

| Area | Web features | Missing | Partial | Present | N/A |
|---|---|---|---|---|---|
| views-dialogs | 163 | 65 | 39 | 28 | 21 |
| models-server | 119 | 61 | 30 | 10 | 17 |
| sidebar-workspace | 135 | 47 | 31 | 50 | 6 |
| attachments | 97 | 46 | 23 | 20 | 2 |
| chat-messages | 113 | 43 | 28 | 24 | 0 |
| content-render | 89 | 42 | 15 | 20 | 10 |
| settings | 134 | 42 | 15 | 60 | 6 |
| chat-form | 98 | 30 | 18 | 13 | 3 |
| **data-services** | **147** | **3 root causes** | — | — | — |

**Do not read "Missing" as a feature count.** The granularity is deliberately fine and the verdicts
were produced by one agent each with no adversarial re-check, so they are leads. Many collapse to a
single root cause — **six of the chat-form gaps are all downstream of one fact: the composer is a
one-line `Entry` bound to a string, not a `TextView` with a buffer** (`gui.nim`, the chat form's
`Entry` bound to `app.draft`), which is what blocks multi-line drafts, Shift+Enter, autogrow, the
height cap and the height reset together.

**`data-services` was checked first-hand 2026-09-03 09:48** `[V]` — all fourteen service modules
read against `src/` — and **its three gaps were built the same day** (`PROGRESS.md` 10:21). They
were: conversation markdown export/import, forking a conversation, and the `pull` half of the
mirror. Everything else in the area was already built, is **A-18**, or is ruled out by **D-BZ** /
the MCP deferral. The breakdown is `PLANS.md` Step 13b, so it is not re-derived here.

**The composer is a `TextView` as of 10:21**, so the six chat-form rows behind it are closed too.
**What remains of this inventory is the other eight areas' 866 verdicts** — leads, not facts.

### A-60 — **CLOSED 2026-09-03 09:10.** The archival half is done; one half deliberately remains.

`[V]` **Archived on the USER's instruction.** `PROGRESS.md` was **117** entries *(this row said
"~122" — counted, it was 117)* against `AGENTS.md`'s ~40 threshold. The oldest 58 are now
`PROGRESS_ARCHIVE.md`; the oldest 18 sessions are `SESSION_HANDOFF_ARCHIVE.md`. Order preserved,
pointers in both live files. `PROGRESS.md` 229 KB → 105 KB, `SESSION_HANDOFF.md` 205 KB → 86 KB.

**What was NOT done and is not scheduled:** `AGENTS.md` defines `PROGRESS.md` as a milestone ledger
— *one line per completed item, no session narrative* — and many entries are multi-paragraph
narratives that belong in `SESSION_HANDOFF.md`. **Reshaping them is not archival and was not asked
for.** Recorded so it is not mistaken for finished, and not re-raised as a defect.

**Noted, not work:** `jca_web/src/lib/components/app/workspace/` holds one orphan file,
`FlashModelUpload.svelte`, with an empty `index.ts` and nothing importing it. It is the
one directory under `components/app/` the barrel does not export, so it is **not** part
of the parity inventory. Recorded so it is not rediscovered and mistaken for a gap.
`jca_web` is frozen (D-Z) — this is not a licence to edit it.

---

## Active — defects in the Nim code, each verified by reading it

**Step 9 is built — this section is empty of defects.** T-5, T-2, T-4 and T-3 were
built 2026-09-02 12:19; the record is `PROGRESS.md`.

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

**T-5, T-2, T-4 and T-3 are gone from this file because they are built**
(`PROGRESS.md`, 2026-09-02 12:19). Per the completion rule their record lives there.
Quitting stops the embedding server; the prepared-statement cache is capped and flushed;
the file-containment check resolves the deepest existing ancestor against a resolved base,
so a new file cannot be written through an escaping symlink and a symlinked workspaces root
no longer refuses its own tree; and chat history is trimmed to a byte budget, oldest first,
never the system message and never the final turn.

**Two things stated plainly rather than dressed up.** The history budget is derived from
`CTX_SIZE` divided by `NUM_SLOTS` at four bytes per token and halved — **an approximation,
and recorded as one**; an exact figure needs the model's own tokenizer, which is an HTTP
round trip per turn on the hot path. And **T-5's join is not asserted**: that `gui.run`'s
`defer` calls it cannot be checked from a test binary, because `gui.nim` links into none.
`lifecycle.stop`'s own behaviour is asserted; the call site is a screen run.


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
scripts are **removed from the tree**, and `hardware-profiles/` holds data only.

> **Corrected 2026-09-03.** This said the six scripts "are in `.devdocs/ARCHIVE/hardware-profiles/`".
> That directory was deleted by the USER in `349a9b5b`; the scripts live in git history only.
> The operative half — no shell script anywhere in the product tree outside `tests/` — still holds
> and was re-confirmed this session. See **D-CE**.

**`tests/*.sh` are the six test harnesses, not product code.** They are the only shell
files left anywhere outside `external/` and `jvim/pack/` *(corrected 2026-09-03: this named
`.devdocs/ARCHIVE/`, deleted by the USER — **D-CE** — and omitted `jvim/`'s 24 vendored
third-party plugin scripts, which are configuration and exempt under D-BS)*.

*(**A-2 is closed** — 2026-09-03 09:02, `PROGRESS.md`. Five of the six now fail rather than skip
when a prerequisite is missing; **`test_nvimctl.sh` still skips on a missing `nvim`, ruled by the
USER**, because `nvim` is not a build dependency of either binary.)*

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
