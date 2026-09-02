# BRIEFING

**Last updated:** 2026-09-02 11:35 (Session 022)
**Branch:** `bsd`. The tree was clean at `71ed41cb` when this session started; **this
session's changes to `api.nim`, `gui.nim`, `workspace.nim`, `jenova_core.nim` and the
`.devdocs/` are uncommitted.** **`jvim/` is tracked** (4,199 files in git of 4,201 on
disk), and `.gitignore` carries an explicit "TRACKED ON PURPOSE" block telling a session
not to add an ignore rule for it.

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
| **13** | **A new assertion is not believed until it has been shown to discriminate — and you prove that by varying the DATA, never by breaking the code (D-BX).** Two suites here have reported PASS while asserting nothing, so the concern is real; the method is not corruption. Give the function inputs that must produce different answers and assert both sides; assert a *transition* (recalled → deleted → not recalled → restored → recalled) rather than a state; create the hostile condition inside the test with `putEnv` or a fixture row. |
| **14** | **Cite the symbol, then the line.** A bare line number is a claim with an expiry date — thirteen of them rotted inside one session because `gui.nim` grew by 750 lines while they were being written. `fssync.resolveStoragePath (fssync.nim:694)` survives that; `fssync.nim:628` does not. |
| **15** | **A green suite says the parts work, never that anything calls them.** `rag.nim` was fully asserted and completely dead for weeks — every assertion supplied its own corpus, so nothing could tell. When a feature is finished, assert the *join*, not only the parts. |
| **17** | **A compile is not evidence the application starts.** `nimble gui` exiting 0 says the widget tree is valid; the Theme setting shipped a 100% SIGABRT behind a clean compile because `gui.run` asked libadwaita a question before `adw.brew` called `adw_init`. **Run `bin/jenova --check` before handing over any GUI change** — it builds the whole window under a real GTK and exits, showing no window, starting no backend and binding no port, so it is allowed where starting the product is not (D-BJ). **Nothing in `gui.run` may touch GTK, GDK or libadwaita before `brew`.** **And know its limit: `--check` builds each branch once, so it proves the window reaches its first frame and never that it survives a *state transition*.** It exited 0 on the build that aborted the moment a note was opened (G-51). |
| **16** | **NEVER edit the product code to break it, for any reason (D-BX).** Not to prove an assertion bites, not with a copy to restore from — a session did exactly that, the restore never ran because the USER interrupted the command holding it, and corrupted source sat in the tree behind a green build. **This rule previously said the opposite and that is how it happened.** The underlying concern stands — an assertion that cannot fail is worthless — and the answer is rule 13's: vary the inputs, assert both sides, assert transitions. If a test passes on data that should fail it, the hole is in the assertion set; write the missing assertion and re-run it **against data**, never against a damaged file. |

---

## 1. What this is

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does the inference; this is everything around it |
| **Binaries** | `bin/jenova` — the desktop app. `bin/jenova-core` — the same program headless, for LAN. Both link the same modules; the split exists so a server host builds without GTK |
| **Build** | `nimble`. Tasks in `jenova_core.nimble`: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| **Architecture** | `BLUEPRINT.md` |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | **Six** shell suites under `tests/`, run by `nimble suites`, plus the self-test subcommands in `jenova-core`. **Read the list out of `src/jenova_core.nim`, never out of this table** — the count was wrong in three files three different ways on 2026-09-01, and two more were added the same day. **None of them covers the GUI** — see §6 |

## 2. State

**Verified as of 2026-09-02 11:35.** Both binaries build from `nimble core` and
`nimble gui`; **every self-test passes, and `bin/jenova --check` exits 0 — the
application reaches its first frame**, which is a thing a compile does not tell you and
which was learned the hard way at 14:02 (rule 17). Both binaries are ELF 64-bit FreeBSD
executables. The six shell suites were **not** run and did not need to be — nothing this
session touched is inside their reach.

**One correction that had to be made by reading the code, not the trackers.** A session
corrupted `nvimctl.nim` to watch a self-test go red and the restore never ran, so broken
source sat in the tree **behind a fully green build** — every self-test passed, because
the corrupted branch was one the tests reached only through a collision that shell did
not have. It was found by reading the function. **The ruling is D-BX and rules 13 and 16
were rewritten**, because those rules had told the session to do it.

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

### Session 022 (part three) — 2026-09-02 11:35 — the 11:21 build crashed on a note; fixed

