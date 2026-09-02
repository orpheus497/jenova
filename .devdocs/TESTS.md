# TESTS

Test specifications, validation criteria and expected outcomes. Mandated by `AGENTS.md`
§ WORKSPACE ARCHITECTURE.

**Created:** 2026-08-28 (Session 004). **Last updated:** 2026-09-02 12:19 (Session 022).
Mandated from the outset; absent for Sessions 001–003. See `DECISIONS_LOG.md` C-10.

> **§5a onward are stage acceptance records** — what each stage had to prove and how. They are
> history, kept for the reasoning. **§0 is the current suite.**
>
> **The commands in §5a–§5f no longer run — corrected 2026-08-31 (Session 007).** They were written
> against a tree that no longer exists and a session copying one of them will get an error, not a
> result. Specifically: **`make core` and `make check`** (§5a N-S0, §5b, §5c, §5d) — there is no
> Makefile (D-AM); **`tests/Makefile check`** — archived; **the N-S1 shell comparison**, which
> sources `lib/detect-env.sh`, `lib/jenova-conf.sh`, `lib/jenova-model.sh` and reproduces
> `bin/jenova-ca:44-48` — all four files are archived, and the inverted-precedence defect it
> measured (B-12 / Q-9) died with them; and **`jenova-core llama-selftest`** (§5f N-S4) — that
> subcommand went with `llama.nim` and `inference.nim` on 2026-08-31.
>
> **The recorded results and the reasoning remain valid as history.** What each check was *for* is
> why these sections are kept. **§0 is the only section to run anything from.**

---

## 0. Current suite — 2026-08-31

**`nimble suites`** builds both binaries then runs the scripts below. Each runs in a scratch
`JCA_HOME` and none spawns a `llama-server` backend.

| Script | Covers |
|---|---|
| `test_api_db.sh` | The `/api/db/*` contract — cascades, fork reparenting, upward restore |
| `test_api_fs.sh` | The filesystem mirror, `/api/fs/*`, `/api/storage/*` and its containment |
| `test_routes.sh` | The route inventory, incl. the pipeline reaching the upstream |
| `test_lifecycle.sh` | The `llama-server` argument vector, `--lan`, port flags, refusal paths |
| `test_models.sh` | Model discovery and switching (§5h) |
| `test_nvimctl.sh` | Reading the live Neovim buffer (§5i). **The one suite that spawns a process** — a headless `nvim` — and the only one needing a compiled driver, `tests/nvimctl_check.nim`. Skips cleanly with no `nvim` installed |

Plus the core's own self-test subcommands, and **`db-capabilities`**, which reports rather
than asserts. **Read the list out of `src/jenova_core.nim`, never from a count written
here** — this line has said nine and ten while the source said otherwise, and
`workspace-selftest` (§0o) and `nvim-env-selftest` (§0q) were added on 2026-09-01.

**There is no Makefile.** `make check` and `make -C tests check` no longer exist (D-AM).

**Archived 2026-08-31:** `test_gpu.sh`, `test_gpu_single.sh`, `test_validate_arg.sh`,
`download-draft-model.sh` — orphaned, wired into nothing. `test-health.sh` went earlier: it shelled
to `python3` and started no server.

**A new suite must be proven able to fail.** Two suites in this project have reported PASS while
asserting nothing. `test_models.sh` was verified by corrupting what its assertions read and
confirming it goes red.

## Do not run these unless the USER asks — 2026-09-01 (**D-BJ**)

**A session does not run `nimble suites`, the product, or the backends on its own
initiative** while the migration is in progress. Running takes the machine's ports and
loads gigabytes onto the GPU, in the middle of the USER's own work. **Building is not
running:** `nimble core` and `nimble gui` are free and are how a change is checked to
compile.

**And do not enumerate processes or ports to find out what is already up.** That is an
audit of the USER's machine, nobody asked for it, and it is where the T-12 loop starts
every time.

**T-12, stated once and closed.** `test_routes.sh` and `test_lifecycle.sh` fail if
anything already holds the real ports, because neither overrides `JENOVA_LLAMA_PORT` the
way both already override `JENOVA_PORT` — `test_routes` expects a 502 meaning "no
`llama-server` answered", and `test_lifecycle` runs `backends health` and `backends start`
with no override, so the product's correct *"port 8081 is already in use"* refusal reads
as a failure. **Neither is a product fault, this has been fully diagnosed three times, and
it is not to be diagnosed again.** The one-line fix — give both scripts their own dead
upstream ports — is in `TODOS.md` Backlog. A session that sees those failures writes
nothing about them.

**Also: invoke the suites through `nimble suites`, never the scripts directly.**
`test_nvimctl.sh` compiles `nvimctl_check.nim` and `nim` is not on `PATH` — only `nimble`
puts it there. **The same trap catches any direct `nim` call**, including a compile-guard
check: it fails with "command not found", which reads as silence rather than an error.

**Six suites, and the self-tests — read their list out of `src/jenova_core.nim`, never
from a number written here.** *This line said "nine" until 2026-09-02 08:01, when the
dispatch carried twelve; the count has now been wrong in this file twice and in three
other files once each. It is rule 9: the number is derivable and it rots.*
*`tree-selftest` was added 2026-09-01 for the
branching tree walk, `hardware-selftest` the same day for profile scoring (§0i),
and `markdown-selftest`, `error-selftest` and `attach-selftest` for Step 7 (§0j).
Earlier trackers said four self-tests;
`db-capabilities` is a capability report, not an assertion, which is where the
miscount came from.*

## 0w. The Step 9 assertions in `pipeline-selftest` (T-3 and T-2, 2026-09-02 12:19)

**12 added.** Both are properties a comment can claim and only an assertion can hold.

**T-3, the history trim — 7 assertions, and the shape is the point.** Both sides of the
budget, so neither an always-trim nor a never-trim implementation passes. **The two
messages that must survive are asserted separately from the count**, because a trim that
kept the right *number* and the wrong *messages* would satisfy a count on its own. That
what went was the **oldest** and not the newest is its own assertion, for the same reason.
An impossible budget must still leave a sendable request — the system message and the
question — because content is never shortened (D-BQ). And **a zero budget must trim
nothing**, or a deployment that never called `configureHistoryBudget` would silently lose
turns.

**T-2, the statement cache — 4 assertions.** More than a cap of *distinct* SQL texts is
issued, which is the shape `api.updateMessage` produces and the reason the leak existed.
Then: the cache is bounded, **it did not simply stop caching** (a bound of zero would pass
the first assertion alone), and — **the one that matters more than the bound** — a query
still works afterwards. A flush that finalized a handle still in the table would raise or
return nothing there.

**Neither was shown going red, and none was attempted (D-BX).** The discrimination is
structural, as above.

## 0v. `fs-selftest` — the file-containment check (T-4, 2026-09-02 12:19)

**New subcommand, 10 assertions.** `fssync.resolveStoragePath` is what stands between a
path a client supplies on `/api/storage/*` and the rest of the filesystem, and it had a
hole at each end. **Its own subcommand rather than a block in an existing one**, because
`fssync.roots` caches the first root it resolves — `JENOVA_WORKSPACES` has to be set before
anything in the process touches it, and only a fresh process can guarantee that.

**A real tree with real symlinks**, because the defect *is* symlink resolution and a
fixture that fakes it would assert nothing. The workspaces root is itself a symlink, and a
directory inside the tree points out of it.

**Both holes, and both sides of each — which is the whole design.** A check that refuses
everything passes a refusal test; one that accepts everything passes an acceptance test.
So: a symlinked *root* accepts both an existing file and a **new** one under it (hole two,
which refused the entire tree); an escaping symlink refuses an existing file **and a new
one, and a new directory under it** (hole one — the old check ran only on paths that
already existed, so every *create* walked straight through). The lexical refusals —
traversal, buried traversal, empty, NUL, newline — are asserted alongside, so the fix
cannot have loosened them.

## 0u. What 8c-3 … 8c-6 added, and what could not be asserted (2026-09-02 11:53)

**No new assertion was written, and three of the four parts needed none — by
construction rather than by omission.** Recorded because "nothing was added" is exactly
the line a later session should be able to check rather than re-derive.

* **8c-3** — the note view and the transcript now call the **same** `gui.mdBlock`, so
  "a note renders like a reply" is true by construction. The parsing under it is
  `markdown.parse`, already asserted in `markdown-selftest`.
* **8c-5** — `cascadeCount("notes", …)` was already asserted in `db-selftest`. The FOCUS
  refusal is a widget condition.
* **8c-6** — the sort is `listNotes`' `ORDER BY updatedAt DESC` and the filter is
  `gui.leavesIn`; both predate the step. The change was a placeholder string.

**8c-4 cannot be asserted from here, and that is the honest answer rather than an
oversight.** `noteDirty` and `confirmLoseNoteEdits` take `AppState`, the type owlkettle's
`viewable` macro emits **inside `gui.nim`**, and `gui.nim` links into no test binary —
`jenova-core` does not import it. Moving the guard below the widget layer would mean
moving the buffer with it, and the buffer is a `GtkTextBuffer`. **So it is a USER run**,
and the standing gap in §6 of `BRIEFING.md` is the reason.

**And `--check` is not evidence for any of this.** It builds each branch once; the note
editor's modes, the dialog and the delete refusal are all *transitions*. That limit is
G-51's lesson and is now written into rule 17 itself.

## 0t. The FOCUS-note assertions (G-49, G-50, 8c-1/8c-2, 2026-09-02 11:21)

**18 added to `workspace-selftest`**, and where they are written is the point of them.

**Why they exist:** a note marked FOCUS applies across the whole workspace tree, and every
other assertion in that suite inserts its rows with raw SQL. **So nothing could see that
saving a note through the window's own path blanked the flag** and quietly demoted the note
to its own level — the model simply stopped being told a rule, which reads as a model
ignoring it. That is rule 15 for the fourth time in this project, after `rag.nim`,
`fileAssets` and the workspace store itself.

