# BRIEFING

**Last updated:** 2026-09-03 11:45 (Session 026c)
**Branch:** `bsd`, at **`256a6528`**. **The working tree is NOT clean and code is being changed
right now — read §0a before you touch `src/`.** *(This header said `9fc9ecc7` "with Session 025's
work uncommitted". The USER committed it as `256a6528`; the commit is titled "Chat bubble resizing"
and its content is the whole of Session 025 — 13a, 13b, the three composer repairs and the SIGBUS
fix. **The branch header was a commit stale in three consecutive sessions**, which is why this line
is checked with `git log` and never carried forward.)*
**Step 13a and 13b are built.** **13a's composer was rebuilt at 11:14 as `DraftView`** after two
failed repairs from the USER's screen, and **a SIGBUS on Enter was fixed at 11:24** — an event
handler bound in `afterBuild` held a pointer freed on the first redraw. All of it is in
`PROGRESS.md`, with the five toolkit traps collected in `PLANS.md` Step 13a. Two new modules
(`composer.nim`, `convmd.nim`), and `gui.nim`, `api.nim`, `fssync.nim`, `theme.nim`,
`jenova_core.nim` and `jenova_core.nimble` changed. That build was green — every self-test passed,
both binaries built, `bin/jenova --check` exited 0. **Do not carry that record forward as current:
`src/` has moved a long way since.** **Whether the tree builds is a fact with a five-minute shelf
life while §0a is live** — this sentence has already carried two binary timestamps that were false
within minutes of being written. **Run `nimble core` and `nimble gui` and find out.** `jvim/` is
tracked on purpose and `.gitignore` says so.

**Session 026 re-derived 22 A-series claims against `src/` and refuted none.** The findings hold;
**every `gui.nim` address in them was wrong**, which is the seventh sweep's ruling being ignored
when the A-series was written. The corrections are in `TODOS.md` at the head of the A-series.

**Then, on the USER's approval: A-69 fixed at 11:38 and nothing else** (`PROGRESS.md`;
`gui.nim` rebuilt, `--check` 0). **Two things this session found that are not in the A-series
corrections above:** the 866 parity verdicts behind 13c **exist in no record at all** — `TODOS.md`
A-59's pointer to "the session record" was checked and is false, so 13c's first step is
re-deriving one area from `jca_web/src`, not looking a list up; and `PROGRESS.md`'s 2026-09-02
07:51 entry, which recorded 10b as built, now carries the correction saying it never worked.

---

## 0. THE USER HAS REPORTED THE DAY'S WORK INCOMPLETE. READ THIS BEFORE TRUSTING ANY "BUILT" ENTRY BELOW.