**Mine, and diagnosed rather than guessed.** owlkettle diffs a `Box`'s children **by
index** and updates in place when the state's type matches, and **`Button.shortcut` has no
update path** — it installs a `GtkShortcutController` in `build` and its `update` hook does
nothing but assert the value never changed, with owlkettle's own `# TODO` on that line.
**`gui.fullscreenButton` (`shortcut = "F11"`) is the only widget in this program that sets
one.** The pin toggle made the note header four children instead of three, so opening a
note handed the fullscreen widget to the **Send** button's state and `assert "" == "F11"`
aborted the process.

**Fixed by moving the toggle beside the note title** — where the Web UI puts its pin —
restoring the header's 3/3/5 branch shape exactly. Nothing was removed. Recorded as
**G-51** and as a comment at the point of discovery: **nothing may change the child count
of a container holding a shortcut-carrying `Button`.**

**A real limit of rule 17, now written down.** `bin/jenova --check` **exited 0 on the
broken build** and would again: it builds each branch once, and this class of assertion
fires only on an *update*, which needs a branch to change. `--check` proves the window
reaches its first frame; it never proves it survives a state transition.

### Session 022 (part two) — 2026-09-02 11:21 — 8c-1 and 8c-2 built

**A note keeps its FOCUS flag, and the window can set one.** Both defects found earlier in
the session are fixed, built and asserted.

**The fix for G-49 went one level up from where the plan put it, and that is the durable
part.** The plan said to resend `isFocusNote` where the node is built — which is what was
done for T-13, the same defect in the same shape, and **it came back anyway**, because
there are six `putEntity` callers and each new one inherits the trap: omitting a field
looks exactly like not needing it. **`api.putEntity` now merges a partial node onto the
stored row**, so any column the window omits is carried forward. It is the only function
every in-process window write passes through and nothing else calls it, so `upsert`,
`writeRow` and the whole HTTP contract are untouched — the Web UI still posts partial
objects and still means them (**D-CC**). **A create is unaffected**, having no stored row.

**G-50 is a pin toggle in the note header** — `view-pin-symbolic`, confirmed present in
this machine's Adwaita theme before it was used. `workspace.contextFor` did the rest; it
has had the escape behaviour since G-43 and had no way to be reached. New
**`workspace.isFocusValue`** is the one truth test both the context builder and the window
read, so the toggle cannot disagree with the behaviour it controls.

**18 assertions added to `workspace-selftest`, written through `api.putEntity` itself.**
That is the join: every other assertion in that suite inserts its rows with raw SQL, which
is exactly why none of them could see G-49 (rule 15, a fourth time). Asserted as a
transition — written FOCUS, survives a partial save carrying no flag, cleared and stops
escaping while staying at its own level, set again and the escape returns. **No single
wrong behaviour passes the whole set.**

**Twelve self-tests pass, both binaries are ELF 64-bit FreeBSD, `bin/jenova --check` exits
0.** The six shell suites were not run — Rule 0, and nothing touched is in their reach.

**Two things stated plainly.** **No red was produced and none was attempted** — D-BX
forbids corrupting the source, and a stash-and-rebuild has the same failure mode that
ruling was written about. The discrimination argument is structural and the prior revision
is in git. And **the toggle is unseen**: `--check` builds the widget tree and presses
nothing.

**Unseen, and it is what a screen run would show:** the pin toggle in the note header, and
a FOCUS note written from the window then turning up in a chat in a different folder.

### Session 022 — 2026-09-02 11:05 — every claim re-checked; two real defects found inside 8c

**No code was touched and nothing was run.** All ten trackers read; every current-state
claim read back against `src/`.

**Everything claimed built is built, and every outstanding finding still holds.** Twelve
`of "…-selftest"` cases in `src/jenova_core.nim`; `models.SourceRoles` is exactly
`["instruct", "thinking"]` and `switchToPath` removes a displaced **symlink** while still
renaming a displaced **real file** to `.old`; `models-selftest` is **22** `check` calls;
the window's app menu carries one `Models…` entry and the two named literals are gone,
with the tray's `TrayItem` pair still in `gui.nim`; `vte.configure` is passed
`nvimctl.editorEnv`; `pipeline.readAttachment` tries the PDF path before `looksTextual`;
`zlib.nim` is `{.passL: "-lz".}` with no `z_stream`; Step 11's removed symbols return
**zero** hits across `src/`; six shell suites and no shell, Lua, C, Python or Makefile in
`src/` or `bin/`. T-5, T-2, T-4, T-3, G-37 (`.glow-text` at `theme.nim:253`, zero hits in
`gui.nim`; `paned > separator` at 417/421), G-38 and G-17 each re-read and each still true.
Both binaries are ELF 64-bit FreeBSD and newer than every source file.

**Two documents were wrong, and both are the same class — a "not built" line outliving the
work that built it.**