**So these go through `api.putEntity`** — the exact call the Save button makes — rather
than through an INSERT. That is the join, and it is the half a unit check cannot see.

**Asserted as a transition, never as a state (D-BX).** A note is written FOCUS and reaches
a folder chat from the workspace root; **a partial save carrying no `isFocusNote` leaves it
FOCUS**; a node omitting the content leaves the content intact; clearing the flag stops the
escape **while the note is still present at its own level**; setting it again brings the
escape back. **No single wrong behaviour survives the set** — ignoring the flag fails the
carry, always carrying it fails the clear, and dropping the note entirely fails the
own-level check. `workspace.isFocusValue` is asserted from both sides for the same reason:
a version that always answered yes, or always no, would pass a one-sided set.

**No red was produced and none was attempted.** The discrimination argument above is
structural. **D-BX forbids corrupting the source to watch an assertion bite**, and a
stash-and-rebuild has exactly the failure mode that ruling was written about — a restore
that does not run leaves broken source behind a green build. The prior revision is in git.

**The suite now points `JENOVA_WORKSPACES` at a scratch directory**, set before
`paths.resolve()`, because writing through `putEntity` mirrors the row to disk and
`fssync.roots` caches the first root it resolves. Without it the self-test would leave note
files in the USER's own `Workspaces`.

**Not covered, and it cannot be from here:** the pin toggle is a widget. `--check` builds
the tree and presses nothing.

## 0r. `models-selftest` — the model list and the switch (G-20, 8a, 2026-09-02 08:43)

**Why it exists:** a selector that quietly omits a model, or offers a `.old` backup as an
installed one, does not fail loudly — the wrong model simply loads, which looks like a
model behaving oddly rather than a list that lied. The enumeration and the switch are in
`models.nim`, below the widget layer, so both are asserted against a fixture tree with no
window and no GPU.

**Every assertion varies the data, never the code (D-BX).** One tree, and the switch is
asserted as a **transition**: nothing active → alpha active and beta not → beta active
and alpha not. Those three cannot all pass unless the flag is real.

**Rewritten to D-CB — 2026-09-02 10:43, G-48. 22 assertions.** *(The two it replaces —
"every installed model is listed" and "the displaced model is preserved as `.old`, not
deleted" — were the shape D-CB forbids. They were rewritten with the fix rather than left
to go red, which is what a superseded assertion otherwise does.)*

**The narrowing, asserted from both sides of one tree.** The fixture holds `instruct` and
`thinking` **and** an `embed` model, a `draft` model and a `.gguf` loose in `models/`.
Both source models are listed; the embed, the draft and the loose file are **not**; and
every row's role is one of the two. **Those cannot all pass unless the scan is exactly the
two folders** — asserting only the absences would pass on a list that returns nothing.

**The backups, asserted as a round trip and not a state.** α → β leaves `models/agent`
holding exactly `beta.gguf`; β → α leaves exactly `alpha.gguf`; **no `.old*` at any
point**, and the active flag comes back with it. **One switch proves nothing here** — the
chain the USER saw only appears once a model is displaced twice, so the assertion has to
return to where it started. The other side of the rule is asserted after it: a **real**
`.gguf` written into `models/agent` by hand **is** renamed to `.old`, because it is the
user's only copy.

**Also covered:** a `.old` backup is not listed · the role is the directory it sits in · an
empty tree lists nothing rather than raising · the link target is **relative**, since an
absolute one works until the tree moves · a path outside `models/` is refused and so is a
file that is not a `.gguf` — containment, because `switchToPath` is exported · **and the
two named targets still work**, which is Directive 3 asserted rather than assumed.

**Not covered, and it cannot be from here:** the panel, its search box and the Switch
button are widgets. `--check` builds the tree and presses nothing.

## 0s. The PDF assertions (G-30, Step 7b, 2026-09-02 08:43)

**10 added to `attach-selftest`**, once libz was approved (D-BY).

**The fixture is built both ways from one page**, compressed and not, so the FlateDecode
path is asserted against the same expected text as the plain one rather than against a
second fixture that could drift from it. **The zlib binding is proven by a round trip**
— `inflate(deflate(x)) == x` — which is `rag.vectorRoundTrip`'s precedent and the reason
`deflate` exists at all.

**Covered:** an uncompressed stream yields its text · a FlateDecode stream yields the
same · a kerned `[(Hel) -250 (lo)] TJ` is **one word**, which is what collecting strings
before flushing them is for · a hex string decodes · an escaped paren does not truncate
the literal · **a page with no text objects yields nothing** · a file that is not a PDF
yields nothing · **a PDF with no readable text is refused rather than attached** · a
readable one attaches as `PDF` carrying its text.

**The two negatives are the load-bearing ones.** An empty attachment would look exactly
like a working one while the model answered about nothing — the same class as a truncated
file (D-BQ) and an unset value sent as a zero (D-BK).

**Known limit, asserted around rather than hidden:** a font using Identity-H encodes glyph
indices, so `pdf.looksReadable` rejects the result. This is a text extractor, not a
renderer — no layout, no reading order, no page images.

## 0p. Proving an assertion bites — **without touching the code** (D-BX, 2026-09-01 19:00)

**The method changed and this is the record of what replaces the old one.** Corrupting a
source file to watch a suite go red is forbidden (D-BX) after a session did it, lost the
restore to an interrupted command, and left broken source behind a green build. The
concern that practice served is real and unchanged — **an assertion that cannot fail is
worthless, and this project has shipped two suites that reported PASS while asserting
nothing.** These are the techniques that answer it, all used in this session:

| Technique | Where it is used |
|---|---|
| **Assert both sides of one fixture.** A datum asserted *visible* in one scope and *invisible* in another cannot both pass unless the scoping is real | `workspace-selftest`: `note-a2` is visible to a project chat and invisible to a folder chat |
| **Assert a transition, not a state.** A sequence that must change direction proves the behaviour end to end | `pipeline-selftest`: recalled → deleted → not recalled → restored → recalled |
| **Build the hostile condition inside the test** rather than hoping the environment supplies it | `nvim-env-selftest` sets a colliding `JENOVA_PORT` with `putEnv` and asserts ours wins |
| **Derive the expected value rather than eyeballing a threshold** | `nvim-env-selftest` computes the exact entry count from `envPairs()` |

**Two assertions written this session could not fail and were caught by this thinking, not
by a corruption:** `check("no key is duplicated", true)` is unconditionally true, and
`env.len > 8` stayed green with the entire inherited environment missing, because the
added keys alone number nine. Both were replaced with exact derivations.

---

## 0o. `workspace-selftest` — workspace artefacts reach the model (G-43, 2026-09-01 19:05)

**32 assertions over a hand-built tree** — one workspace, two projects, two folders under
the first project, regular and FOCUS notes at every level, and two file assets (one with
content, one without).

**The scoping ladder**, which is the half a summary always gets wrong:

- A folder chat sees its own folder's note, **not a sibling folder's**, not the project's
  own, not an unassigned one.
- A project chat sees the project's note **and its child folders'**.
- A workspace chat sees everything nested below it.
- **A global chat sees only what belongs to nothing** — not everything, which is how a
  rule written for one workspace would end up answering a question about another — and
  **gets no FOCUS notes at all**.

**The FOCUS escape:** a workspace-root FOCUS note reaches a *folder*-level chat, labelled
`[Workspace]` from the note's own level and not the asking chat's. A FOCUS note with
blank content contributes nothing.

**The literal format:** all three headings verbatim, `Title:`/`Content:`, `File: <name>
(Type: <type>)`, and the exact string `(Binary file, content not available for direct
reading)`. A trashed note is not quoted back to the model.

**THE JOIN — assertions 24-32, and the ones that matter.** Every assertion above would
stay green if nothing ever *called* `contextFor`, which is exactly how `rag.nim` was
finished, asserted and completely dead for weeks (T-17, rule 15). So: the context reaches
the outbound body, under the Web UI's own heading, **in a system message and not a user
turn**, with the user's own turn untouched and still last. An **empty** context injects
nothing at all — no stray system message — and an **existing** system message is extended
rather than replaced, with no second one inserted.

## 0q. `nvim-env-selftest` — the editor's environment (G-45, 2026-09-01 19:05)

Every key `jvim/lua/jenova/endpoints.lua` reads, with the values it expects, so a rename
on either side goes red and names itself. `JENOVA_LAN_MODE` asserted in both directions.

**The one that matters: the environment is complete.** VTE's `envv` *replaces* the child
environment rather than extending it, so a result carrying only the `JENOVA_*` keys is a
broken editor — it fails as "nvim: not found", which reads as a missing dependency rather
than as this function's bug. **Same class as the `detectGpu` `LD_LIBRARY_PATH` failure in
§0i: an unreachable thing and an absent thing produce the same silence.** Asserted as an
exact count derived from `envPairs()`, plus `PATH` and `HOME` surviving by value.

**And an inherited value is overridden in place, not appended** — the collision is created
by the test with `putEnv`, because `paths.findRoot` documents that `JENOVA_ROOT` *is*
exported by the shell launchers, so it is the real case.

---

## 0n. What Step 11 must prove — the panel removal (G-46, D-BW, 2026-09-01 18:41)

**Almost none of this is assertable, and saying so is the honest answer.** Step 11 is a
deletion: there is no behaviour to assert, only the absence of one.

**What must hold:** `nimble core` and `nimble gui` build, every self-test still passes,
and **`bin/jenova --check` exits 0.**

**`--check` is the check that matters here and it is not a formality.** Rule 17 exists
because the Theme setting shipped a 100% SIGABRT behind a clean compile. **Removing a
widget block is precisely the change that compiles and then fails to build a window** — a
dangling style class, a `sizeRequest` on a widget that no longer exists, a renderable
still referenced from one branch of `mainArea`. `--check` builds the whole tree under a
real GTK, shows no window, starts no backend and binds no port, so it is allowed where
running the product is not (D-BJ).