> **2026-09-03, from the USER, verbatim: *"almost all the features and functions that were
> implemented or fixed are incomplete."***
>
> **That outranks every green result recorded today** (rule 1: never deny what plainly was run;
> rule 12: a "not yet run" label survives exactly until evidence contradicts it). **It is not to be
> argued with, re-verified against the assertions, or explained away — the assertions were never
> what was in question.**
>
> ### Fourteen units were recorded as BUILT on 2026-09-03. **Every one of them is now UNCONFIRMED.**
>
> A-69, A-70, A-48, A-26, A-17, A-16, A-20, A-24, A-19, A-18, Step 12c, Step 12d, and the rest.
> **The `PROGRESS.md` entries stay** — they are the point-in-time record of what was changed and
> why, and several carry reasoning worth keeping. **What was wrong is the word "built".**
>
> ### This was predicted, in writing, by these documents, and done anyway
>
> **Every unit's own entry carries the disclosure:** *"unobserved — the render branch is a widget"*;
> *"that the row now survives is a USER screen run"*; *"nobody has seen a cache hit"*; *"A-18-2 and
> A-18-3 are almost entirely widgets"*. **§6 says `gui.nim` has no coverage of any kind and that
> every GUI defect in this project's history was found by the USER looking at the screen.** Rule 17
> says `--check` builds each branch once, allocates no sizes and routes no events.
>
> **Fourteen units were produced in one afternoon against that standing gap and labelled done.**
> Green assertions proved the parts. **Rule 15 — a green suite says the parts work, never that
> anything calls them — is the exact failure, and it is in this file, numbered, above.**
>
> ### The USER has stated which it is, and it is the worse of the two
>
> **The fixes are half-done ON SCREEN. The things recorded as built do not work when used.**
> *(Asked and answered 2026-09-03. The alternative reading — "repairs rather than features, the
> parity work never moved" — was offered and is NOT what was reported.)*
>
> **This session had already checked, by reading, that every surface EXISTS in the tree:** A-70's
> SYSTEM branch (`gui.nim:3433`/`:3439`/`:3445`), A-18's second trash section (`:4069-4081`) and
> Empty Trash button (`:4019-4022`), 12d-3's `cacheHit` reaching `statsLine` (`:2958`/`:2961`),
> A-48's `<a href>` genuinely emitted (`markdown.nim:149`). **So the joins are present in the source
> and broken in the window.** *That is precisely the class no assertion, no `--check` and no amount
> of reading can reach* — **and it is the class this project has already paid three unusable builds
> and one SIGBUS to learn about.**
>
> ### **The first thing to do is re-check every widget added today against the trap catalogue we already own.**
>
> Session 025 recorded **five owlkettle traps** in `PLANS.md` Step 13a, every one of which produced
> a widget that was **green on every check this project can run and completely unusable on screen**:
> `addOverlay` defaults to `AlignFill` and a targetable child swallows every click; `xAlign`/`yAlign`
> align text *inside* a label and do not size it; **a `property` hook is overwritten by
> `afterBuild`**; **`ContentScroll` must not be reused for anything but a transcript block** — its
> `halign = START` and natural-width propagation collapse an empty child to nothing; **GTK4 CSS has
> no `max-height`**; and **a raw pointer into an owlkettle `EventObj` may be held for one update
> cycle only.** Add **G-51**: a child inserted before `gui.fullscreenButton` in a row aborts the
> process on the next redraw.
>
> **Nobody checked today's fourteen units against that list.** It is the highest-value thing
> available and it needs no screen.
>
> ### One hazard found by reading, and it is the shape to look for
>
> **A-18-3 inserted "Empty Trash" into the trash panel's header row *before* the Close button**
> (`gui.nim`, the `Box(orient = OrientX)` above the `ScrolledWindow`), taking that row from three
> children to four **and shifting Close's index by one.** **G-51's mechanism is exactly this:**
> owlkettle diffs a `Box`'s children **by index** and reuses a child's state whenever the type
> matches. All four are `Button`s. **This row does not abort**, because the abort needs a
> shortcut-carrying `Button` and `gui.fullscreenButton` is the only one in the program and is not
> here — **but "does not abort" is not "is correct", and index-shifted state reuse across same-typed
> children is the family this project has already been burned by.** Every other panel added today
> should be read the same way: **what index did a new child take, and what was there before it?**
>
> ### The instrument problem, stated plainly
>
> **This session verified by reading that every surface exists, and the USER reports they do not
> work. Both are true, and that is the definition of the gap.** No assertion, no `--check`, no
> amount of source reading reaches widget behaviour. **The USER's screen is the only instrument this
> project has, and today fourteen units were recorded as built without using it once.**
>
> ### RESOLVED BY REVERT AND VERIFIED — 2026-09-03 13:25:33. **The window starts again.**
>
> **`nimble core` 0, `nimble gui` 0, `bin/jenova --check` 0** — *"GTK initialised, window tree built,
> no window shown"* — **all sixteen self-tests 0, and the core count did not move: 30 → 30, delta
> zero.** *Verified by the same instrument that proved the crash, which is the point: a core-count
> delta of zero across a run is evidence in a way that "the source defect is gone" is not.*
>
> **The revert was one edit** — `MarkupLabel` back to `Label` at `mdBlock`'s `bkText` branch, with
> the attempt preserved as a comment. **A-48 kept everything that was ever established:** the
> allowlist, the 24 assertions and the rendering are all `markdown.nim` and were never touched.
>
> **The history below is kept in full, because what the three failed fixes bought is worth more than
> the feature was.**
>
> ### It took THREE fix-forward attempts before the revert, and the standing decision is why
>
> **The builder set its own condition — one attempt, then revert — and this was the third.** Each
> attempt left the window unstartable, and **three sessions could not verify anything through
> `--check` while it stood.** *A crashing window is strictly worse than a link whose click was never
> proven.* **Revert to green; do not fix forward. That is now the rule, not a judgement call.**
>
> ### THE WINDOW DID NOT START. `bin/jenova --check` SEGFAULTED. **Verified current at 13:23:27 — and twice mis-reported as stale.**
>
> **Nim's own message: `SIGSEGV: Illegal storage access. (Attempt to read from nil?)`** Frame 0 is
> **`gui.mdBlock`**, reached `run` → `build` → `view` → `mainArea` → `messageBody` → `mdBlock`, on
> the **first view build**. **29 cores in `/var/coredumps`.**
>
> **It was twice reported as already fixed and it was not.** The refutation is arithmetic, not
> argument: a build at **13:23:27**, newer than every source file (`gui.nim` 13:21:06), still exits
> **139**, and the core count went **28 → 29** across that single run — **so that run produced its
> own core.** *A "the source defect is gone and the binary post-dates it" reading cannot survive a
> core-count delta.*
>
> ### The cause, and it is NOT the markup
>
> **A bisect settled it — four builds of the same `MarkupLabel`, rendering byte-identical A-48
> markup through the identical `useMarkup` Label, varying only the event body:**
>
> | event body | `--check` |
> |---|---|
> | event omitted entirely | **0** |
> | `proc activate(uri: string) = discard uri` | **0** |
> | `proc activate(uri: string) = app.notice = uri` | **SIGSEGV** |
> | `proc activate(uri: string) = app.openLink(uri)` | **SIGSEGV** |
>
> **Two of the four pass on identical markup, so no markup-path cause survives.** Refuted with it:
> the `\x01`/`\x02` placeholder scheme, unbalanced `</a>`, `escape()` ordering, and **A-56's UTF-8
> slicing** — all named as suspects, all wrong.
>
> > **STATE THE CAUSE NARROWLY OR IT MISDIRECTS THE NEXT SESSION.** *"Capturing `app` in an event
> > closure is fatal"* **is false and would condemn the whole window** — `convRow`'s `proc
> > clicked()`, the sidebar, the trash panel and the settings panel all capture `app` and all work.
> > **The true statement is: a CUSTOM renderable's hand-declared event, rebuilt per frame inside
> > `view`** — the composer SIGBUS's family — **and `mdBlock` is the worst site for it because it
> > returns a fresh `Widget` per block, per message, per frame.** *The general version tells a future
> > session that custom renderables are unusable; the narrow one tells them where the boundary is.*
>
> ### **The faulting LINE is in a different branch from the faulting CAUSE — and this is the limit of "read the core first"**
>
> **It dies at `b.text.countLines` — A-28's exact line, in the CODE-BLOCK branch — while the closure
> causing it is in the TEXT branch.** *That is why frame 0 misled three sessions into the markup
> path.* **It is the argument for a bisect over a backtrace on this class of fault, and it belongs
> beside "on a SIGBUS, read the core first" as its stated limit:** a backtrace names where the
> process died, **which is not always where the defect is.** *Now recorded in the code itself at
> `gui.nim:2817`, next to the reverted branch.*
>
> **The genuine toolkit finding underneath:** capturing `app` in an event closure is an **established
> working pattern** — `settingsPanel`, `trashPanel` and the sidebar rows all do it. **What is new is
> doing it inside a `Widget`-returning proc that is itself called in a loop from another one:**
> `messageBody` calls `mdBlock` per block, per message. **Nobody is guessing beyond that.**
>
> ### **RULE 24 — a correlation is not evidence until you have built the control that could break it.**
>
> `markdown.nim` was modified at 13:14:26 and the first core is 13:15. **Two timestamps a minute
> apart were offered as "as close to a pointed finger as source-and-timestamps can get", and it was
> coincidence** — the crash arrived with the `gui.nim` renderable, not the markup emission.
> **The bisect that refuted it is the control that should have been built before the suspects were
> named.** *Sibling of rule 20 — a search returning nothing is not evidence until you have confirmed
> it could have found something — and the fourth instance of that family today.* **It was produced
> by a coder disproving its own fix.**
>
> ### Standing decision: **REVERT TO GREEN, do not fix forward.**
>
> **One edit — `MarkupLabel` back to `Label` at `mdBlock`'s `bkText` branch.** Three sessions cannot
> verify anything through `--check` while this stands, and **a crashing window is strictly worse
> than a link whose click was never proven.** **It costs A-48 nothing that was ever established:**
> the allowlist, the 24 assertions and the rendering are all `markdown.nim` and untouched. **What
> reverts is the activation, which was never proven.**
>
> ### A-48's activation — the strongest form of the finding, and it is worth more than the feature
>
> **Not "unobserved". Not merely "blocked on a renderable". The CORRECT renderable — built the
> sanctioned way, with owlkettle's own `state.connect` and correct hook ordering — segfaults on
> first build, for reasons not yet established.**
>
> **Three mechanisms are eliminated BY CONSTRUCTION, which is what makes this a real finding rather
> than a failed attempt:** the **markup path** (bisect: identical markup passes with an empty event
> body), the **hand-rolled signal connection** (replaced with `state.connect` — still cores), and the
> **hook ordering** (`beforeBuild` creates the widget, the `text` property hook dereferences one that
> exists — still cores). **What remains is the event closure capturing `app` inside a
> `Widget`-returning proc called in a loop.**
>
> **This is an owlkettle finding, not a coding error**, and it was produced by a builder disproving
> its own fix twice.
>
> ### An OPEN QUESTION, not an answer — **and it is the first thing that connects this crash to something the codebase already documented about itself**
>
> **Marked as a lead, untested, and recorded as a question deliberately.**
>
> **The fact, verified here, `jenova_core.nimble:29-40`** — the comment justifying `--mm:arc` for the
> GUI: *"owlkettle's `EventObj[T].widget` is a strong ref back to the state that owns the event, so
> **every widget with a callback is a `state → event → state` reference cycle**… ARC has no cycle
> collector, so those cycles leak instead. **The leak is bounded: GTK owns the widgets, and what is
> left behind is a small state object per discarded widget in a fixed-size tree.**"* **That same
> comment names the five SIGBUS cores of 2026-08-31 as the reason ARC was chosen at all.**
>
> **The theory:** that justification rests on *"a fixed-size tree"* — **and `mdBlock` is not one.** A
> fresh `Widget` per block, per message, per frame. A user-declared renderable carrying an event
> inside it would mint a new cycle every frame in a tree that grows with the transcript. **If it
> holds, A-48's crash is the August SIGBUS hazard reappearing exactly where the assumption behind the
> memory-management choice does not hold.**
>
> **What argues against it, recorded beside it because it may kill it:** `mdBlock`'s own code-copy
> `Button` does `proc clicked() = copyToClipboard(b.text)` (`gui.nim:2868`) — **per block, in the
> same loop, capturing the same borrowed `b` — and it is safe.**
>
> ### **REFUTED — the user-declared/built-in split does not exist. Recorded as refuted, not dropped.**
>
> **`widgetdef.nim:44-50`, read here:**
> ```nim
> EventObj*[T] = object
>   app*: Viewable        # strong ref to the whole AppState
>   callback*: T
>   handler*: culong
>   widget*: Renderable
> ```
> **A `Button`'s `clicked` and a custom renderable's `activate` are the same object, wired the same
> way.** There is no category "outside owlkettle's management" — it was invented. **And the nimble
> comment's cycle is worse than it states: the event holds `app` as well as `widget`.**
>
> ### The MEASURED boundary that replaces the theory
>
> > **In `mdBlock`, a closure capturing `app` segfaults; a closure capturing `b` does not.**
> > Four builds, byte-identical markup. `mdBlock`'s own code-copy `Button` captures `b`, in the same
> > loop, on the same borrowed item, and ships.
>
> ### The one variable left standing is **DEPTH**, and it is measured
>
> **`convRow` captures `app` in five closures in a loop and works.** Its four call sites —
> `gui.nim:4783`, `:4790`, `:4797`, `:4813` — **are all directly inside `method view` (`:4647`):
> depth 1.** **`mdBlock` is depth 3:** `view` → `mainArea` (`:4840`) → `messageBody` (`:3506`) →
> `mdBlock` (`:2943`). *Verified here.* **A second `mdBlock` call site exists in the note-editor path
> (`:3418`) at a different depth — an untouched data point for whoever runs the experiment.**
>
> ### **DEPTH IS DEAD TOO — structurally, and this closes the thread to the limit of reading**
>
> **`widgetutils.nim:91-92`, verified here:**
> ```nim
> updater.assignApp(state.app)
> let newChild = if child.isNil: updater.build() else: updater.update(child)
> ```
> **`assignApp` then `build`, adjacent, unconditional, with no branch between them**, and the
> multi-child helpers open the same way. **The containers recurse one level at a time and there is no
> depth-sensitive branch anywhere in the path.** So `genAssignAppEvents` not descending into children
> is real **and irrelevant — it was never meant to.** *Depth was the last surviving theory and it is
> dead by construction, not by measurement.*
>
> ### **A RIGHT ANSWER ARRIVED WITH A WRONG PROOF FIRST. Only the sound proof is recorded — and the distinction is the day's most expensive lesson.**
>
> **The unsound argument, WITHDRAWN by its author:** that `linkCallback` calls `data[].redraw()`,
> that `redraw` raises on a nil `app`, and that since the `discard uri` build was measured safe,
> `event.app` must therefore have been non-nil. **`redraw` never ran in any of those builds.** The
> crash is at **build**; `--check` is build-and-exit — verified at `gui.nim:5197-5201`, it calls
> `setupApp`, prints *"GTK initialised, window tree built, no window shown"* and returns. **No window,
> no click, no signal emitted, so the callback never executes and the nil-guard never fires.** The
> safe/fatal split says **nothing whatever** about `event.app`. The companion "you would have seen
> owlkettle's `ValueError`" argument fails identically — that message lives inside `redraw`, on the
> activation path.
>
> **The sound argument, which is what the record carries:** **a nil `EventObj.app` is inert at build
> time** — a nil field in an object nothing dereferences until a handler fires — **so it cannot
> produce a segfault during `view` → `build` at all.**
>
> > **A right conclusion reached by wrong reasoning is not evidence, and a later session leaning on it
> > would be leaning on nothing.** *This is the cleanest instance of what has cost the most today:
> > **a wrong proof of a right answer**. It was catchable only because the reasoning was published
> > with the claim — "the depth theory is dead", written without its argument, would have stood.*
>
> ### What remains established, and it is generator emission — not activation
>
> - **Connect is emitted by TWO generators, disconnect by ONE.** `HookConnectEvents` at
>   `widgetdef.nim:442` (`genBuildState`) **and** `:528` (`genUpdateState`); `HookDisconnectEvents` at
>   `:496` (`genUpdateState`) **alone**. **Zero `=destroy`, `HookDestroy` or `proc destroy` in the
>   file** — verified, count is 0.
> - **Within `genUpdateState`, disconnect precedes reconnect, so an update is correctly paired.**
>   **The hole is exactly build-then-discard-WITHOUT-an-intervening-update** — *which a per-block,
>   per-frame tree produces and a fixed sidebar does not.* **That narrower form is the one to carry.**
> - `connect` hands GTK a **raw pointer into a ref object's payload**, held for the life of the
>   connection.
> - **Residue: exactly ONE variable — what the closure captures.** **Nobody is naming a mechanism,
>   and five theories died today by naming one.**
>
> **Whoever picks A-48 up should start from a documented hazard rather than from four builds.**
>
> ### Three units are BLOCKED on it, and that is the correct state
>
> **ONLY FINDING 5 IS BLOCKED. Finding 7 and 13c-2 are UNBLOCKED — correcting an earlier over-reach.**
>
> Three units were held. **That was too many.** **Finding 5** stays blocked: its closure captures
> `app`, per message, in a loop, at `mdBlock`'s depth — **unmeasured in exactly that configuration.**
> **Finding 7** (a settings-panel button) and **13c-2** (an expander) are **neither inside `mdBlock`
> nor per-block**, and *the only established boundary is "a closure capturing `app` in `mdBlock`".*
> **Generalising past the measurement is what killed five theories today**, and blocking two units on
> a boundary nobody has drawn is the same error wearing a cautious face.
>
> ### **FINDING 5 IS AN EXPERIMENT, NOT A QUEUED UNIT — reclassified, correcting an earlier call**
>
> **It was filed as "probably safe" because it is a `Button`, and `Button` works in that position.
> That reasoning was wrong.** *The safe `Button` there captures `b`; Finding 5's would capture `app`*
> — `proc clicked() = app.forkConversationRow(m.id)`, **per message, in a loop, at `mdBlock`'s
> depth. That is the crashing shape on every axis measured.**
>
> **So: add the closure, run `bin/jenova --check` immediately — before anything else and before any
> other change.** *What it must not be is built as routine work by someone who thinks it is a small
> icon.*
>
> ### **PRE-REGISTER BOTH READINGS BEFORE THE PROBE RUNS. This is a condition, not a note.**
>
> **A free probe exists: `mdBlock` has two call sites** — `gui.nim:2943` via `messageBody` and
> `:3418` via `mainArea` — **one compiled closure at two runtime depths, needing no new widget.**
>
> **But depth is now dead by construction, so a split result MUST NOT be read as "depth".** The two
> paths also differ in **`b`'s provenance**: the transcript's blocks are a table-owned value copied
> out of the memo under ARC (**A-6**). **Both readings are to be written down before the probe runs,
> not chosen after it.** *That is the discipline that would have saved five theories today.*
>
> ### The process note, now a pattern rather than an incident
>
> **Every theory offered on this crash has been refuted — by someone building a control or reading a
> type — and each refutation left the question sharper than the theory did.** The markup timeline
> fell to a bisect; the user/built-in split fell to reading `EventObj` and **forced the question onto
> depth**; the depth objection is **what turned Finding 5 from a small icon into an experiment.**
> **The refutations were the progress, not the delays** — and in every case the refuter was
> correcting their own work.
>
> ### Two process failures this cost, both worth a line
>
> **1. A SOURCE FIX IS NOT EVIDENCE THAT A CRASH IS GONE.** Reading the source and comparing mtimes
> establishes that the *diagnosed* mechanism was addressed — **not that it was the only one, nor that
> the fix worked.** Only running it establishes that. **And the structural problem underneath: the
> sessions that can read are the ones not permitted to run.** The crash was twice declared stale by
> reading, and twice disproved by a rebuild and a core-count delta.
>
> **2. A CORRECT CAVEAT UNDER A WRONG HEADLINE IS READ AS THE HEADLINE.** The stale-crash report
> carried an explicit, accurate disclaimer that it did **not** establish the binary was green — under
> a headline saying the crash was already fixed. **The disclaimer was true and nobody acted on it.**
> *Belongs beside rule 9.*

> ### THE VERIFICATION GATE — three criteria, not one. **This is the remedy, and it is the most important thing on this page.**
>
> **"Verify each build against its plan" is what produced fourteen mechanisms and no features, and
> the reason is worth stating precisely: every one of those builds DID match its plan.** A-18-1 was
> a tri-state, asserted fourteen ways, exactly as scoped — **and nothing read it.** A plan-conformance
> check cannot catch that, because the plan was conformed to.
>
> | | Criterion | Failing it means |
> |---|---|---|
> | **(a)** | Does it match its plan? | Not done |
> | **(b)** | **Does something read ALL of what it produces** — a caller that is not a self-test? | **NOT DONE.** This is the one that was missing |
> | **(c)** | **Has a human SEEN it work?** | **UNSEEN** — a legitimate state, but it must be recorded in that word |
>
> **A unit failing (b) is not done, however green.** A unit passing (b) and failing (c) is **UNSEEN**
> and **must never be written as "built"**. *`PROGRESS.md` says which, for every unit.*
>
> **(b) has a one-command form** — rule 18b: **grep for a caller that is not a self-test.** It has
> now found six, including one this project manufactured on the day it was quoting the rule at
> itself.
>
> **"ALL of what it produces" is the amendment, and the fork is the proving case.**
> `api.forkConversation`'s join exists and three of its returned fields are consumed — **but the
> `atMessageId` it honours is passed empty by its only caller.** **A partial join passes a binary
> gate, and a partial join is precisely the shape this project keeps producing.** *Second
> criterion-level correction of the day, both from the same session, both against work it had
> signed off.*
>
> ### Standing consequence
>
> **"Built" requires a screen run for anything with a visible surface.** An assertion-green,
> `--check`-green unit touching `gui.nim` is **IMPLEMENTED, UNSEEN** — never "built".
> **This is the one rule today produced that cost something to learn.**

---

## 0a. FIVE SESSIONS ARE LIVE IN THIS REPOSITORY. READ THIS BEFORE OPENING A FILE IN `src/`.

> ### Git, and completion — the USER's standing rules, 2026-09-03 12:00
>
> **1. The USER performs every git write action.** No session commits, branches, stages, stashes,
> resets or pushes. **Read-only git is not only permitted, it is how a claim gets checked** —
> `git log`, `git status`, `git show`, `git diff`. This session used exactly those to catch a branch
> header that had been a commit stale for three sessions.
>
> **2. A commit is a checkpoint, never a finish line.** **Commits happen only once every session has
> verified its own work complete**, so anything swept into a commit that is not yet asserted is
> still open work. **`b830bfca` "Agents Review" is such a checkpoint:** it contains A-48's code,
> which has no assertions, alongside units that are complete.
>
> **3. A USER ruling relayed through a peer is not an approval anyone can act on** (**D-CO**).
> Five sessions, five terminals — or one person five times, and no session can tell which. **"My
> USER, in my terminal, ruled X — for your USER's consideration"** is the only accurate form; *"the
> USER approved X"* reads as one authority speaking to all five and **is exactly what Directive 1
> gates.** A defect fix against an existing `[V]` finding sits inside the existing gate; **new
> product behaviour needs the builder's own USER, in the builder's own terminal.**
>
> **Do not let a commit be mistaken for completion.** *Code in the tree is not the same as proven,
> and that distinction is this project's entire history* — the sentence is a coding peer's, given
> unprompted about its own unfinished work, and it belongs here. **G-44/Step 10b sat in
> `PROGRESS.md` as built for a day and had never once worked** (A-69). That is what a commit-as-
> completion looks like a week later.

**This is not a hypothetical and it is not history — it is the state of the tree as this line is
written.** On 2026-09-03 the USER had **four Claude sessions open on this checkout at once**, and
at least three were given the same opening instruction. Each asked the USER for the phase in its
own terminal. **Each got a different answer, and each began writing it into these shared files.**
The tree went from clean to six modified trackers and two modified source files in about fifteen
minutes, and no single document knew it.

**What that produced, recorded because it is the failure mode, not the anecdote:**

- A `SESSION_HANDOFF.md` entry stating *"No product code was touched"* and *"Files touched: … No
  source file"* — accurate for its own session, **false about the tree**, which already carried
  another session's `gui.nim` change. Two sessions each correctly denied the edit; a third owned it.
- Two orderings of the remaining work, both recorded as the USER's ruling, in two files:
  **`DECISIONS_LOG.md` D-CI** (the defects 12e-1 → 12f-1 → 12e-2 → 12f-2 → 12d, ahead of 13c) and a
  separate instruction to build **Step 12c (A-3, A-4)**, which D-CI does not mention at all.
- A binary-freshness claim in this very file that was true when written and false eleven minutes
  later.

**The standing rule that comes out of it:**

> **Before editing anything in `src/`, run `git status` and `ListAgents`.** A clean tree in a
> tracker is a claim about the past. If another session holds the file, message it — do not diff
> around it and do not assume the change you are looking at is yours.
>
> **One session owns `.devdocs/` at a time.** As of 11:45 that is this session, by the USER's
> instruction; the others write code and report completed units to it. **Trackers written by four
> hands concurrently are worth less than no trackers**, because they read as one coherent voice
> while contradicting each other two screens apart.

### In-flight register — 2026-09-03 11:45. **Uncommitted work by other sessions.**

**Attribution took three corrections to settle, and how it settled is the useful part.** Two
sessions denied the 12c work; mtimes and the `gui.nim` diff together pointed at one of them; **the
actual author was a fifth session nobody had counted**, which identified itself unprompted. **A-5
in particular was declared an orphan by two sessions** before its author claimed it. **Nothing here
was recorded until its author claimed it or this session read it out of the tree** — a peer
explicitly asked not to be recorded on inference, and it was right to.

### Roster — who is who, 2026-09-03 11:57

**Recorded because it took an hour and three wrong attributions to establish, and because
`ListAgents` shows a session its peers but never itself** — each session's own name is the one
missing from the four it can see.

| Name / role | Writes | Work |
|---|---|---|
| **DEVDOCS MAINTAINER** — `jenova-26 [25ad4a]` | `.devdocs/` **only**, and nothing else, ever | Sole writer of these trackers. **Holds and brokers the `src/jenova_core.nim` token.** **Verifies every reported unit by running the binaries before recording it** |
| **PLANNER** — `jenova-d3 [1f330e]` | Nothing | Forward plans, handed to the maintainer. Wrote Step 12d and 13c's counting rule. No product code, no `.devdocs/` |
| **CODING PEER 1** — `jenova-b6 [48da9d]` | `markdown.nim`, `gui.nim` note path | **A-26**, **A-17**, **A-48** built. **12d** next, held for the plan |
| **CODING PEER 2** — `jenova-e4 [e69945]` | `fssync.nim`, `api.nim` | **A-69**, **A-16**, **A-20**, **A-24** built. **A-18** next |
| **EXAMINER PEER** — `jenova-d0 [e0618c]`, *also the 12c author* | Nothing now; released `pipeline.nim`, `http.nim`, `server.nim` | Wrote **Step 12c** (A-3, A-4, A-5) and **never compiled a line of it** — instructed not to build, and it was verified green by two other sessions. Now parity examination: six findings, including **A-70** |

**How the names were resolved, because it took an hour:** `ListAgents` shows a session its peers
and never itself, **so each session's own name is the one missing from the four it can see.** Three
independent listings settled all five. **One session's recollection of its own name was wrong** and
three clean eliminations beat it.

*(The roster carried these last two as separate sessions for a while. They are one. That is the
fourth attribution error in an hour, and every one of them ran the same way: a session was inferred
from a file rather than asked.)*

**Address a session by role, not by socket and not by "the other session".** Three of the five
could not name themselves, two disclaimed the same change, and one was not counted at all until it
spoke up.

**Agreed division, by FILE rather than by work unit — because files collide and tasks do not:**

| Files | Holder | Work |
|---|---|---|
| `pipeline.nim`, `http.nim`, `server.nim` | 12c author | **Step 12c — A-3, A-4, A-5. BUILT** (`PROGRESS.md`). Then **12d** (A-7), since it already holds both files that needs |
| `markdown.nim`, `gui.nim` | A-26 author | **12e-1 (A-26) — BUILT.** Then **12e-2 (A-48)**, the same file. **`gui.nim` goes whole to one holder** — it carries A-26, A-5 and A-69 together, and splitting one file across two writers is the collision being avoided |
| `fssync.nim`, `api.nim` | third peer | **12f — A-17** written and compiling, **assertions outstanding, so not a completed unit.** Then **A-16/A-18**. Needs a small `gui.nim` surface for A-18 and negotiates it with that file's holder first |
| `.devdocs/` | this session | The trackers, and this register |

**That parallelises D-CI instead of serialising it, and no two sessions hold a file.**

### `src/jenova_core.nim` is a TOKEN, not an etiquette

**All the assertion work lands in that one file** — `pipeline-`, `error-` and `attach-selftest` for
12c, `markdown-selftest` for A-26, `fs-selftest` for A-17. **A clobber there is invisible until a
build breaks or an assertion silently disappears**, which is the exact class of failure these
trackers exist to catch and the reason Session 023 found a green suite over dead code.

> **The `.devdocs/` session holds the token and passes it on.** Ask, write, build, report green,
> and it moves to the next in queue. **Hold it while you type, not while you think.** A holder that
> goes quiet has it reclaimed, and the reclaim is recorded here.
>
> **`gui.nim` is a second token** — it is the biggest file in the tree and four units wanted it at
> once (12d-3, A-70, A-18's trash view, A-71's reset button).
>
> ### **The one rule that overrides the token: whoever breaks the build owns the repair, immediately, token or no token.**
>
> **Established 2026-09-03 12:12 by a session that broke the tree and said so unprompted.**
> A-18-1 changed `fssync.restoreMirror` from a `bool` to a tri-state and instantly invalidated its
> author's own nine assertions, so `nimble core` was **red from ~12:09 to 12:12**. It took
> `jenova_core.nim` without the token to repair a break it had caused, **and that was the right
> call**: a red tree blocks every session at once and a queue in front of the fix makes it worse.
> **Announce it, fix it, say when it is green.** The disclosure is what makes this safe — a session
> that built in that window needs to know its failure was not its own.

**Nothing enters `PROGRESS.md` as built until a green `nimble core`, `nimble gui` and `bin/jenova
--check` has been established against the tree as it then stands.** A build proof taken before
`jenova_core.nim` changed underneath it is not a proof of the tree after — a peer volunteered
exactly that about its own green run, and it is now the rule. **In practice every unit here was
verified by a session other than the one that wrote it, and 12c's author never compiled its own
work at all**, having been told not to build. **That separation turned out to be worth more than
the process that produced it by accident.**

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
> gathering for work the USER asked for.**

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run** — and **never deny what plainly was run.** Both halves are the rule. If it was not executed, say "I don't know". If the USER says they ran it, they ran it. |
| **2** | **This is a Nim program using `llama-server`. That is all it is.** No shell scripts, no Lua, no C, no Makefile. Build with `nimble`. |
| **3** | **The archived old build is not work.** A broken reference to an archived file is fixed by **deleting the reference or porting it to Nim** — never by repairing it, and never by asking the USER which (**D-AZ**). |
| **3b** | **Everything is driven from the GUI** (**D-BC**). Anything needing a terminal, a shell script or a hand-edited file is a defect. |
| **4** | **Explain in plain English, then cite the ID.** "G-23 needs resolving" communicates nothing. Say what it is, then give the reference (**D-BA**). |
| **5** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Check the stdlib and the codebase first — including whether the API route you are about to write is already implemented and tested. |
| **6** | **Do not rebuild old patterns.** The two-command split was rebuilt after the USER killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **7** | **Comments only where the code is not self-explanatory.** No essays above functions. Do not retroactively "improve" existing comments. |
| **8** | **Do not ask what has been answered.** `DECISIONS_LOG.md` SETTLED FACTS and its QUESTION STATUS index, first. |
| **9** | **Do not write derivable facts into these documents.** Counts and file lists rot. Point at the code. *Session 023 found the self-test count wrong again — two files said thirteen, the dispatch carries fourteen.* |
| **10** | **Re-check a tracker's claims against the code; do not carry them forward.** Session 013 found seven false claims. Session 015 found thirteen rotted citations. **Session 023 checked 388 claims across all ten trackers and 176 of them — 45% — did not hold as written.** |
| **11** | **Verify a scope list against the source, not against a summary.** The "GUI parity" list carried since Session 010 named six items. **The real inventory is 1,095 Web UI features, enumerated 2026-09-03 and recorded as `TODOS.md` A-59.** Check scope claims against that. |
| **12** | **A "not yet run" label is not durable.** It survives exactly until any evidence contradicts it — a screenshot, a defect report, or the USER saying so. |
| **13** | **A new assertion is not believed until it has been shown to discriminate — and you prove that by varying the DATA, never by breaking the code (D-BX).** Give the function inputs that must produce different answers and assert both sides; assert a *transition* rather than a state. |
| **14** | **Cite the symbol, then the line.** A bare line number is a claim with an expiry date. `fssync.resolveStoragePath (fssync.nim:694)` survives a refactor; `fssync.nim:628` does not. *Session 023 watched an agent cite `nvimctl.alive` at `:350` in a 196-line file — inside the audit that was hunting for exactly this.* |
| **15** | **A green suite says the parts work, never that anything calls them.** `rag.nim` was fully asserted and completely dead for weeks. When a feature is finished, assert the *join*, not only the parts. |
| **16** | **NEVER edit the product code to break it, for any reason (D-BX).** Not to prove an assertion bites, not with a copy to restore from. If a test passes on data that should fail it, the hole is in the assertion set; write the missing assertion and re-run it **against data**, never against a damaged file. |
| **23** | **GROUP BY WHAT THE USER EXPERIENCES, THEN CHECK THAT ONE FIX ADDRESSES ALL MEMBERS.** **A group that survives the first test and fails the second is an ORDERING, not a unit.** *Recorded because it was tested rather than asserted:* of four proposed groupings, **two survived rescoped and two dissolved**; of one proposed earlier the same day, **none survived**. **The difference was the method — the survivors were grouped by observed shared consequence, the failures by a shape someone had named**, and the session that had named the shape said so about itself, unprompted, in the message correcting someone else. That test turned "observability" from a three-file bundle into **one logger plus a dependency note**, and stopped "unbounded blocking on the GTK thread" from sending a builder to fix five things that do not block the GTK thread. |
| **22** | **A COUNT GIVEN WITHOUT ITS METHOD IS UNFALSIFIABLE — and every wrong count this project has carried was of that kind.** The self-test number was written nine ways. A-57's discard count was published as 58, corrected to 32, and **counted here as 30 with two other syntactic forms beside it**. *The correction to the count was itself wrong.* **What made it checkable in one command was that its author published the grep** — which turned out to be an OR of `except CatchableError: discard` **and** `except CatchableError:$`, so it measured *"a handler exists"* and reported *"a failure is discarded"*. **Publish the method or write a word instead of a number.** |
| **21** | **A COMMENT STATING A PRECONDITION IS A CLAIM WITH AN EXPIRY DATE, AND NOTHING IN THIS PROJECT RE-CHECKS THEM.** **The sharpest instance found 2026-09-03:** `fssync.nim:564-566` said the lexical containment check was *"tolerable while `restoreTrash`'s only caller was the HTTP route"* — **the code wrote its own precondition down, A-16 shipped that morning and became a second caller, and the comment became false in the tree.** *A reader would have been reassured by a sentence that had stopped being true.* **This is G-38's class and there are now three instances in three files** — G-38's `Paned` that was never used, `gui.nim:4650-4652` explaining that the strip shows name/type/size *because* a thumbnail would cost a decode **with a thumbnail rendering eleven lines below it**, and this one. **Unlike the "unreachable capability" habit, which was retracted, this one is worth forecasting.** When a comment says *"safe because X"*, X is a thing to verify, not to trust. |
| **20** | **A SEARCH THAT RETURNS NOTHING IS NOT EVIDENCE UNTIL YOU HAVE CONFIRMED THE SEARCH COULD HAVE FOUND SOMETHING.** **Two instances in one session, both nearly recorded as findings.** *(a)* `grep -rn "db/cache" jca_web` returned zero and was offered as proof the Web UI never calls that route — **but `apiFetch` builds the URL as `` `/api/db/${path}` ``, so the string cannot appear at a call site.** The route *is* there, at `database.service.ts:598`/`:609`. *(b)* `grep 'StyleClass("msg-system")'` returned zero and nearly had two live style classes reported as unapplied — **they are written inside a `case` expression as bare strings.** **The fix is a control: run the same search for something you know exists.** A-63's seven dead config keys were established that way — six other keys were run through the identical search and each returned one consumer — **and that is what makes its negative result a finding rather than a failed grep.** |
| **19** | **NEVER READ AN EXIT CODE THROUGH A PIPE.** `nimble gui 2>&1 \| tail -1; echo $?` reports **`tail`'s** status, which is **always 0**. So does `nimble core \| tail && nimble gui \| tail`. **A session using that idiom reports a green build it has not checked, and then `--check` runs the stale binary and agrees** — *two green lines, neither of them evidence.* Use `${PIPESTATUS[0]}`, or redirect to a file and test `$?` directly. **Reported 2026-09-03 by a session against itself**, which is how it was caught; **the `.devdocs` session had the same defect in its own verification commands and re-ran them clean.** Every build claim made with the broken idiom is unverified regardless of who made it — **and this project's history is full of green results that asserted nothing, which is exactly the shape of this one.** |
| **18b** | **When a capability lands, grep for a caller that is not a self-test.** *One command, and it has now found five.* **Rule 15 says a green suite proves the parts and never the join — this is the procedure it was missing**, and without one the rule was violated systematically. The class: a capability complete and asserted below the widget layer that **the window cannot reach**. Known instances — 13b's fork column (`forkedFromConversationId`, in the schema from the start, nothing could create one); `pipeline.cacheStore`, whose only caller was `pipeline-selftest`; `pipeline.ChatError.detail`, populated at both call sites and read at neither; `api.forkConversation`'s `atMessageId`, honoured with every caller passing `""`; and `workspace`/`rag`'s earlier cases. > **THE PREDICTION IS RETRACTED; THE PROCEDURE STAYS.** This was recorded as a pattern these files
> exhibit. **It is not one.** It is **four instances found at the parity boundary** — and the
> evidence against generalising is now three-fold: one seven-row sweep cluster contained **zero**
> members, **A-45 was an outright counter-example** (a threadvar initialised on the wrong threads,
> not a join the window cannot reach), and a nine-row batch produced **none**. **The one-command
> check remains worth running as a cheap habit. It is not a forecast.** *Retraction requested by the
> session that produced the generalisation, against its own work, and endorsed by the session that
> co-signed it — which is the behaviour that makes these verdicts usable.*

**A sixth variant exists and is rare: present in the frozen source and never invoked** — `DatabaseService.setCache`/`getCache` is the **sole known instance**, hunted for and not found again in `attachments`. **Named so nobody goes looking for a pattern that is not there.** |
| **17** | **A compile is not evidence the application starts.** **Run `bin/jenova --check` before handing over any GUI change** — it builds the whole window under a real GTK and exits, showing no window and binding no port. **And know its limit: it builds each branch once**, so it proves the window reaches its first frame and never that it survives a *state transition*. It exited 0 on the build that aborted the moment a note was opened (G-51). **AMENDED 2026-09-03 12:20 — and this is the half the rule was missing. `bin/jenova --check` RUNS THE BINARY THAT IS THERE. If the build failed, that is the PREVIOUS binary, and `--check` will cheerfully exit 0 on it.** A session caught this the honest way: `nimble gui` exited **1** and `--check` exited **0** in the same run. **A session can follow this rule faithfully, in good faith, and be reading a stale result.** So the check is not "run `--check`" — it is **"the build exited 0, and *then* `--check` exited 0", in that order, or it proves nothing.** Never report `--check` green without the build's exit status beside it. |
| **18** | **REPLACED 2026-09-03 09:02 — the suites now mean something, and test work is now LAST.** This rule said a green build proved nothing because `nimble suites` ran no self-tests and four of six passed when they could not run. **A-1 and A-2 are built** — every self-test runs and a suite that cannot run fails. **The rule that replaces it is the USER's instruction of 09:05 (`TODOS.md` A-68): test and check work is left until last.** A red suite met while doing feature work is not a work item — record nothing, say nothing, carry on, exactly as Rule 0 already directs. Do not open a session with test bookkeeping. |

---

## 1. What this is

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does the inference; this is everything around it |
| **Binaries** | `bin/jenova` — the desktop app. `bin/jenova-core` — the same program headless, for LAN. They link the same **non-GUI** modules; the split exists so a server host builds without GTK |
| **Build** | `nimble`. Tasks in `jenova_core.nimble`: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| **Architecture** | `BLUEPRINT.md` |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | `nimble suites` runs the **self-test subcommands** (from the `SelfTests` const in `jenova_core.nimble` — **read the names out of `src/jenova_core.nim`, never from a number written here**) and then the six shell suites under `tests/`. A failing assertion fails the run, and a suite that cannot run fails rather than skipping — **with one sanctioned exception: `test_nvimctl.sh` still skips when `nvim` is absent**, the USER's overrule, because `nvim` is not a build dependency of either binary. **Nothing tests the GUI — see §6.** |

## 2. State

**Verified 2026-09-03 by reading the source.** Both binaries build; the last recorded run of
every self-test and `bin/jenova --check` passed on 2026-09-02 12:19 and **nothing has changed the
code since**, so that record stands. Both binaries are ELF 64-bit FreeBSD executables.

**The backend is implemented and mostly covered.** The database, the threaded HTTP server, the
`/api/*` surface, the filesystem mirror, retrieval **and its feed**, the prompt pipeline, and model
discovery and switching all have assertions behind them. **Two named parts do not:** `config.load`
and its precedence chain have no self-test and no suite, and the watchdog's decision function
`lifecycle.watchOnce` — whose own docstring says it was separated from the loop *so it could be
tested* — is asserted nowhere.

**And the coverage those assertions represent is not what it looks like.** See §6 — it is the most
important thing on this page.

**The desktop application has the shape of the Web UI and a large part of its function**, plus a
substantial set of capabilities the Web UI never had. What it is missing is now enumerated properly
for the first time: **1,095 Web UI features** were catalogued on 2026-09-03 (`TODOS.md` A-59)
against the six-item scope list that had been carried since Session 010.

## 3. What happened in Session 023

**A three-part audit, commissioned by the USER. No code was changed and nothing was run.**

1. **Web UI ↔ GUI parity.** 1,095 features enumerated from `jca_web/src`; 866 parity verdicts
   produced across eight of nine areas. *(`data-services` was not reached then; it was read
   first-hand 2026-09-03 09:48 and resolves to three gaps — §4.)* 31 GUI capabilities beyond the
   Web UI catalogued.
2. **Every `.devdocs/` claim against the source.** 388 claims checked across all ten trackers.
   **212 TRUE, 87 STALE, 53 MISLEADING, 35 FALSE.** Corrected in this pass.
3. **Mechanism analysis.** Seven subsystems read end to end — GUI wiring and threading, memory,
   GPU and rendering, the data layer, retrieval and the pipeline, lifecycle and backends, and the
   structure of `gui.nim`. **64 findings, none refuted**, plus five coverage gaps the audit found
   in itself.

**Full narrative: `SESSION_HANDOFF.md`. The findings: `TODOS.md` A-series. The work: `PLANS.md`
Step 12.**

**Read `[V]` / `[A]` on every A-row before acting on it** (**D-CG**). Roughly a third were
confirmed first-hand this session; the rest are agent findings that survived a refutation attempt
and nothing more.

**`TODOS.md` A-67 is a traceability index** mapping each of the 64 sweep findings to its A-row, so
this file's coverage can be checked mechanically instead of trusted. It exists because **the first
pass dropped five findings** — recovered as A-61 … A-65 — and mis-stated A-52's severity. All 64
now resolve.

## 4. What is actually missing

**This section no longer carries a feature table.** It carried one for six sessions, it was
corrected three times — for PDF, for audio, for the trash view, and finally for the note editor —
and it was wrong again each time within a day. **That is rule 9, and the fix is to stop
re-deriving it here.**

**The list is `TODOS.md`.** The ordered plan is `PLANS.md`. The parity inventory is `TODOS.md`
A-59, and it supersedes every scope list this project has written.

> ### THE CURRENT WORK IS THE VERIFIED DEFECTS — `PLANS.md` **Step 12c…12f**. The parity backlog is next, not now.
>
> **Changed 2026-09-03 11:40 and this line has moved twice today, so read the dates.** The parity
> backlog (`TODOS.md` **A-59**, `PLANS.md` **Step 13**) was chosen by the USER at 09:10 and was the
> current work until **D-CI**, at which point the USER chose the defects instead. **A-59 is not
> cancelled and is explicitly next** — D-CI says so in its own text.
>
> **Two orderings are live, both given by the USER, in two different terminals** (§0a):
>
> - **D-CI** — `12e-1` (A-26, the note memo) → `12f-1` (A-17, the storage trash root) → `12e-2`
>   (A-48, markdown links) → `12f-2` (A-16/A-18, trash restore and a window surface) → `12d` (A-7,
>   the response cache), **12d last because it is the only one that touches `upstream.forward`'s
>   verbatim relay** and D-CD warns that wiring the writer without fixing the hit response makes
>   cached turns render blank.
> - **Step 12c** — A-3 and A-4, the two data-losing defects in the chat path. **In flight now**
>   (§0a) and **absent from D-CI's list**, which is a gap in the ordering rather than a decision
>   against it.
>
> **13a and 13b are BUILT (2026-09-03 10:21, `PROGRESS.md`).** The composer is a `DraftView`, so
> the six chat-form gaps behind the one-line `Entry` are closed together; and `data-services` is
> closed: markdown conversation export/import, forking a conversation, and the mirror's `pull` half,
> so an edit made in the embedded Neovim now comes back into the database.
>
> ### **13c cannot be picked up as written. Its work list does not exist.**
>
> **Verified 2026-09-03 by search, and this is the single most useful thing on this page for
> whoever takes 13c.** `TODOS.md` A-59 says the 866 per-feature verdicts are "in the session
> record". **They are in no record.** The strings `views-dialogs`, `models-server` and
> `sidebar-workspace` occur **nine times in the whole of `.devdocs/`**, every one inside A-59's own
> nine-row summary table or the sentence telling you to start with them. Session 023's verdicts
> were produced by agents, counted, and never written down.
>
> **So 13c's first unit is re-deriving one area's inventory from `jca_web/src` directly** — not
> looking a list up, not verifying rows that exist. Budget for that before scoping anything, and do
> the largest three by count (`views-dialogs` 65, `models-server` 61, `sidebar-workspace` 47)
> **for root causes**: both 13a and 13b collapsed to one cause behind a column of rows, and that is
> the shape to expect.

**The shape of it, which does not rot:** the backend is largely finished and the outstanding work
is mostly in the window.

## 5. Known broken

**A-1 and A-2 were the two that outranked every feature gap. Both were built 2026-09-03 09:02**
(`PROGRESS.md`); `nimble suites` runs every self-test and a suite that cannot run fails,
**except `test_nvimctl.sh`, which the USER ruled must keep skipping on a missing `nvim`.**
**T-12 went with them.** That pass also found `test_models.sh` asserting **pre-D-CB** behaviour —
red since 2026-09-02 10:43, invisible because Rule 0 stopped anyone running the suites. The
product was correct; the assertion was stale, and it is corrected.

**All remaining test and check work is deferred to last** — the USER's instruction, `TODOS.md`
**A-68**. The live work is `PLANS.md` Step 12c onward, below.

**A-69 is FIXED — 2026-09-03 11:38 (`PROGRESS.md`), and it is gone from `TODOS.md`.** Attaching a
file had never once been filed as a workspace artefact: `gui.fileAttachmentsAsArtefacts` minted the
`fileAssets` id with `$genOid()`, `fssync.physicalPath` refuses any id that is not a UUID, and
`api.upsert`'s mirror-failure branch deleted the row it had just written — so the user saw "could
not file … in the workspace" on every attachment and **G-44 / Step 10b had never worked, while
`PROGRESS.md` recorded it as built.** One call, `fssync.newUuid()`. **Unobserved: that the row now
survives is a USER screen run** — `gui.nim` links into no test binary and `--check` routes no
events, which is exactly how this shipped in the first place.

**Four of the high-severity defects were built on 2026-09-03 at 11:51 and are gone from
`TODOS.md`** (`PROGRESS.md`, Step 12c and Step 12e-1):

- **A-3** — attaching an image no longer drops the earlier conversation. `trimHistory` measures
  through `pipeline.messageWeight`, which charges an image part a flat `ImageContextBytes` rather
  than its base64 length.
- **A-4** — `MaxAttachmentBytes` is now *derived* from `http.MaxBodyBytes`, so the two caps cannot
  cross, and an oversized body is a **typed 413** drained before it is raised, classified
  `cekBadRequest` and not retryable.
- **A-5** — the context-used figure is `cacheN + promptN + predictedN`.
- **A-26** — the note memo has explicit O(1) invalidation at the two points the editor re-baselines.

**Still open and high severity:**

- **A-6 — the G-40 memos may still copy per frame.** `[A]`, and it needs a second read before it
  is believed. **It is the last of the original high-severity four.**

**Built since, and gone from `TODOS.md`** (`PROGRESS.md`, 11:55–12:02): **A-17** (storage deletions
were invisible and unclearable), **A-16** (restore put back the row and never the file), **A-20**
(cascading soft-deletes now transactional — **recorded as unasserted on purpose**, because
atomicity cannot be asserted without damaging code, D-BX), **A-24** (the trash lists newest-first as
its docstring always claimed), and **A-48** (markdown links and images, behind an http/https
allowlist, 24 assertions).

**Still open and user-visible:** Copy is Wayland-only and swallows its failure (**A-27**); the
documented `CANVAS=0` off-switch for the only continuous GPU load cannot be triggered by any means
(**A-25**); **A-18** — the whole `/api/fs/trash/*` surface is reachable only over HTTP and the
window offers none of it, **upgraded `[A]` → `[V]` 2026-09-03** and now the only open half of 12f.

**New, and it is a defect this project introduced rather than inherited — `TODOS.md` A-70:**
**exporting a conversation with a system turn and importing it back makes that turn display as the
model's own words.** `gui.Role` has no `rSystem` and `listMessages` maps everything not `"user"` to
`rAssistant`, while `convmd` round-trips `role: "system"` faithfully. **13b's own round trip is the
path that reaches it.**

**Still outstanding from before:** **G-47**, the editor page's Neovim truncated at the bottom on a
resize — **not diagnosed**, two candidates recorded, and not settleable without the running widget.
Two cosmetic Backlog items (G-37, G-38) and the G-51 widget constraint.

## 6. The coverage gap — now one gap, not two

**Half of this section is closed.** Every suite and every self-test exercises `jenova-core`, and
**`nimble suites` now executes every self-test** — read the list out of the `SelfTests` const in
`jenova_core.nimble`, never from a number written here — with a suite that cannot run reporting
failure. So "it is asserted in `X-selftest`" is a coverage claim again.

**What remains, and it is the durable half:**

- **`gui.nim` has no coverage of any kind.** Every GUI defect in this project's history was found
  by the USER looking at the screen. Nothing about 12a changes that — `gui.nim` links into no test
  binary.
- The behaviour deliberately pushed *below* the widget layer to be assertable —
  `workspace.contextFor`, `nvimctl.editorEnv`, `api.restoreEntity`, `pipeline.chatBody`, the whole
  of `settings.nim` — **is asserted, and those assertions now run.**

**The response is correct and should continue.** Moving behaviour below the widget layer is the
right design and it is why the audit could read this codebase at all.

**One thing not to mistake for coverage** (`TODOS.md` A-66): nobody has verified that a `check(...)`
inside the self-test bodies can actually *fail*. Roughly 900–1,100 lines were grep-sampled, never
read. Sound where sampled is not the same as proven to discriminate. **That is deferred with all
other test work under A-68** and is not to be picked up before the feature work is done.

## 7. Waiting on the USER

**Nothing is blocking. Q-37 is PARKED by the USER (2026-09-03 09:10) — do not re-raise it.**
It asked whether the desktop settings should govern a LAN request: `settings.applyTo` has one
caller, `pipeline.chatBody`, and the LAN path goes through `pipeline.prepare`, which takes no
`Settings`, so the sampling and penalty parameters apply only to bodies the window builds.
**Re-verified 2026-09-03 and it still holds.** It blocks nothing and is parked deliberately, not
forgotten. `TODOS.md` A-53.

**Four product decisions remain parked, none on the critical path:** Q-37 above, filesystem as the
source of truth (T-11), deployment (T-7), a CLI (T-8).

**Answered during this audit and not to be re-raised:** the `.devdocs/ARCHIVE/` deletion was the
USER's own and deliberate (**D-CE**); the response cache is a defect to fix rather than remove
(**D-CD**); `etc/jenova.local.conf` is the USER's in-use machine config and is out of scope
(**D-CF**).

## 8. Unobserved — awaiting a USER screen run

**A screen run is the USER's, when it suits them, and not something a session initiates or asks
after** (Rule 0). What remains unobserved rather than suspected:

0. **Step 13a's composer, after the 11:14 rebuild.** Three defects have been fixed across three
   runs — unclickable, a placeholder that never cleared, no autogrow — and **none of them was
   visible to any check this project can run.** What is unseen: clicking in, typing, Shift+Enter,
   wrapping, the growth and the 168px cap. The four new buttons — Fork on a conversation row, and
   the three in settings — are unseen with it. **`--check` cannot substitute for this:** it builds
   the tree and exits, allocating no sizes and routing no events, which is exactly how it passed a
   composer nobody could click, twice.

1. The note-header pin toggle and a FOCUS note written from the window turning up in a chat scoped
   to a different folder.
2. Session 015's recall against a **live** backend — everything was verified with the embedder
   down, so the semantic half of ranking on real embeddings is unproven.
3. Three settings behaviours needing a live generation: the transcript following a streaming reply,
   the code-block cap on a long answer, and the "Custom" badge which needs `/props` values.
4. A switched model actually loading into a restarted backend.
5. Four Adwaita icons that only appear on a branched or continuable turn — `view-refresh-symbolic`,
   `media-playback-start-symbolic`, `go-previous-symbolic`, `go-next-symbolic`.

## 9. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Language** | Nim only, plus `llama-server`. No shell, no Lua, no C, no Makefile in the product tree |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine. **The names are positional and nothing verifies the mapping** — see D-CE's note |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted (D-X). AGENTS.md Directive 2's "non-copyleft" clause is dead letter here and its operative clause — zero proprietary dependencies — is satisfied |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Retrieval** | Indexes chats (D-BD), fed per completed exchange (D-BI) |
| **Settings** | 1:1 with the Web UI's minus API Key, MCP and `serverUrl` (D-BL) — **re-verified 2026-09-03 against what the Web UI actually draws**, and the claim holds: 47 drawn keys, 41 implemented, the six absent being those three plus four MCP/agentic fields. `OmittedFields` names three of the seven and should name all seven (A-31) |
| **Unused files** | Remove from the product tree; **git history is the archive** (D-AM as amended by **D-CE**) |
| **MCP** | Deferred by the USER. Largest thing in the Web UI — do not pick it up casually |
| **Audio in/out** | Not needed, not gated, not to be raised again (D-BZ). The `input_audio` *send* path stays under Directive 3 |
| **Virtual file explorer** | Cancelled by the USER (D-AW). The Neovim page is the browser |
| **`jca_web`** | Frozen (D-Z). Read it to establish parity; never edit it |
| **`etc/jenova.local.conf`** | The USER's machine file, in use. Never edited, and its divergence from the shipped profile is not a finding (**D-CF**) |