1. **`ARCHITECTURE_MAPPING.md` §6b said the editor environment is not wired and that "both
   embedded editors run stock Neovim".** Neither half is true: 10c wired it on 2026-09-01
   and Step 11 left one editor. **This is `BLUEPRINT.md` §10's failure mode in the file
   Directive 4 designates the file-by-file map**, and §2 of that same file records the
   wiring as done.
2. **This file's own header said `jvim/` was untracked and the session's edits
   uncommitted.** Both are stale — see the header.

**And two defects that nothing had recorded, both of which land inside 8c.**

1. **Saving or renaming a note in the window silently clears its FOCUS flag (G-49).**
   `gui.saveNote` and the sidebar rename branch build a node with no `isFocusNote`;
   `api.f` returns `""` for a missing field and `api.writeRow` is INSERT OR REPLACE over
   **every** column, so the flag is overwritten empty and `workspace.allNotes` then reads
   it false. **This is the exact hazard the comment above that rename branch already
   names** — it was acted on for `fileAssets` and for a note's `content`, and
   `isFocusNote` was missed in both write paths.
2. **The window cannot create or toggle a FOCUS note at all (G-50).** `isFocusNote`
   appears nowhere in `gui.nim`. So 10a's FOCUS escape — the behaviour D-BU exists for —
   is reachable only from the frozen Web UI, which is a D-BC defect.

**Together they mean the FOCUS half of the workspace context is asserted, shipped, and
unreachable — and destroyed by the first save from the window.** That is rule 15's shape
again: `workspace-selftest` supplies its own rows, so nothing could tell.

### Session 021 (part three) — 2026-09-02 10:53 — the USER ran it; G-48 is closed

**Switching and folder resolution work as intended.** Confirmed on screen. **G-20 and
G-48 are done and gone from `TODOS.md`.**

**Which of the three changes fixed the reported failure was never diagnosed**, because the
symptom was never known. The reshape was D-CB's shape, not a repair aimed at a mechanism.
**No session is to write a diagnosis in later** — there was none.

**Loading a switched model into the backend was not exercised**, the USER not having
started it. That is **unobserved, not suspect** — §8, not a defect. **The two halves that
were confirmed keep their confirmation** (rule 12).

### Session 021 (part two) — 2026-09-02 10:43 — the switcher takes D-CB's shape

**G-48-1, -2 and -3 are built. G-48-4 — the reported failure — is untouched, because the
symptom is still not known.**

**The enumeration is the two source folders.** `models.available` drew from every
subdirectory of `models/` *and* the flat `models/` directory; it draws from
`models/instruct` and `models/thinking` and nothing else. An embed model or a
speculative-decoding drafter offered as the agent model produces a configuration
`lifecycle` never launches, and it fails as a model behaving oddly rather than as a list
that lied.

**A displaced symlink is removed, not renamed.** Every entry `switchToPath` has ever
written is a link into a source folder, so a `.old` copy of one preserves nothing and
leaves the directory fuller on every switch — which is the chain the USER saw. **A
displaced real file is still preserved**, because a `.gguf` put in `models/agent` by hand
is the user's only copy and deleting it is data loss. `symlinkExists` is an lstat, so it
tells the two apart.

**One switch surface in the window.** The two named menu items are gone — an explicitly
instructed removal, which is the only kind Directive 3 permits. **The tray keeps its
pair**, because a D-Bus menu cannot host a searchable list and removing them would leave
the tray with no way to change model at all. **That is a reading of D-CB's "in the
window", not a ruling — it can be overruled in one word.**

**`jenova-core models switch` is unchanged and asserted**; only its wording moved, to
"removed displaced model link".

**`models-selftest` is 22 assertions, and both new groups bite by varying the data
(D-BX).** The fixture holds an embed model, a drafter and a loose `.gguf` alongside the
two source folders, and asserts the source models present *and* the other three absent —
neither side passes alone. The backups are asserted as a **round trip**: α → β → α leaving
exactly one entry and no `.old*` at any point, because one switch cannot show a chain.

**Twelve self-tests pass, both binaries are ELF 64-bit FreeBSD, `bin/jenova --check` exits
0.** The six shell suites were not run — Rule 0, and nothing touched is in their reach.

**Unseen, and it is what the USER is about to test:** the Models panel against a real model
tree, and the app menu with one switch entry instead of three.

### Session 021 — 2026-09-02 10:00 — every claim re-checked against the source; G-48 scoped

**No code was touched and nothing was run.** All ten trackers read in full; every
current-state claim read back against `src/`.