**One thing to check by reading, not by running:** that `pipeline.configureEditor` is
left set **once**, in `gui.run`, to `nvimctl.socketPath`. The panel re-aimed it in
`openDoc` and restored it in `closePanel`; if either call is deleted without the other,
`Editor:` ends up pointed at a socket nothing listens on and the intent silently returns
no document — **which looks exactly like "the model can't see my file" and is the same
failure class as the `detectGpu` `LD_LIBRARY_PATH` bug** (§0i): an unreachable thing and
an absent thing produce the same empty string.

**Existing `document.md` files must still be on disk afterwards.** They are the USER's
files; the removal takes the surface, not the data.

---

## 0m. What Step 10 must assert — written before the code (2026-09-01 18:29)

**Written up front deliberately.** Every feature in this project that was proven after
the fact shipped a hole; the ones whose assertions were written with the plan (settings,
hardware, attachments) did not.

### 10a — workspace artefacts reach the model (G-43, D-BU)

**This is the one that must not be asserted only in parts.** `rag.nim` was fully
asserted and completely dead for weeks because every assertion supplied its own corpus
(rule 15). G-43 is the same shape — a complete data model with no reader — so **the join
is the assertion that matters**, not the formatter.

Over a hand-built tree (one workspace, two projects, two folders, regular and FOCUS notes
at every level, plus file assets), in `pipeline-selftest`:

| # | Assertion |
|---|---|
| 1 | **Scope isolation** — a chat set to folder A does **not** see folder B's regular notes |
| 2 | **Widening** — a project chat sees the project's notes *and* its child folders'; a workspace chat sees everything nested |
| 3 | **FOCUS escape** — a workspace-root FOCUS note reaches a *folder*-level chat. This is the behaviour a summary always loses and the reason the flag exists |
| 4 | **The global fallback** — a chat with no container sees only artefacts with no container, and **no** FOCUS notes |
| 5 | **The literal format** — `--- FOCUS / RULES ---`, `[Folder\|Project\|Workspace] Title`, `--- NOTES ---` with `Title:`/`Content:`, `--- FILES ---` with `File: <name> (Type: <type>)`, and the exact string `(Binary file, content not available for direct reading)` for a file with no content |
| 6 | **A blank FOCUS note contributes nothing** |
| 7 | **THE JOIN** — the text lands in the **system message of the body actually sent**, under `[CURRENT WORKSPACE ARTIFACTS (Notes & Files)]`, alongside the persona and the RAG context rather than displacing them |

**7 is the one that would have caught T-17.** A corruption that removes the injection
call while leaving the builder intact must go red on 7 and stay green on 1–6; if it does
not, the assertion set has the hole rule 16 describes.

**Known and deliberately not asserted:** there is **no token budget**. The Web UI has a
standing `TODO` saying the same, and Jenova inherits it by taking parity. It belongs with
**T-3**, not here.

### 10b — an upload becomes an artefact (G-44, D-BV)

Attaching a file to a conversation scoped to a workspace/project/folder writes a
`fileAssets` row **at that level**; the row is picked up by 10a's builder; deleting the
container cascades it. **Shown going red against the current source, where no
`fileAssets` row is ever written by anything.**

### 10c — the editor's environment (G-45, D-BS)

The spawn environment is built by a proc that takes no terminal, so it is asserted
directly: `NVIM_APPNAME=jvim` is present, and `JENOVA_ROOT`, `JENOVA_PORT` and
`JENOVA_LAN_MODE` carry the values `paths`/`config` hold. **Whether jvim actually loads
is a USER run** — the same honest split as every widget in this project.

### 8b — the trash view (G-21)

The restore re-index is the assertable half: index an exchange, delete it, assert
`rag.query` no longer returns it, restore it, **assert it comes back without a
`backfillChats` call**. The view is widgets.

---

## 0l. Confirmed on screen by the USER — 2026-09-01 18:29

**G-40 is verified.** The USER ran the 17:51 build and **uploading attachments works as
intended**. Step 7c §0k's standing caveat — that the parse counters prove the work is not
repeated but cannot prove the frame budget is met — **is discharged by that run.** Do not
re-add it (rule 12).

**G-41 is half-verified.** Tables are no longer clipped to a stub. They now render
*larger* than their content, filed as **G-42** (`TODOS.md` Backlog), which the USER
called "not too serious". Autoscroll during a live generation was not separately
reported on.

---

## 0k. The per-frame cost assertions (G-40, Step 7c, 2026-09-01 17:51)

**17 assertions added to `attach-selftest`.** They are a different kind from
everything else in this file and the difference is the point.

**What they assert is a count, not an output.** The defect that froze the window
produced *correct output*: the right thumbnail, the right transcript, the right
request. It compiled, every existing assertion passed, and a screenshot looked
perfect. The only observable was that the work was done **again on every frame** —
so what is asserted is `ParseMemo.parses` and `BlockMemo.parses`, the number of
times a payload was parsed. *"A hundred lookups of one message parse it exactly
once"* is the fix stated as an assertion.

**These are the only assertions in this project that can catch a per-frame cost
being reintroduced.** The `parses` counters exist for that and are not to be
removed as debug leftovers.

**Covered:** an attachment carries an identity key; the key is stable across reads
and differs for two files with identical content (**this is the one that
re-creates the original defect when corrupted**); a hundred lookups parse once; a
message with no row id is never memoised, because a streaming turn is a live
buffer; a message whose payload changed *is* re-parsed, because Continue extends a
saved row; the request path keeps the **unreduced** node while the renderable form
drops `AUDIO`, and both come from one parse; an imported audio attachment is still
sent; a file over 25 MB is refused, the refusal names both sizes, and nothing
truncated is returned (**D-BQ**); a file under it is still accepted. Plus four on
`markdown.BlockMemo` in the same shape.

**Three independent corruptions, three clean reds:** the memo disabled (2 red),
the key derived from the payload (1 red — the original defect), the markdown stamp
check removed (1 red — the Continue case, which would have shown a stale
transcript).

**Two real bugs were found by these assertions while they were being written**,
which is the case for writing them: `for i, e in` over a `JArray` resolves to
`pairs`, which asserts the node is an object and aborts the process; and
truncating division reported a 25.001 MB file as *"is 25 MB and the limit is
25 MB"*. The size is rounded up now.

**What is not asserted, and cannot be from here:** that the window is actually
responsive with a document attached. The counters prove the work is not repeated;
they cannot prove the frame budget is met. That is a USER run.

## 0j. Step 7's three self-tests (G-34, G-35, G-30, 2026-09-01 15:46)

**`markdown-selftest` — 17 assertions.** `markdown.nim` renders every assistant
reply and was reachable only from `gui.nim`, so nothing could assert it. It links
here — it imports `std/strutils` and nothing else. Covers: a pipe table becomes a
table block with its header, rows and `:---:` alignment · **a pipe with no
separator row is not a table** · pipes inside a code fence are not a table · a
short row is padded rather than dropped · task lists render ☐/☑ and the raw
brackets are gone · `~~` becomes `<s>` · a code span still suppresses emphasis ·
`<b>` in a cell is escaped, not injected.

**Proven able to fail — three corruptions, three different reds:** any pipe line
counted as a separator (the "no separator" assertion) · alignment markers ignored
(the alignment assertion) · task lists falling through to the bullet branch (two).

**A fourth corruption stayed green and was recorded as a *weak* corruption, not a
hole (rule 16).** Removing the "a separator cell must contain a dash" check changes
no realistic input, because the empty-cell and charset checks already reject them —
the guard is redundant rather than untested. Saying so is the point: rule 16 is
about finding holes, not about logging every corruption that fails to bite.

**`error-selftest` — 15 assertions.** `pipeline.classifyError`. Covers: llama.cpp's
own overflow wording parsed for **both numbers** · **an overflow is not offered a
Retry**, because retrying sends the identical oversized prompt · 502/503 are the
backend not being up, and are retryable · a timeout is a timeout · a refused
connection names the backend · a 500 shows the server's own words · **a non-JSON
body is survived** and falls back to naming the status.

**Three corruptions, three reds:** an overflow marked retryable · the two numbers
no longer extracted (three assertions) · a timeout collapsed into a generic
network failure.

**`attach-selftest` — 27 assertions.** `pipeline.contentFor` and, since 16:19,
`pipeline.readAttachment` / `uriToPath`. Covers: **no
attachments leaves `content` a plain string**, so every request without one is
unchanged · an image becomes an `image_url` part carrying the whole data URL · a
text file is wrapped in the Web UI's own `--- File: name ---` header · **images
before text files, the Web UI's order** · an attachment with no text sends no
empty text part · a legacy `context` attachment is still sent · audio becomes
`input_audio` with the format read from the mime type · a text-extracted PDF
becomes a text part · a malformed `extra` is survived.

**Two clean reds:** images emitted as text parts (four assertions) · the
attachment header changed from the Web UI's (two).

**Twelve more assertions were added at 16:19** with drag-and-drop and paste: the
URI percent-decode (without which most screenshots fail to open, since their
names have spaces), the NUL-byte text test, an unknown extension attaching as
text, **the vision refusal in both directions** — refused on a text-only model
and *allowed* while `/props` has not answered, because refusing on an unknown is
the same defect the other way round — and an unreadable file refused rather than
crashing. **Three further corruptions, three clean reds:** the percent-decode
dropped · text decided by extension instead of content · an unanswered `/props`
refusing images.

**A third corruption crashed rather than going red, and is not claimed as a
pass.** Removing the no-attachments guard reaches a nil dereference before the
assertion runs. It shows the guard is load-bearing; it is not a clean red.

**Plus 5 assertions on `api.cascadeCount` in `tree-selftest`** — a workspace counts
every descendant table, a folder only what is in it, a conversation its messages, a
leaf nothing, and **a soft-deleted row is not counted again**. Corrupting the
`is_deleted=0` filter turns the last one red. G-36's dialog quotes this number, and
a confirmation that under-reports what it will delete is worse than none.

**What none of these reach:** the stop button, the table `Grid`, the attachment
chips, the picker and the confirmation dialog are widgets. `--check` builds the
tree; it does not press anything.