**Everything claimed built is built**, verified by reading rather than by symbol
existence: twelve self-test cases dispatched in `src/jenova_core.nim`; `zlib.nim`
(`{.passL: "-lz".}`, no `z_stream`) and `pdf.nim`, with `pipeline.readAttachment` trying
the PDF path **before** `looksTextual` because a PDF fails the NUL test; `models.available`
/ `activeAgentPath` / `switchToPath` with `switchModel` still gated to the two literals and
still called by `jenova-core models switch`; `gui.modelsPanel`, `openModels`,
`switchToModel` and the `switch_path` job in `ctlWorker`; workspace context injected in
`pipeline`; `api.restoreItem` re-indexing; `gui.fileAttachmentsAsArtefacts` writing through
`api.putEntity`; `nvimctl.editorEnv`. Step 11's removed symbols return **zero** hits. Six
shell suites; **no shell, Lua, C, Python or Makefile in `src/` or `bin/`**.

**Every outstanding finding still holds** — T-5 (`gui.run`'s `defer` is four statements and
none is a `stopAll`), T-2, T-4, T-3, G-37 (`.glow-text` carried by no widget; `paned >
separator` at 417/421, the corrected address), G-38, G-17.

**Four things were wrong, and three of them change work rather than wording.**

1. **This file's §4 table and `PLANS.md`'s "Where the work stands" table both still gated
   PDF on the libz decision and still said to raise audio capture first.** Both were ruled
   on 2026-09-02 (D-BY, D-BZ) and **D-BZ forbids putting audio to the USER again in any
   form.** Corrected in both files. Same class as the `BLUEPRINT.md` §10 finding.
2. **There are three switch surfaces, not two.** The Models panel, the window menu's two
   named literals, **and the tray's two — which are built in `gui.nim`, not `tray.nim`.**
   D-CB says one *in the window*; the reading taken is that the tray keeps its two, since a
   D-Bus menu cannot host a list and removing them leaves it with no way to switch at all.
3. **`models-selftest` asserts the behaviour D-CB now forbids** — `TESTS.md` §0r records
   "the displaced model is preserved as `.old`, not deleted" as covered. G-48-2 invalidates
   that assertion, and `TESTS.md` §0r must change with it. Nothing said so.
4. **`models.available` also scans the flat `models/` directory**, not only the
   subdirectories every tracker names. The narrowing is two deletions, not one.

**And one consequence nothing recorded:** the `.old` chain lives in `switchToPath`, which
`switchModel` calls — so fixing it changes the tray's two quick-switches **and**
`jenova-core models switch`, whose output prints the `preserved:` lines.

### Session 020 (part three) — 2026-09-02 09:43 — the USER ran it

**PDF attachment is confirmed on screen.** Step 7b has no unverified claim left.

**The model switcher does not work (G-48), and its shape is wrong.** The symptom is not
known and is not to be guessed at. **D-CB settles what it must do:** draw from
`models/instruct` and `models/thinking` only, swap `models/agent`, do not accumulate
`.old` copies, and give the window one switch surface rather than two. What shipped
scans every subdirectory, so it offers embed and draft models as the agent model.

`models-selftest` passes throughout — the parts are asserted, the join to the window is
not, and the window is what fails (rule 15).

### Session 020 (part two) — 2026-09-02 08:43 — Step 7b closed and 8a built

**Two USER rulings, both of which they had given repeatedly and neither of which was
written down.** **D-BY: libz is approved** — it had been carried as "gated on a
dependency decision, yours" since Step 7b was written, which is what made them repeat it.
**D-BZ: audio capture is not needed and is not gated** — not scheduled, not to be raised
again. **The `input_audio` send path stays** under Directive 3; it carries imported Web UI
conversations, and not building capture is not licence to delete what already sends.

**Step 7b is closed — a PDF attaches as its text.** New `zlib.nim` (bound as
`uncompress`/`compress` only — no `z_stream` mirrored into Nim, D-V) and new `pdf.nim`
(content streams, FlateDecode, the four text-showing operators), wired into
`readAttachment`, which had refused every PDF outright. Stored in the Web UI's own PDF
shape. **A PDF with no readable text is refused, never attached empty** — a scan or an
Identity-H font yields nothing, and an empty attachment reads as a working one. **It is a
text extractor, not a renderer:** no layout, no reading order, no page images.

**8a is built — the window has a model list.** `models.available` is the enumerator
`discover` could never be; `models.switchToPath` generalises the switch with a containment
check; the two named quick-switches are **kept beside it, not replaced (D-CA)** because a
D-Bus tray menu cannot host a list. **Model information is deliberately not built** — it
needs `/props` plus a GGUF header read and is its own work.

**Twelve self-tests pass** — new `models-selftest` (15) and ten added to
`attach-selftest`, all proven to discriminate by varying the data (D-BX). Both binaries
ELF 64-bit FreeBSD; **`bin/jenova --check` exits 0**.

**Unseen, and it is what the USER is about to test:** the Models panel and its search, and
a PDF's text actually reaching the model.

### Session 020 — 2026-09-02 08:13 — all ten devdocs read; every claim re-checked against the source

**No code was touched and nothing was run.** All ten trackers were read in full and every
current-state claim read back against `src/` — **behaviour, not just symbol existence**:
`workspace.contextFor`'s six documented behaviours and its exact output strings,
`nvimctl.editorEnv` returning the whole environment, `gui.fileAttachmentsAsArtefacts`
filing at the conversation's own level and skipping an unscoped chat, `api.restoreItem`
re-indexing, and the settings parity assertion checking both directions.

**Everything claimed built is built.** Verified by reading the code, not a summary:
Step 11 (the document panel — **all fifteen named symbols return zero hits across
`src/`**), 10c (`nvimctl.editorEnv`, taken by `vte.configure`, passed to the spawn),
10a (`workspace.contextFor`, injected at `pipeline.nim:350`, scope supplied by
`gui.nim:1586`), 10b (`gui.fileAttachmentsAsArtefacts` writing through
`api.putEntity`), 8b (`api.restoreItem` re-indexing, `restoreEntity`, `deletedRows`,
`gui.refreshTrash`/`openTrash`/`restoreFromTrash`). Six shell suites under `tests/`.
**No shell, Lua, C, Python or Makefile anywhere in `src/` or `bin/`.**

**Every outstanding finding is still true**, each re-read: G-17, G-20, G-37, G-38,
T-2, T-3, T-4, T-5, G-42's `ContentScroll` (natural height propagated, natural width
deliberately not, `policy(AUTOMATIC, NEVER)`) and G-47's `NvimTerminal {.expand: true.}`.

**Seven things were wrong and are fixed.**

1. **`BLUEPRINT.md` §10 said the desktop application has "no attachments, no trash view,
   no stop control, and no typed error reporting". All four are built** — three at
   2026-09-01 15:46, the trash view at 19:05, both after that file's own timestamp.
   **This is the serious one: `AGENTS.md` designates `BLUEPRINT.md` the authoritative
   architecture, so a session reading it derives a product missing four features it has
   — which is D-AO's exact failure mode, in the file D-AO was written about.**
2. **`BLUEPRINT.md` §10 also contradicted its own §7**, calling hardware profile
   selection unreachable when §7 records it built the same day.
3. **`BRIEFING.md` §3 said ten self-test subcommands. The dispatch carries twelve.**
4. **`TESTS.md` said "Nine self-tests, six suites."** Both are counts, both are now
   pointers to `src/jenova_core.nim`. **That line has now carried four, five, six,
   nine and ten** — rule 9 exists for exactly this and the number keeps being rewritten
   instead of removed.
5. **`TESTS.md` §0i said `hardware-selftest` has 13 assertions. It has twelve.**
   (`attach-selftest` has **46** against 44 accounted for — noted, not corrected, because
   the number should not be written down at all.)
6. **`TODOS.md` G-37 said "`theme.nim` has not been touched since" and gave the
   separator rule at 428/432.** Step 11 deleted two `.doc-panel` rules from that file
   the same evening; it is **417/421**. The finding holds; the claim beside it did not.
7. **`DECISIONS_LOG.md`'s QUESTION STATUS index still described Q-30 as live** — two
   Neovim instances, `configureEditor` re-aimed on both transitions. Step 11 made it
   moot and `PLANS.md` says so; the index that exists to *be* the current read did not.
   Overridden at the top of the file.

**One finding of this session's own was retracted.** `ARCHITECTURE_MAPPING.md` genuinely
is not the file-by-file map Directive 4 defines — fourteen modules share one row — but
**Session 019 recorded that at 18:07 as deliberately left**, on rule 9's and D-AN's
reasoning. Filing it as a defect was the rediscovery that note exists to prevent. The
guard now lives in `ARCHITECTURE_MAPPING.md` itself.

**And one finding that changes the next step's shape rather than a document's wording.**
`PLANS.md` 8a said the model selector's first job was to call `models.discover`, which
was "a finished engine with nothing feeding it" — T-17's shape. **It is not.**
`discover` returns **one path for one of three fixed roles**, `switchModel` refuses any
target that is not the literal `"instruct"` or `"thinking"`, and `discover` has **no
caller anywhere in the product** — `jenova-core models list` echoes three `config`
values and never asks `models.nim` anything. **There is no enumeration to draw and no
way to activate an arbitrary model; two thirds of 8a's backend has to be written.**
`PLANS.md` 8a is rewritten against the source with the work broken into four parts and
a proof table.