## 0i. `hardware-selftest` — profile scoring (S-1, 2026-09-01 15:13)

**Why it exists:** scoring decides which tuning the machine runs under, and a wrong
score does not fail loudly — it runs the wrong profile, which looks like working
software that is merely slow. The ladder lives in `hardware.scoreProfile`, below the
widget layer, and is asserted against hand-written `Hardware` values with no `sysctl`
call and no window.

**Twelve assertions** *(this said thirteen until 2026-09-02; counted out of the
`hardware-selftest` block, it is twelve — another derivable number that rotted, rule 9).*
Every `profile.conf` parses · two GPUs select
`Vulkan/dgpu-igpu-i5-1135g7` · one GPU does not · **the dual profile scores strictly
below the winner on single-GPU hardware, and strictly above it on dual** · the opt-in
`CUDA/dgpu-generic` is disqualified · unknown hardware falls back to `CPU/generic`
rather than matching nothing · an OS mismatch disqualifies *every* OS-pinned profile ·
apply writes `jenova.conf`, **leaves `jenova.local.conf` untouched**, and the applied
profile is then reported as current.

**Proven able to fail — three corruptions, three different sets of red:**

| Corruption | Result |
|---|---|
| `PtsGpuMissing` −8 → 0 | **PASSED at first.** See below |
| `readProfile` never sets `optIn` | the opt-in assertion goes red alone |
| an OS mismatch scores 0 instead of disqualifying | the OS assertion goes red alone |

**The first corruption passing is the finding, not a failed experiment (rule 16).**
`dgpu-i5-1135g7` and `dgpu-igpu-i5-1135g7` are identical but for `MATCH_GPU_1`, so with
the penalty removed they **tie at 35** on single-GPU hardware — and the right one still
won, purely because it sorts first and Nim's sort is stable. **The assertion was
checking the winner's name when the thing that mattered was the margin.** The strict
inequality was added, and the same corruption then goes red naming the tie.

**What this suite could not see, and did not:** the first real run reported **no GPU at
all**, because `llama-server` needs `LD_LIBRARY_PATH` set to `paths.llamaLibDir` and
`detectGpu` did not set it. An unloadable binary and a GPU-less machine produce the same
empty string. **A unit check over hand-written hardware cannot reach that** — it is the
join to the environment, which is rule 15 again. Fixed and confirmed against the real
machine: both Vulkan devices, score 40.

## 0h. `jenova --check` — does the application start at all? (2026-09-01 14:02)

**Run this before handing over any GUI change.** `BRIEFING.md` rule 17.

```sh
bin/jenova --check     # exit 0 = the application reaches its first frame
```

**Why it exists.** The Theme setting shipped a **100%-reproducible SIGABRT** behind a
clean `nimble gui`: `gui.run` asked libadwaita for the desktop colour scheme while
resolving the startup palette, and `adw.brew` — which calls `adw_init` — had not run
yet, so it reached `gdk_display_manager_get` with no display and GDK aborted the
process in 0.09 s. **A compile cannot see call ordering across an init boundary**
(D-AR), and no self-test can reach `gui.nim` at all, because `pipeline-selftest` links
`jenova-core` and `jenova-core` links no owlkettle. The startup path had *no*
verification of any kind.

**What it does and does not do.** It calls `adw_init`, installs the stylesheet and
**builds the entire widget tree, including every `afterBuild` hook**, then returns
without `runMainloop`. So it exercises everything a launch does up to the first frame —
and **presents no window, starts no backend, binds no port and touches no GPU**, which
is what makes it usable under **D-BJ** where starting the application is not. It needs
a display; it does not need the model.