### Session 019 — a new direction from the USER, and the claims audited

**The USER gave four instructions in one message, and they are one feature: a workspace
should carry its own notes, its own files, and an editor that works on them with the AI.**
Rulings **D-BS**, **D-BT**, **D-BU**, **D-BV**. The plan is `PLANS.md` **Step 10** plus a
rescoped **8c**; the items are `TODOS.md` **G-43**, **G-44**, **G-45**.

**Everything below was verified against the source before it was written down.**

1. **`jvim/` was added to the tree** — 4,201 files, untracked, the default configuration
   for the Neovim Jenova embeds, carrying a `lua/jenova/` layer with FIM, a chat drawer,
   LAN discovery, telemetry and an agent tool loop over buffer, LSP and shell. **D-BS
   rules it configuration, not product Lua** — the no-Lua rule archives Lua that
   *implements* Jenova, and porting a Neovim config to Nim is not a coherent idea. **A
   session must not archive it.** It is mapped in `ARCHITECTURE_MAPPING.md` §6b and
   `BLUEPRINT.md` §6b.
2. **The notes editor stays, Neovim is confined to the editor page, and the document
   side panel is removed (D-BW, superseding D-BT the same session).** The USER called
   the panel a gimmick. **This is a removal and Directive 3 permits it because it was
   explicitly instructed** — never cite it as licence to remove anything else. G-17 is
   now simply *make the notes editor good*; it is the smallest it has ever been.
3. **Workspace notes and files must reach the model (D-BU).** `pipeline.nim` contains
   **no reference to notes at all**, while `notes.isFocusNote`, `fileAssets.content` and
   `conversations.workspaceId` all exist and `api.nim` round-trips them. **The data model
   is complete and nothing reads it** — T-17's shape a third time.
4. **An uploaded file becomes a workspace artefact (D-BV).** **Nothing in the program has
   ever written a `fileAssets` row.** This decides half of Step 7d.

**Both questions raised at 18:29 were answered by the USER at 18:41, and no question is
open.** **Q-34 — parity with the Web UI:** `messages.extra` keeps the inline base64
exactly as D-BP stores it and the artefact is written *in addition*, so nothing about the
message row changes. **That closes Step 7d.** **Q-35 — no:** keep the notes editor, do not
replace it with Neovim, and remove the document panel. **T-11 is not touched by any of
it** — with notes in their own editor and Neovim on its own page there is no second
writer against an authoritative row at all, which is the outcome Q-29 was protecting.
**Both answers reduce scope.**

### G-40 is confirmed on screen. G-41 is half-confirmed.

**The USER ran the 17:51 build: uploading attachments works as intended.** Step 7c's one
outstanding item — whether the window is responsive with a document attached, which
nothing here could assert — **is closed by that run** (rule 12: do not re-add the label).

**Tables are no longer clipped to a stub, but now render larger than their content.**
Filed as **G-42**, `TODOS.md` Backlog. The USER: *"not too serious."* The cause is G-41's
own fix — `ContentScroll` propagates natural height and deliberately not natural width,
which stopped the collapse without constraining the result down.

### The claims audited again, and the citation policy changed

**No code was touched and nothing was run.** Every outstanding claim in `TODOS.md`
and `PLANS.md` was read back against the source.

**Every finding is true.** G-17, G-20, G-21, G-37, G-38, T-2, T-3, T-4 and T-5 were
each confirmed by reading the code they describe, and so was the Step 8b note that a
restored message is never re-indexed. **Everything claimed built is built:** the
self-test subcommands dispatched from `src/jenova_core.nim` *(the count that stood
here was ten and is now wrong again — read the `of "…-selftest"` cases out of the
file, per rule 9)*, six `nimble` tasks, six shell suites, `settings.nim` with its parity assertion, `hardware.nim`,
`pipeline.ParseMemo` / `markdown.BlockMemo` / the 25 MB cap from 7c, `AutoScroll` and
`ContentScroll` with their three protos from G-41, and the retrieval feed wired from
`api.nim` and `gui.nim`. **No shell script, Lua file, C file or Makefile exists
anywhere in the product tree.**

**Two things were wrong and are fixed.**

1. **The self-test count was wrong in three files, three different ways** — `BRIEFING.md`
   §2 said nine, `PLANS.md` said nine, `TODOS.md` said six. `jenova_core.nim` dispatches
   **ten**. §1 had already recorded the correction on 2026-09-01 at 17:27 and the other
   lines were never brought with it.
2. **The seventh citation sweep, and the last one.** The addresses split perfectly by
   file: **every** line reference into `db.nim`, `fssync.nim`, `pipeline.nim`,
   `theme.nim` and `lifecycle.nim` was correct; **every** reference into `gui.nim` and
   `api.nim` was wrong, because 7c and G-41 took `gui.nim` from 3,916 to **4,019**
   lines. **Seven sweeps have now re-derived the same two files and all seven rotted.**
   So the numbers into those two files are **deleted, not corrected** — a reference in
   `TODOS.md` and `PLANS.md` now names the symbol and stops. That is rule 9 finally
   applied instead of restated.

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

> **Corrected 2026-09-02 10:00.** This table gated PDF on "a zlib dependency decision,
> yours" and told the next session to raise **audio capture** before building it. **libz
> was approved (D-BY) and PDF is built and confirmed on screen; audio is ruled not needed
> and not gated (D-BZ), and is not to be put to the USER in any form.** It also listed the
> trash view as missing while the Works column below lists it as built. **This is the same
> class as the `BLUEPRINT.md` §10 finding — a summary table outliving the ruling it
> describes, and it is what made the USER repeat both answers for weeks.**

| Works | Missing entirely |
|---|---|
| Send a message, stream a reply | **A real note editor** (G-17) |
| Copy, edit, delete, regenerate, continue a message | **LaTeX maths** — the half of G-34 left |
| Branching — alternative versions, with a counter | **Model information** — context size, quantisation, chat template. Needs `/props` plus a GGUF header read; never built and said so |
| Statistics: tokens, tok/s, context used and left, model | — |
| A reasoning view for thinking models | — |
| **A PDF attaches as its extracted text** (G-30, D-BY) — confirmed on screen | — |
| **A model switcher** (G-20, G-48, D-CB) — confirmed on screen | — |
| **Stop a generation, keeping the partial answer** (G-33) | — |
| **Markdown tables, task lists, strikethrough** (G-34) | — |
| **Typed errors, Retry, context-overflow reporting** (G-35) | — |
| **Delete confirmations naming the cascade** (G-36) | — |
| **Attachments: picker, drag-and-drop, paste, thumbnails, preview** (G-30) | — |
| Recall of past chats — the index is fed | — |
| **Workspace notes and files reach the model**, scoped and with FOCUS notes (G-43), **and a note can be marked FOCUS from the window** (G-50) | — |
| **An upload is filed as a workspace artefact** (G-44) | — |
| **The editor page loads `jvim`** (G-45) | — |
| **A trash view, whose restore also re-indexes** (G-21) | — |
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

> ### **G-40 — attachments froze the entire window. Fixed 2026-09-01 17:51 (Step 7c).**
>
> **Reported by the USER; the GUI stopped responding on attaching a document.** Not
> a crash — unbounded synchronous work on the GTK thread, from four compounding
> causes. The worst: `attachmentPixbuf` built its cache key as `sha256(payload)`
> **on the line above the lookup that key served**, so a multi-megabyte hash ran on
> every frame — a cache that guaranteed the cost it existed to avoid. Alongside it
> `view` re-parsed every attachment's JSON and every message's markdown per frame,
> `postConversation` re-parsed every payload per send, and nothing capped input.
>
> **Fixed** with an identity key (name/size/mtime, never content), one parse per
> message held in `pipeline.ParseMemo` and `markdown.BlockMemo`, and a **25 MB cap
> that refuses rather than truncates** (**D-BQ**). 17 assertions, three clean reds.
>
> **The rule it establishes:** *nothing inside `view` may do work proportional to a
> payload.* `view` runs on every frame; a proc called from it may look things up
> and must not parse, hash, decode or copy.
>
> **Unverified, and it is the whole point:** whether the window is actually
> responsive with a document attached. The counters prove the work is not repeated;
> they cannot prove the frame budget is met. **That is a USER run.**

> ### **G-41 — tables were a fixed size; autoscroll did not follow. Fixed 2026-09-01 17:58.**
>
> Both from one gap (**D-BR**): **owlkettle's `ScrolledWindow` exposes `child` and
> nothing else.** A bare one reports a near-zero minimum height and collapses its
> child, so every table was clipped to a stub regardless of row count — the same
> trap this project already documented at the code-block cap. `ContentScroll`
> propagates natural height, not natural width, so a table takes the room its rows
> need and still scrolls sideways.
>
> **Autoscroll read the adjustment in the widget's own `update` hook, which runs
> before GTK re-measures the new token** — so it acted on a stale height every
> frame and, once a reply grew faster than its 64px tolerance, stopped following
> for the rest of the generation. Now driven from the adjustment's `changed`
> signal, with `value-changed` recording whether the reader has scrolled away.
>
> **Neither is asserted and neither can be — both are widget behaviour.**

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