**It does not replace a screen run.** Exit 0 means the program is *running*, never that
anything on it is *right* — layout, colour and legibility are still only visible to the
USER looking at it (D-AR's other half).

**Proven able to fail.** Reinstating the old `paletteFor` and running `--check`
reproduces the abort exactly: same `Gdk-ERROR` line, exit 134.

**Verified across every input the setting has**, each against a scratch `JCA_HOME` so
the USER's own state is never touched: `theme` of `system`, `light` and `dark`, a
corrupt `settings.json`, and no settings file at all — all exit 0. A static sweep of
`run` confirms no GTK, GDK or libadwaita call remains ahead of `brew`.

## 0a. The coverage gap: nothing tests the GUI — 2026-09-01

**Every suite and every self-test above exercises `jenova-core`.** Routes, database,
filesystem mirror, containment, lifecycle and the argument vector, model discovery and
switching, the Neovim buffer reader. **There is no test of `gui.nim` of any kind** — no
suite, no self-test, no compiled driver.

**Every GUI defect in this project's history was found by the USER looking at the
screen**: the black sidebar slab, the unstyled tree, the unreadable wordmark, the
collapsing code blocks, the five-column panel, the oversized chat bubbles, the
one-way-door fullscreen, notes that could not be created, the crash on quit — and, on
2026-09-01, **an application that aborted before drawing anything at all**.

**That last one was different in kind and is now covered**: it needed no eye, only a
launch, and `jenova --check` (§0h) is that launch without the cost of one. The rest of
this section still stands for everything a screenshot is genuinely required for.

That was survivable while the outstanding GUI work was *layout*, where a screenshot is
the only real test anyway. **It is not survivable for the work now planned**, which is
mostly *logic*: conversation branch trees, message mutation, and parameter plumbing
into the request body.

**What `PLANS.md` requires, per step, and why each is assertable:**

| Step | What must be proven | How, without a window |
|---|---|---|
| **1 — container rename** (T-14) | ~~A renamed project takes its files with it, and a failed move rolls back~~ **DONE 2026-09-01 — see §0b** | Done as planned: `test_api_fs.sh`, +17 assertions |
| **2 — message actions** (G-28) | ~~Edit and delete reach the right rows and cascade correctly~~ **DONE 2026-09-01 — see §0c** | Done as planned: `test_api_db.sh`, +12 assertions. Regenerate and continue remain screen-only |
| **3 — branching** (G-29) | ~~The active path and the sibling counts are right for a known fork shape~~ **DONE 2026-09-01 — see §0d** | Done as planned, and as predicted it was the step needing an assertion rather than a screenshot: `jenova-core tree-selftest`, 26 assertions |
| **4 — chat indexing** (T-17) | ~~A query returns the right message; a conversation-scoped filter confines results; re-indexing a conversation does not duplicate chunks~~ **DONE 2026-09-01 — see §0f** | Done as planned, plus four in `pipeline-selftest` the plan had not asked for: the *wiring*, which is the half that had been invisible |
| **5 — settings** (G-31) | ~~A stored sampling value actually reaches the outbound JSON body~~ **DONE 2026-09-01 — see §0g** | Done as planned, plus fourteen the plan had not asked for — most importantly that an **unset** value is not sent at all |
| **6 — hardware profiles** (S-1) | Known hardware selects the right profile; an opt-in profile never wins automatically; the fallback ladder holds (specific > GPU generic > CPU generic) | A new suite over the profile data. Pure scoring logic, no hardware needed. **Prove it can go red first** — the archived `test_validate_arg.sh` never asserted this and rewrote `etc/jenova.conf` as a side effect |
| **9 — statement cache** (T-2) | The cache stays capped under many distinct queries | A new suite. **Prove it can go red first** |
| **9 — containment** (T-4) | A write through a symlinked parent is refused 403; a legitimate write under a symlinked root succeeds | Extend `test_api_fs.sh`, both directions |
| **9 — history trim** (T-3) | Oldest dropped first, system message never dropped, budget respected | A unit check on the trim function at a small budget |

**The rule this section exists to state:** where a GUI feature's *behaviour* can be
asserted below the widget layer, it must be. Reserve the screen for what only the
screen can show.

## 0b. `tests/test_api_fs.sh` — container renames (T-14, 2026-09-01)

**17 assertions added**, covering what `PLANS.md` Step 1 named and two things it did not.

| Asserted | Why it is the assertion |
|---|---|
| A renamed project's directory moves, and nothing is left at the old path | The defect itself: the row moved and the directory did not |
| The note **and** the file asset are found under the new path | Files are what was being stranded. A directory that moves empty proves nothing |
| The same for a folder rename, and for a workspace rename | Three different resolvers, three different parent chains |
| A renamed workspace keeps its `.git` directory | The workspace *is* a git repository; a rename that loses it loses the history |
| `/api/fs/tree` lists the note at its new path | The Neovim page is the file browser (D-AW), so the tree is the interface the fix exists for |
| A rename onto an occupied directory answers an error, both directories survive intact, and the row is still holding its **old** name | The refusal and the rollback, which are D-BE. This is the assertion most likely to rot |
| Renaming everything back restores the original paths | The move works in both directions, and it leaves the rest of the script reading as written |

**Proven able to fail — the whole point.** Run against the pre-fix source with the new
assertions in place, `test_api_fs.sh` reports **FAIL (12)**, and the twelve are exactly
the positive checks. Some of the absence checks pass vacuously in that run — a
`Delta/Gamma` that never existed is trivially absent — which is why the positive checks
carry the proof and are stated first.

**One assertion was wrong on the first run and the suite caught it**, which is the
cheapest possible demonstration that it bites: it read the row back through
`GET /api/db/projects/<id>`, a route that does not exist. There is no per-id GET on this
surface; the collection listing is the read path. The corrected assertion matches the
whole row, which also pins the column order.

## 0c. `tests/test_api_db.sh` — message actions (G-28, 2026-09-01)

**12 assertions added.** Of the five actions a message now carries, **edit and delete are
pure HTTP and are asserted here; copy is a clipboard call and regenerate and continue are
GUI composition over `gui.send`** — those three are screen-only and are not claimed to be
covered.

| Asserted | Why it is the assertion |
|---|---|
| An edit writes the new text **and leaves `convId`, `role` and `timestamp` alone** | `api.writeRow` is INSERT OR REPLACE over every column, so an edit routed through `putEntity` would blank the rest of the row. The three "keeps" assertions are the ones that would catch that, and they fail for a different reason than the "writes" one — which is why all four are separate |
| An update with no id, and one naming no known column, are both refused | A blank `UPDATE` would report success having written nothing |
| Deleting one message removes it from the listing, **as an explicit negative check** | The action the window's per-message delete performs. A `check` for absence written as a substring match would pass vacuously on an empty response, so this one greps and fails on a hit |
| Its siblings and its conversation survive | Distinguishes a single-turn delete from the conversation cascade asserted further down |
| The deleted message is still in `/deleted` | It is a soft delete, so it must be recoverable — which is what makes the trash view (G-21) possible later |

**Proven able to fail, in both halves separately.** Neutering the `UPDATE` inside the
extracted `api.updateMessage` turns *edit writes the new text* red (and the pre-existing
*partial update writes only given fields* with it), while the three "keeps" assertions
stay green — correctly, since those columns genuinely are not touched. Pointing the
DELETE at a different id turns *deleting one message removes it from the listing* and *a
deleted message is soft-deleted, not gone* red. Two independent corruptions, two
different sets of red, which is the evidence that the assertions are measuring two
different things rather than one.

**Why the update logic moved:** the route body was extracted into `api.updateMessage` and
exported as `patchMessage` so the window's edit and `POST /api/db/messages/update` run
one implementation. Before that the only partial-update code lived inside the HTTP
handler, and the GUI would have needed a second copy — two definitions of one contract,
drifting from the first change.

## 0d. `jenova-core tree-selftest` — the branching tree walk (G-29, 2026-09-01)

**Why this is a self-test and not a suite.** Conversation branching is a tree walk, and a
wrong tree walk **does not fail loudly**: it draws a plausible transcript with the wrong
turns in it, or a "2 of 3" counter off by one. Neither is visible to someone who does not
already know the right answer, which makes it precisely the class of defect a screenshot
cannot catch. So the walk was put in `api.nim` as three pure functions over `(id, parent)`
pairs — `pathTo`, `siblingsIn`, `deepestFrom` — and is asserted here against a fork shape
written out by hand, with no database and no window. `sha256-selftest` is the precedent:
pure logic gets its own subcommand.

**26 assertions.** It began as 15 over one fork shape — a turn regenerated twice, a
conversation continuing under the middle version, an edit of the root turn — and **that
was not enough, which the USER found by running the build.**

**What the first 15 missed, recorded because it is the lesson.** They covered the shape
branching *creates* and never the shape it *inherits*: every message written before
branching has a NULL `parent`, so an existing conversation arrives as a flat set of
roots. `siblingsIn` then reads the whole conversation as versions of one turn, and the
transcript collapses to a single message. **A suite that only tests the shape a feature
produces cannot see the shape it is given.** The eleven added assertions are that gap,
in three layers: the broken behaviour stated explicitly, the migrated behaviour, and the
migration itself.

| Asserted | Why |
|---|---|
| The path to a leaf is root-first and skips the branches not taken | The transcript itself |
| An unknown or empty leaf yields **no** path rather than a partial one | A `currNode` pointing at a deleted turn must fall back, not draw half a conversation |
| Every version of a turn is a sibling, in the order they were made | What the counter counts and what prev/next steps through |
| A turn never branched is its own only sibling | Lets the caller ask unconditionally and draw the control only when there is more than one |
| Root turns are siblings of each other | Editing the first turn of a conversation is the case most likely to be missed |
| Switching to a branch follows it to its **newest** leaf | Picking an older answer must show the conversation that followed *it*, not strand the reader at the switch point |
| A cycle in the parent links, and in the child links, **terminates** | `parent` is data and a row is editable through the API. A cycle must draw a wrong transcript at worst, never hang the window |
| **Unmigrated history makes every message a sibling, and collapses the path to one message** | The defect the USER hit, stated as an assertion so it is a known property rather than a surprise |
| The same turns, once chained, are one path with no version arrows and open on the last turn | What the migration has to produce |
| The migration chains a real table, leaves an already-parented row alone, skips soft-deleted rows, and **changes nothing on a second run** | It runs on every `initDb`, so idempotency is not optional |

**Proven able to fail, three independent corruptions.** Removing the `reverse` in `pathTo`
turns *the path to a leaf is root-first* red; taking the first child instead of the last
in `deepestFrom` turns *the newest branch is the one followed from the root* red; and
making `migrateMessageParents` return immediately turns *the oldest turn stays the root*,
*each later turn is chained to the one before it* and *migrating twice changes nothing*
red. Each corruption is caught by its own assertions and no others.

**Also verified end to end, not only synthetically:** a copy of the USER's live database
was run through `jenova-core db-init` and its four NULL-parent messages came out correctly
chained. The original was not touched.

## 0e. `pipeline-selftest` — request keys survive the rewrite (G-33, G-39, 2026-09-01)

Three assertions, and they guard a silent failure. The window asks for its statistics and
its reasoning split by putting `timings_per_token` and `reasoning_format` in the request
body, and **`llama-server` sends neither unless asked**. `pipeline.prepare` rewrites that
body. If it ever dropped keys it did not recognise, both features would go quietly dead
with every other test in the project still green — no error, no log line, just numbers
that never appear.

**Now ten assertions, in two groups.**

**Four on the pass-through:** unknown top-level keys survive `prepare` with their values
intact. Sampling parameters travel the same path, so `temperature` is asserted alongside
them — Step 5 depends on the same property. **Proven able to fail** by a one-line
`req.delete("timings_per_token")` in `prepare`.

**Six on the outbound body, and these exist because their absence let Continue ship broken
twice.** The window's request body used to be built inside `gui.nim`, where no self-test
could reach it — so a body the server *refuses outright* looked identical to a correct one
from every angle except running the program. It now lives in `pipeline.chatBody`.

| Asserted | Why |
|---|---|
| An ordinary turn asks for live timings and for reasoning to be split out | The two features depend on the server being asked |
| An ordinary turn does **not** ask to continue anything | Sending the continuation fields on every turn would change what the model does |
| A continuation names what it is continuing (`"content"`) | Not `true`, and never `reasoning_content` — the visible answer is what is resumed |
| **A continuation turns the generation prompt OFF** | The half that was missing. Without it `llama-server` answers **HTTP 400** — *"Cannot set both add_generation_prompt and continue_final_message to true"* — so Continue failed outright rather than merely behaving oddly |
| A continuation still ends on the assistant turn being extended | The fields are meaningless without the partial reply as the tail |

**Proven able to fail:** dropping the `add_generation_prompt` line turns *a continuation
turns the generation prompt OFF* red and nothing else.

**Also verified against a running server, which is what the earlier attempt skipped:**
`"1, 2,"` continues to `"1, 2, 3, 4, 5"` — non-streaming returns the whole message,
streaming emits only the new tokens. The window streams, so appending is correct.

## 5i. `tests/test_nvimctl.sh` — the live editor buffer (G-18, 2026-08-31)

Covers `src/jenova/nvimctl.nim`. No `jenova-core` subcommand exists behind it, so the script owns the
editor's lifecycle and `tests/nvimctl_check.nim` owns the assertions.

**Why the assertions are what they are.** `nvimctl` does not fail by crashing. It fails by returning
the file **on disk** instead of the **buffer** — which looks correct in every test where nothing has
been edited, and is precisely wrong for the feature, whose purpose is reading unsaved work. So the
same 13 assertions run twice: once clean, then again after `setline(2,…)` edits the buffer **without
saving**. The script also asserts the edit never reached the file.

**Proven able to fail:** on the dirty pass the buffer-text and `modified` checks were observed going
red and the driver exiting 1, while `cat` showed the file unchanged. That is simultaneously the
proof the assertions bite and the proof of the feature's core claim.

**Measured, not assumed:** `nvim --listen` rejects a socket path near **104 bytes** — FreeBSD's
`sun_path` limit. The suite uses `/tmp/jenova-test-nvim.$$.sock`; the product uses
`$HOME/Jenova/state/`. A path under a deep scratch directory fails with
`Failed to --listen: invalid argument`.

**Run 2026-08-31: 5 passed, 0 failed.**

## 0f. Chat indexing — the index is fed, and the feed reaches the model (T-17, 2026-09-01)

**Fourteen assertions across two self-tests**, and the split between them is the point.
`rag-selftest` proves the index is *fed correctly*; `pipeline-selftest` proves the feed
*arrives*. Those are different failures, and this project has already shipped the second
one: `serve` once failed to call `rag.initSchema()` and every suite stayed green while
`/v1/chat/completions` answered 500.

**Why this needed testing at all.** Retrieval was finished and proven — ranking,
filtering, snippets, the float32 round-trip, the similarity maths — and it had never
been used, because `indexContent` had no caller outside its own self-test. **A module
can be fully asserted and completely dead.** Nothing in the suite could tell the
difference, because every assertion supplied its own corpus.

### Ten in `rag-selftest`

| Asserted | Why it is the assertion |
|---|---|
| An exchange indexes **two** rows — the reply and the turn it answers | The unit is an exchange, not a message. Indexing a question when it is saved puts it in the index before its own request is answered, and the model is handed back the question it just asked |
| A query returns the **exact message** that answered it | On wording that appears in the reply and nowhere else, so the hit is a path and not a conversation |
| A conversation filter confines recall, asserted **in both directions** | A filter returning nothing at all also leaks nothing. So: the other conversation is reachable unfiltered, *and* absent when filtered |
| Re-indexing does not duplicate chunks or documents | The path is stable per row and `indexContent` forgets before writing. Together that is what stops every turn adding another copy of itself |
| A deleted message is forgotten and no longer retrievable | Otherwise the deletion is honoured everywhere except in what the model remembers |
| The backfill indexes history that was never indexed | The feature working on chats that already exist, which is the whole of D-BD's third clause |
| The backfill **skips** what is already indexed | Run at every start; a non-incremental one would re-embed the entire history each launch |
| A message indexed **without vectors is retried** later | The self-healing half. Indexed while the embedder was down, it would otherwise stay semantically invisible for ever |
| Deleting a conversation clears its whole index scope | Its messages are flagged in one statement, so there is no per-row site to hook |
| An empty turn is not indexed | A reply that is pure reasoning has nothing to retrieve *by*, and would put an empty body in the keyword index |

**Both halves of the backfill are proven with no embedding server running**, by storing
vectors against the chat chunks directly — the same technique the vector block already
uses for the BLOB path. **The rule under test is the skip, not the embedder.** Gating it
on a live server is how an assertion ends up running in one mode and silently skipped in
the other.

**One assertion of mine was wrong on its first run and the suite caught it**, which is
the cheapest possible demonstration that it bites. It gated the incremental check on
`rag.chunkCount() > 0` — a count of vector-bearing chunks **across the whole index**,
which the vectors block above populates by hand. It therefore reported a live embedder
where there was none. **That is the exact mistake already recorded on the chunk-count
assertion in §0, inverted:** written for one mode and mistaking it for the only one.

### Four in `pipeline-selftest` — the wiring

| Asserted | Why |
|---|---|
| A chat message reaches the index | Separates a broken feed from broken wiring, which is what makes the next three diagnostic |
| An indexed turn is **retrieved** on a later turn (`ragHits > 0`) | `prepare` already queried the index on every turn and always got nothing; this is the first assertion that it now gets something |
| The recalled text is **in the body sent to the model** | Retrieved and then dropped is indistinguishable from never retrieved, from every angle except reading the outbound body |
| The recalled turn is attributed to the chat it came from | The path is printed above the snippet, so the model is told this is a past conversation and which one |

**Proven able to fail, four independent corruptions, four different sets of red.**
Limiting `indexExchange` to one row turns *an exchange indexes the reply and the question
it answers* red **alone**. Making `forgetMessage` a no-op turns *a deleted message is
forgotten* red **alone**. Dropping the vector condition from the backfill's skip query
turns *a message indexed without vectors is retried later* red **alone**. And returning 0
from `ragLimitFor` — the wiring corruption — leaves *a chat message reaches the index*
**green** while turning the other three red, which is the evidence that the two groups
measure genuinely different things.

## 0g. `pipeline-selftest` — settings reach the model (G-31, G-32, 2026-09-01)

**Fifteen assertions**, all in `pipeline-selftest`, because the sampling parameters are
only ever a JSON field on the outbound body. That is why `settings.applyTo` and the merge
live below the widget layer: **the entire feature is provable with no window, no backend
and no generation.**

| Asserted | Why it is the assertion |
|---|---|
| An **unset** parameter is not sent at all | The one that matters most and reads as the least interesting. Sending a defaulted 0.0 for every untouched field would silently override the server's own preset on every request — and would look exactly like a working settings screen |
| An unset **boolean** is not sent either | An unasked-for `false` is still an override. A bool is never "empty", so this needed its own rule and therefore its own check |
| A stored temperature reaches the outbound body | What `PLANS.md` Step 5 named as the proof |
| An integer is sent as a **number, not a string** | `"40"` as a JSON string is ignored by `llama-server`, which on screen is indistinguishable from a setting that does nothing. The *kind* is the assertion |
| A penalty reaches the body by the same path | A different section over one merge — proves the mechanism, not one field |
| Merging does not disturb the fields already there | `stream` and `timings_per_token` are what the statistics and the stream itself depend on |
| The Developer switch turns reasoning parsing off | `reasoning_format` is computed rather than constant now, so it can be got wrong |
| Custom JSON adds a parameter this build does not name | The escape hatch working |
| Custom JSON overrides a **named** field | It is merged last, deliberately |
| Custom JSON overrides a field **the body sets itself** | **This one exists because it was missing** — see below |
| Settings do not clobber the continuation flags | Continue shipped broken twice (D-BH). A later feature quietly overwriting its two fields would be the third |
| A non-numeric parameter is refused **before** it is stored | At merge time it would be silently dropped on the way to the model, which is indistinguishable from a parameter the server ignored |
| Malformed custom JSON is refused before it is stored | Same reason, different failure |
| A well-formed set validates | A validator that refuses everything also passes both checks above |
| Settings survive a save and load | Against a **scratch file**, never `p.state / "settings.json"` — a self-test that overwrote the USER's own settings would be a defect of its own |

**Proven able to fail, four independent corruptions, four different sets of red.**
Sending an unset float as 0.0 turns *an unset sampling parameter is not sent at all* red
**alone**, leaving *a stored temperature reaches the outbound body* green — the two are
measuring different things. Serialising an integer as a string turns the kind check red
**alone**. Neutering `validate` turns exactly the **two** refusal checks red and nothing
else.

**The fourth corruption passed, and that is the most useful result here.** Moving the
merge *above* the fixed fields — so `custom` could no longer reach `reasoning_format` or
`stream` — broke a behaviour the module's own header claims, and **every assertion still
went green**. The hole was in the assertion set, not the code. *Custom JSON overrides a
field the body sets itself* was written in response and turns that corruption red. This
is the third session running in which the act of proving an assertion can fail found
something the assertion did not cover; the pattern is worth keeping.

### The parity half — ten more, added 2026-09-01 13:52 (D-BL)

**"1:1 with the Web UI" is exactly the kind of claim that is true the day it is written
and quietly false a month later**, so it is asserted rather than stated: `jca_web`'s
`ChatSettings.svelte` `settingSections` key list is in the self-test.

| Asserted | Why it is the assertion |
|---|---|
| Every Web UI settings field is present | The parity claim itself. A field dropped or renamed later goes red **and names itself** |
| And none the Web UI does not have | The other direction. A one-way check passes on a panel that has drifted by addition |
| The three exclusions are recorded | API Key, MCP and `serverUrl` are deliberate (D-BL). Recorded, so the difference is never re-read as an oversight |
| `typ_p` is looked up in `/props` as `typical_p` | **The defect the USER's report exposed.** One name mismatch, one permanently blank placeholder, and every other field working — which is a bug a screenshot does not show |
| And it is the only field whose `/props` name differs | Pins the exception. A second mismatch introduced later is caught rather than silently blank |
| Every numeric parameter has a built-in default to show | The ghost text. Without it a box is blank until the backend answers, which is what the USER saw |
| Every field explains itself at more than a clause | The Web UI's own help is reference text — "Keeps only k top tokens" — and the USER asked for guidance. A length floor is crude but it is the part a machine can check |
| Only the attachment and audio fields are marked pending | The marker must track reality. A field marked pending after its feature lands is as misleading as one that is silently dead |
| The theme select defaults to one of its own options | A select whose stored default is not in its list opens on nothing |
| Theme is not sent to the model | It is a window concern. `applyTo` iterates every field, so a select leaking into the request body is one missing `discard` away |

**Proven able to fail, three independent corruptions, three different sets of red.**
Removing `showRawModelNames` from the field list turns *every Web UI settings field is
present* red **alone**. Reverting the `typ_p` mapping turns its own check red **alone** —
that is the actual reported bug, re-created and caught. Stripping `dry_base`'s built-in
default turns the ghost-text check red **alone**.

**Not proven, and stated as such:** no reply has been streamed through this with a live
`llama-server` and a live embedding server. Everything above runs with the embedder down.
What that leaves unseen is the semantic half of ranking on real embeddings — the keyword
half, the feed, the filter, the forget and the injection are all asserted. **This is not a
gap to go and close**: bringing the backends up to prove it is exactly what D-BJ and D-AG
forbid. It is observed when the USER next runs the application, or not at all.

## 1. Standing rule

The editing environment is a Linux container on a FreeBSD host (the Linuxulator). **Nothing run
there is evidence for FreeBSD behaviour.** Static checks (`sh -n`, `luajit -bl`) and pure-logic
scripts are the exception: they test the text, not the kernel. Anything touching sysctls,
`/proc`, procstat, GPU or the network stack must be run natively before it counts.

## 5a. Plan B stage acceptance

### N-S0 — build proof

1. `make core` exits 0 and writes `bin/jenova-core`; `file` reports an **ELF 64-bit FreeBSD**
   executable.
2. `./bin/jenova-core` runs and exits 0.
3. **The FreeBSD guard must fire, not merely exist.** `nim c --os:linux src/jenova_core.nim`
   must fail with the `{.error.}` message. Run this on every change to the guard — C-9 records a
   guard that passed static checking while doing nothing.

### N-S1 — configuration precedence

The regression that matters is B-12. Compare the two resolution paths directly:

```sh
# Shell path — reproduces bin/jenova-ca:44-48 (local conf sourced BEFORE profile)
sh -c 'JENOVA_ROOT="$PWD"; export JENOVA_ROOT; \
  . ./lib/detect-env.sh; . ./lib/jenova-conf.sh; \
  . ./lib/jenova-model.sh; . ./etc/jenova.conf; \
  echo "THREADS=$THREADS DEVICES=$DEVICES FIT_TARGET=$FIT_TARGET"'

# Nim core — corrected order
./bin/jenova-core config | grep -E '^(THREADS|DEVICES|FIT_TARGET)='
```

**Expected while `etc/jenova.local.conf` declares 8 / three devices / 768:** the shell prints the
*profile* values (4, two devices, 512) and the Nim core prints the *local conf* values. They are
**supposed to differ** until N-S6 deletes `bin/jenova-ca`; identical output before then means the
Nim core has regressed to the inverted order.

Environment precedence: `JENOVA_THREADS=16 ./bin/jenova-core config` must report `THREADS=16`,
beating both files.

**Recorded result, 2026-08-28:** all three checks pass. Shell 4 / `Vulkan0,Vulkan1` / 512; Nim
8 / `Vulkan0,Vulkan1,Vulkan2` / 768; env override 16.

### N-S2 — database concurrency

`./bin/jenova-core db-selftest` — a writer thread and four reader threads against one database.

**What it asserts, and why each matters:**

| Check | Why it is the right check |
|---|---|
| `sqlite3_threadsafe()` != 0 | A single-threaded SQLite build would make the whole design unsound. `initDb` refuses to run against one |
| `journal_mode` = `wal` | Without WAL a writer blocks every reader, reintroducing serialization |
| Distinct connection handle per thread | Structural proof the layer is per-thread, not one shared handle behind a lock |
| **Reader/writer time-window overlap > 0** | **The load-bearing measurement.** Completion proves nothing — serialized work completes too. Only overlap shows the threads ran *at the same time* |

**Recorded result, 2026-08-28:** PASS. 2000 operations across 5 threads in 15.8 ms; each reader
100% concurrent with the writer; five distinct handles.

**A passing self-test does not mean the system is concurrent.** It covers this layer alone. The
system-level property is decided at N-S3, where the async loop must dispatch blocking work to
worker threads rather than calling it inline (C-13). A future regression test for that belongs
with N-S3, not here.

### N-S3 — the server must not serialize

`./bin/jenova-core serve-selftest`. **This is the regression test for the defect that motivated
the whole rewrite**, so it is worth being precise about why it is built the way it is.

It opens an SSE stream and records the gap between consecutive events — **twice**: once with the
server idle, then again while four other connections sit inside real 400,000-row recursive CTEs
in SQLite. The stream is opened *before* the load starts, so it owns its worker; the property
under test is that established streams are not stalled by blocking work elsewhere.

| Why each choice | |
|---|---|
| **Maximum** gap, not average | An average hides a single long freeze, and a single long freeze *is* the defect |
| **Two phases, compared** | One passing run says nothing about whether load matters. The comparison is the evidence |
| **Real SQL, not `sleep`** | A sleep would not exercise the database path that stalled the Lua proxy |
| Budget = 2.5× the send interval | A serialization defect shows as *multiples* of the interval, not milliseconds over it |

**Phase 3 — a saturated class must not take the server down.** Added 2026-08-28 under D-U. Over-
subscribe the debug class 3:1 with 800 ms holds, then time `/health` and `/`. This is the property
a single shared pool fails *even when nothing blocks*: completion streams are long-lived by
design, so enough of them occupy every worker and the server goes dark. **A server can pass phases
1 and 2 and still fail this one.**

**Recorded results, 2026-08-28:** PASS all three. Idle max gap 40.1 ms against a 40 ms interval;
under load 40.1 ms with 38 slow queries overlapping the stream; `/health` 0.2 ms and `/` 0.2 ms
while the debug class was saturated.

> **A test that silently stopped testing — worth remembering.** When the class table was resized
> under D-T, phase 2 kept passing but reported 4 slow queries where it had reported 41.
> `/debug/stream` and `/debug/slow-query` had both landed in the now-1-thread debug class, so the
> "load" queued *behind* the stream rather than overlapping it. The assertion still passed, and it
> was measuring nothing. The load endpoint moved to the api class. **A passing concurrency test
> whose overlap count collapses is not passing — check the work actually happened concurrently.**

**Also verified by raw socket** — deliberately not with `fetch`, which normalises `..` out of the
URL client-side and would have made the traversal check meaningless:

```
GET /../etc/jenova.conf   -> 403 Forbidden
GET /../../etc/jenova.conf-> 403 Forbidden
GET /nope.js              -> 404 Not Found
GET /                     -> 200 OK   (public/index.html)
POST /                    -> 405 Method Not Allowed
GET /debug/slow-query     -> 404 under `serve` (gated; enabled only for the self-test)
```

### N-S3b — the `/api/db/*` contract

`sh tests/test_api_db.sh` — 22 assertions, wired into `tests/Makefile check`. Starts its own
`jenova-core` on a scratch database and stops it on exit.

**Every assertion encodes something `lib/proxy.lua` does**, not something that merely seems
reasonable. `jca_web` is a shipped client that must keep working unchanged while it is deprecated
(D-L), so "sensible" is not the standard — "identical" is.

The three that exist because a first implementation got them wrong, all found by reading `db.lua`
rather than inferring from the route list:

| Assertion | The behaviour it pins |
|---|---|
| `child deleted without forks reparents grandchild` | Children are moved onto the deleted node's own parent, not orphaned (`db.lua:369`) |
| `deleteWithForks removes nested descendants` | The fork walk is recursive, not one level deep (`db.lua:341-360`) |
| `restoring a note revives its workspace` / `its project` | Restore cascades *upward*; without it a restored item sits inside a deleted container and never appears (`db.lua:905-917`) |

Also pinned: integer columns stay JSON numbers rather than strings, partial updates touch only
the fields supplied, soft deletes populate the trash listing, and import runs transactionally.

**Recorded result, 2026-08-28:** PASS, 22/22.

> **A wrong assertion, corrected rather than accommodated.** The workspace-cascade check first
> asserted `projects/all` was empty, but a *different* workspace's project was legitimately still
> alive — the cascade was right and the test was wrong. Rewritten to check the specific row. An
> assertion that only passes because unrelated state happens to be empty is not a test.

### N-S4 — in-process inference

**`./bin/jenova-core llama-selftest [prompt]`** loads the model from config and generates,
bypassing the server. Use it to separate a model/backend problem from a serving problem.

**Recorded result, 2026-08-28** at the full deployed configuration — `devices=Vulkan0,Vulkan1`,
`ctx=32768`, `slots=2`, `kv=q8_0`, `ngl=-1`, `threads=8`: loads (Vulkan0 152.85 MiB, Vulkan1
381.11 MiB) and generates 48 tokens.

**Serving, and the property that matters.** With `serve` running, issue a long generation and time
other classes *while it runs*:

```sh
# long generation in the background
printf 'POST /completion ... {"prompt":"...","max_tokens":180}' | nc 127.0.0.1 $PORT &
# then, concurrently:
GET /health            GET /api/db/workspaces            GET /
```

**Recorded result, 2026-08-28:** `/health` 3–4 ms, `/api/db/workspaces` 6 ms, `/` 3 ms, while the
generation ran to all 180 tokens. **This is precisely the scenario in which `proxy.lua` froze
every other client.** Warm the model with a one-token request first, or the timing measures model
loading rather than serving.

Streaming shape: `POST /v1/chat/completions` with `"stream":true` returns
`Content-Type: text/event-stream` and `chat.completion.chunk` records terminated by
`data: [DONE]`.

> **Not covered by any test yet:** sampling parameters are ignored (N-25) and client disconnect
> does not cancel a generation (N-26). Neither should be assumed working because these checks pass.

## 5g. `tests/test_lifecycle.sh` — the backend argument vector and lifecycle flags (N-S6)

**31 assertions, PASS.**

**The `--lan` assertions are the load-bearing ones and go both ways:** that the client port moves to
`0.0.0.0`, *and* that neither backend does. Backends bind loopback unconditionally — publishing them
would put two unauthenticated inference endpoints on the network (S-0, D-E,
`jenova-ca:568-575`). A one-directional assertion would pass on a build that published everything.

Also pinned: the three port overrides reach the right places; **an unknown `serve` flag is refused
rather than ignored** — silently swallowing a typo is how a run does the wrong thing while looking
correct; and **`backends health` fails when nothing is listening**, because health is not liveness.
A wedged `llama-server` keeps its pid and stops serving, so a pid check calls it healthy. That is
what the watchdog acts on. It does not start `llama-server` — that needs a model, and the models live
under `~/JCA`, which D-AE places permanently out of bounds. It asserts the **command line**, via
`jenova-core backends args`, which prints it without starting anything.

**Why the argument vector is worth a test at all:** under D-AF `llama-server` is the engine, so
these flags *are* the tuning. They are the accumulated result of work against real hardware, and a
silently dropped or reordered one changes generation behaviour without failing anything. Pinned:
`--spm-infill` (the USER's Neovim FIM), `--cache-prompt`, `--offline`, `-cb`, `-fa auto`,
`-sm layer`, loopback binding and ports for both backends, and the embed server's `-ngl 0 -dev none`
— CPU by design so it cannot compete for VRAM with the agent model.

**The branch most easily conflated is asserted in both directions:** `NGL_AGENT=all` must use
`-fitt` and must *not* pass `-ngl`; an explicit count must pass `-ngl N` and must *not* pass
`-fitt`. The two conflict, and passing both is how a single-GPU profile ends up mis-offloaded.

**Refusal paths too:** `start` with no model exits non-zero and names the reason, `stop` is
idempotent, `status` reports each backend separately rather than collapsing to one word — because
"agent up, embeddings down" is a real state, and hiding it is how B-14 stayed invisible.

## 5h. `tests/test_models.sh` — discovery and switching (N-36, N-37, 2026-08-31)

**15 assertions, PASS.** Guards the total-conversion gate: `models.nim` replaced
`lib/jenova-model.sh` and `bin/jenova-model-switch`, the last two shell scripts the running product
relied on.

**A reimplementation of a file-scanning helper does not fail by crashing — it fails by picking a
different plausible file.** Every assertion pins one of those failure modes rather than a happy
path: the agent model is created *out of collation order* so a missing sort would be caught;
`.old` backups must not be discovered as active; the agent falls back to a flat `models/` directory
and draft and embed **must not**, because giving them a fallback the shell never had would start
passing `-m`/`-md` paths where the original left them empty; and the switch's symlink target must be
**relative**, since an absolute one works until the tree is deployed and then points outside it.

**Equivalence was established against the originals before they were archived, not after.** Both
implementations ran against the same scratch trees and their outputs were compared — four discovery
cases, and a switch compared down to the resulting `models/agent` link targets. Identical in every
case.

> **A negative control, because this project has twice shipped a suite that could not fail.**
> `test_routes.sh` once called `pass`/`fail` helpers it did not have and reported PASS while the
> shell printed "command not found"; `test_api_fs.sh` once reported `ok` on eight absence checks
> while the server was on the wrong port. So this suite was **verified to fail**: corrupting only
> what the assertions *read* turns 4 of the 15 red and the suite exits non-zero. **Adding a suite
> now includes proving it can go red.**

## 5f. `sha256-selftest` and `pipeline-selftest` — the completion pipeline (N-S5c, 2026-08-31)

**`sha256-selftest`: 4 assertions, PASS.** The published FIPS 180-4 vectors — empty string, `"abc"`,
the 56-byte two-block message, and one million `a` characters. **The last one is the point:** it
exercises the block loop and the 64-bit length encoding, where a single-pass test would not. A
hand-written hash fails by producing plausible wrong digests rather than by crashing, so published
vectors are the only honest check.

**`pipeline-selftest`: 15 assertions, PASS.** Intent detection and prefix stripping; visual intent
stripping tools and setting `tool_choice: none`; agent mode never overriding a client system prompt
and injecting the CORE MANDATE only when none exists; the freechat fallback; cache key stability;
**the key being the SHA-256 of the rewritten body and not the original**; cache round-trip;
non-chat bodies passing through untouched; and a message already carrying a context marker not
being re-retrieved.

> **Wiring is not proven by unit checks.** `serve` never called `rag.initSchema()`, so the first
> chat request hit a missing table and answered **500 instead of reaching the upstream** — while
> `pipeline-selftest` stayed green throughout, because it calls `initSchema` itself.
> `tests/test_routes.sh` now posts a real chat body and asserts **502**: 502 means the pipeline
> completed and `llama-server` is merely absent, 500 means it threw. **The distinction is the
> assertion.**

> **A vacuous pass, caught immediately — the second this session.** Those new route assertions
> called `pass`/`fail` helpers that existed in `test_api_fs.sh` and not in `test_routes.sh`. The
> shell printed "command not found" to stderr and the suite still reported PASS, because `FAILED`
> was never incremented. **A test that cannot fail reports success just as loudly as one that
> passes.**

## 5e. `jenova-core rag-selftest` — retrieval (N-S5b, 2026-08-31)

**7 assertions, PASS.** Indexes a three-document scratch corpus, then asserts a keyword hit ranks
the right file, that a snippet survives storage (**the property `search.lua` lost on every
restart**), and that a path filter confines results.

**The vector half is asserted without an embedding server, deliberately.** Endianness, the BLOB
round-trip and the dot product are where a silent error would live, and waiting for a server to be
running to find out is how unverified logic ships. `rag.nim` exposes `vectorRoundTrip`,
`similarity` and `storeChunkVector` so the test can pin them directly: a float32 vector survives
byte-exact, identical vectors score 1.0, orthogonal score 0.0, and a stored vector reads back
through the same `queryBlob` path the query itself uses.

**`chunks with vectors: 0` in the output is not a failure** — it is the embedding server being
absent, and keyword-only retrieval is a supported degraded mode that `search.lua` had too.

**What this does NOT cover, recorded as N-31:** the HTTP request and response shape against a live
embedding server on :8082. That is the one part of the semantic path still unproven.

**`jenova-core db-capabilities`** reports what the linked libsqlite3 can actually do —
threadsafety, journal mode and FTS5 — because Q-24's index choice was contingent on a fact that had
been assumed rather than checked (D-AB). Result on this host: `fts5: available`.

## 5d. The route inventory — **now a test**, `tests/test_routes.sh` (2026-08-31)

**9 assertions, PASS.** Wired into `tests/Makefile check`. Runs in a scratch `JCA_HOME` (D-AE).

**Reading the statuses correctly matters here.** A **502** on `/v1/chat/completions`, `/completion`
and `/infill` is the **pass** condition under D-AF: it proves the request was classified and reached
`upstream.forward`, which then found no `llama-server` listening. **A 404 or 405 would mean the
route was never classified at all** — which is precisely what `/infill` returned before N-S4c. The
test asserts 502, not "not an error", for exactly that reason.

The prose below explains why the check exists and how to extend it when a new surface is claimed.

### Why it exists

**Any stage claiming to reproduce a surface must diff its routes against the running binary before
the claim is made.** N-29 exists because that was never done: the audit enumerated the route
families it noticed, `/api/storage/*` was not among them, and N-S5a was recorded complete with five
routes unserved.

The check is one loop and takes seconds:

```sh
probe() { printf '%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" "$2" \
          | nc 127.0.0.1 "$PORT" | head -1; }
```

Enumerate the source's routes first — for `lib/proxy.lua`,
`grep -oE '"\^(GET|POST|DELETE|PUT|\[A-Z\]\+) /[a-zA-Z0-9/_%.-]*'` plus the `find("…")` matches,
since it uses both forms — then probe every one. **A 404 or 405 on a route the original serves is
the finding.** Reading the handler list is not a substitute; that is what produced the false claim.

## 5c. `tests/test_api_fs.sh` — the filesystem contract (N-S5a, 2026-08-31)

**46 assertions, PASS** (31 at N-S5a, 15 more for `/api/storage/*`). Covers what §5b said was
missing: physical path layout, the git repo per
workspace, base64 `data:` decoding, rename-then-trash-the-old-path, the `<epoch>_<name>` trash
naming, the `.metadata.json` sidecar, all four `/api/fs/*` routes, per-entity delete ordering, and
that bulk import does *not* mirror.

**Both API suites now run inside a `mktemp` `JCA_HOME` and delete only a directory matching their
own prefix.** This is not hygiene — `test_api_db.sh` previously derived its database path as
`"${JCA_HOME:-$HOME/JCA}/.system/jenova.db"` and `rm -f`'d it, **so `make check` deleted the live
conversation database on any machine with a real deployment.**

> **A vacuous run, caught before it was believed.** The first execution reported `ok` on eight
> checks while the server was listening on a different port — every one an absence check, and an
> absence check passes when the entire system is unreachable. **A `/health` liveness gate now runs
> before any assertion.** Same lesson as the N-S3 phase-2 overlap collapse: an assertion that
> cannot fail is not evidence.

> **An over-strict assertion, corrected rather than accommodated.** It pinned the sidecar's byte
> spacing — `fs_sync.lua` writes `{"type": "notes", …}`, the Nim core emits compact JSON. Only
> those two components read the file and both parse it as JSON, so the formats are interchangeable
> in both directions. **The fields are the contract; the spacing is incidental.**

**The `/api/storage/*` assertions are about containment, because that is the risk.** These four
routes take a client-supplied path and read, write and delete with it. Asserted: three traversal
forms all refused with **403 and not 404** (a 404 would disclose whether a path outside the root
exists), an absent file inside the root answering 404, the trash preserving the original relative
path, and — after a defect of mine — **a stored file beginning with `[` being served as its own
content rather than mistaken for the JSON listing.** The first wiring picked the content type with
`not body.startsWith("[")`; `ApiResult` now carries `contentType` explicitly.

**And a fidelity finding that only appeared because the port broke an existing test.**
`test_api_db.sh`'s restore-cascade assertions began failing. Not a regression: **`fs_sync.lua:70`
refuses to mirror a row whose `id` is not a UUID, and `proxy.lua:899` deletes the row and answers
500.** The test used `"n2"`, and had passed only because `api.nim` had no mirroring to reject it —
**the test was encoding the gap rather than the contract.** Real UUIDs now, plus an assertion
pinning the rejection.

## 5b. N-27 — the dimension the contract test did not cover *(CLOSED 2026-08-31 by §5c)*

Recorded 2026-08-31. **`test_api_db.sh` passes 22/22 and is not wrong. It is incomplete.**

`lib/proxy.lua` calls `fs_sync` at **ten sites inside the `/api/db/*` routes** —
`sync_workspace`, `sync_note`, `sync_fileAsset`, `trash_workspace`, `trash_project`,
`trash_folder`, `trash_note`, `trash_fileAsset` — so creating a workspace makes a directory and
deleting a note moves the file into a trash tree. `src/jenova/api.nim` performs none of it.

**Why no assertion caught it:** all 22 issue HTTP requests and inspect the JSON that comes back.
The filesystem is never examined, so the suite has no assertion that *could* fail on this. It is
C-9's lesson in a new place — **a check that cannot fail in a dimension is not evidence about that
dimension**, and a green suite says nothing about what it does not look at.

**Required of the N-S5a acceptance test**, so this cannot recur:

| Assertion | Why |
|---|---|
| Creating a workspace/project/folder through `/api/db/*` **creates the directory on disk** | The mirroring contract, in the dimension the current suite omits |
| Deleting a note **moves the file into the trash tree**, and `GET /api/fs/trash` lists it | Pins delete-side mirroring and the `/api/fs/*` port together |
| `POST /api/fs/trash/restore` **returns the file to its original path** | Restore is the half most likely to be quietly wrong |
| `GET /api/fs/tree` matches the real directory contents | The route N-20 must reproduce |
| **Run against the existing `proxy.lua` first, then the Nim core, and compare** | "Identical, not sensible" — `jca_web` is frozen under D-Z and must keep working unchanged |

## 6. What has actually been verified, and how

**Live on FreeBSD 15.1 (Session 001):** `sh -n` across 53 shell scripts · `luajit -bl` on every
Lua file · `ffi_defs` loading with FreeBSD constants and a 16-byte `sockaddr_in` ·
`test_ffi_flags.lua` 5/5 · `jenova-model-switch` 6/6 including filenames containing spaces ·
environment detection · profile selection across the full ladder · CUDA opt-in exclusion ·
zero bash · zero `IS_LINUX`.

**By source reading (Session 003), not execution:** remediation-plan Phase 1 — non-variadic
`fcntl`/`open`/`ioctl` with a FreeBSD load guard, `set_cloexec` on accepted sockets,
`fd_set_new()`, the `stalled` flag, the drained accept loop, backlog 128.

**Session 004:** `sh -n scripts/cleanup.sh` clean, plus an end-to-end run of
`cleanup.sh --logs --cache --state` answering `n` at the prompt, confirming all three paths
resolve under `$JCA_HOME` (`var/log`, `var/cache`, `.system`) and that nothing outside it is
targeted. Nothing was deleted.

**Not verified by anyone yet:** a full build, an install, a live daemon start, and the complete
`proxy-concurrency` harness on native FreeBSD.