All six suites and every self-test exercise `jenova-core`. **Nothing tests `gui.nim` at
all.** Every GUI defect in this project's history was found by the USER looking at the
screen.

**The response is working and should be continued.** Branching's tree walk went into
`api.nim`, the request body into `pipeline.chatBody`, the chat indexer into `rag.nim`,
and on 2026-09-01 the workspace scoping ladder into `workspace.nim`, the editor
environment into `nvimctl.editorEnv` and the trash listing and undo into
`api.deletedRows`/`restoreEntity` — all below the widget layer, all asserted, none of
them requiring a window. **Where a GUI feature's behaviour can be moved below the widget
layer, move it there and assert it.** What is left in `gui.nim` is then layout, which is
what a screen is actually for.

## 7. Waiting on the USER

**Nothing in the plan is blocked and no symptom is outstanding.** Q-36 was raised and
answered on 2026-09-02 (D-CB); **G-48 was closed by the USER's run at 10:53.**

Three product decisions remain parked, none on the critical path: filesystem as the
source of truth (T-11), deployment (T-7), a CLI (T-8).

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
4. **A switched model actually loading.** The switch itself and the folder resolution are
   **confirmed** (2026-09-02 10:53); what was not exercised is the other end — restarting
   the backend and `llama-server` coming up on the newly linked `models/agent`. The USER
   had not started it. **Unobserved, not suspect**, and by design: the panel says a switch
   does not reload the backend, because `llama-server` holds the old weights until it is
   restarted.
5. **The note header's pin toggle** (G-50, 11:21). A FOCUS note marked from the window
   should then appear in a chat scoped to a *different* folder in the same workspace,
   under `--- FOCUS / RULES ---`. Both halves are asserted below the widget layer and the
   toggle itself is a widget — `--check` builds it and presses nothing.
   `view-pin-symbolic` was confirmed present in this machine's Adwaita theme before it
   was used, so it is the drawing and not the icon that is unseen.
6. **Four icons still unconfirmed**: `view-refresh-symbolic`,
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

## Next — `PLANS.md` **Step 8, the remaining views**

**Step 7c is done** — attachments no longer freeze the window. **The one thing
outstanding from it is a USER run**: the parse counters prove the work is not
repeated, but nothing here can prove the window is responsive with a document
attached.

**Step 7d is a decision, not work:** attachment payloads still live inline in
`messages.extra` (D-BP), so each is held in `allMessages`, again in `messages`,
and again in the outbound body — and every image is re-uploaded to
`llama-server` on every subsequent turn, which **T-3** (no history trim) makes
permanent. Moving payloads out of the row would fix all of it and would diverge
from the frozen Web UI's storage shape. **Worth raising only if 7c does not make
the window responsive.**

**Step 11, 10c, 10a, 8b and 10b are built** (2026-09-01 19:05 and 2026-09-02
07:51). Every self-test passes, both binaries are ELF 64-bit FreeBSD,
`bin/jenova --check` exits 0. The record is `PROGRESS.md`; the detail is
`PLANS.md` "What Session 019 built".

**Step 7b and 8a are built and both confirmed on screen** — 8a shipped, did not
work, was reshaped to D-CB at 2026-09-02 10:43, and the USER ran it at 10:53.

**Next — 8c-3 … 8c-6, the rest of the notes editor** (G-17, D-BW). **8c-1 and
8c-2 are built** (11:21) — the two correctness defects that were inside it. What
is left is comfort work: a Markdown view with Edit/Cancel, not losing unsaved
text on Close, delete behind the existing confirmation, and the list
affordances. Six parts and a proof table are in `PLANS.md` 8c.

**One thing 10b leaves unproven and it is a USER run:** whether an attachment
actually appears in the workspace tree, and whether its text then comes back in
the model's context on a later turn. The row write and the context render are
each asserted; the two meeting on a live chat is not.

**Two open defects, both widget behaviour and both a USER run:** **G-42**,
markdown tables now render larger than their content — caused by G-41's own fix,
which propagates natural height and deliberately not natural width, so the
collapse stopped without the result being constrained down. And **G-47**, the
editor page's Neovim truncated at the bottom on a resize, reported at 18:41 and
**not diagnosed** — a candidate mechanism is written in `TODOS.md` and flagged
as a candidate, not a finding.

**Then Step 9:** T-5, T-2, T-4, T-3.

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
