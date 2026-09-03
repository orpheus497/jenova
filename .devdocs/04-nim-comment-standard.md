# Report 04 — The Nim comment standard: audit and cleanup plan

**Status:** analysis complete, **no source changed** — this is the plan you asked for
**Scope:** `src/**/*.nim`, `tests/**/*.nim` — **37 files, 21,874 lines**. Nothing else.
Explicitly out of scope: `jca_web/`, `jvim/`, `bin/`, `etc/`, `hardware-profiles/`,
`external/`, `docs/`, `README.md`.
**Measured at commit:** `c8fb564` on `claude/gui-webui-parity-audit-avmj8w`. The branch is under
active concurrent development, so these are a point-in-time census, not a constant. Regenerate the
whole worksheet with:

```sh
for f in $(find src tests -name '*.nim' | sort); do
  printf '%s %d %d %d\n' "$f" "$(wc -l <"$f")" "$(grep -cE '^[[:space:]]*#' "$f")" \
    "$(grep -ohE '\b[A-Z]{1,4}-[A-Z0-9]{1,3}\b' "$f" | grep -vE 'SHA-256|SHA-1|UTF-8|PDF-1' | wc -l)"
done
```

The conclusions do not move with a few dozen lines; the batch table below does, so re-run it before
starting a batch
**Method:** every number below was produced by a command against the tree at that commit;
every compiler claim was produced by running `nim check`. Nothing is estimated.

This report closes finding **D-11** in `03-error-memory-wiring.md`, which left the dangling-label
question open as *"the user's call, not a defect to fix unilaterally"* and offered three options.
The decision is now made: **option 3 — strip them** — widened to the whole comment apparatus.

---

## 1. Census

Measured, not sampled:

| Measure | Value |
|---|---|
| Nim files (`src/` + `tests/`) | **37** |
| Total lines | **21,874** |
| Comment lines (`^\s*#`) | **7,106 — 32.5% of the file set** |
| ├─ `##` documentation comments | 3,928 |
| └─ `#` plain comments | 3,178 |
| Trailing comments (code then `#`) | 103 |
| `#[ … ]#` multiline comments | **0** (the codebase does not use them) |
| Prefixed comments (`Script`/`Function`/`Action purpose:`) | **557** (37 / 310 / 210) |
| Lines inside those prefixed blocks | **3,823** |
| Other inline comment lines | **3,283** |
| Routine declarations (`proc`/`func`/`template`/`macro`/`method`/`iterator`/`converter`) | **776** |
| ├─ FFI declarations (`importc`/`dynlib`/`header:`, incl. inside `{.push .}`) | 82 |
| ├─ With a comment line immediately above | 357 |
| └─ **With no comment above** | **338** (of which **205 are top-level**) |

**Average size of a prefixed block:**

| Prefix | Blocks | Mean lines | Blocks > 10 lines |
|---|---|---|---|
| `Script function and purpose:` | 37 | **19.8** | — (the largest is 56) |
| `Function purpose:` | 303 | **6.6** | 54 |
| `Action purpose:` | 212 | **7.5** | 49 |

The five largest single comment blocks in the tree: `gui.nim:1` (56 lines), `workspace.nim:1`
(44), `theme.nim:1` (36), `rag.nim:1` (34), `settings.nim:1` (33).

**The shape of the problem in one sentence:** the codebase is simultaneously *over*-commented
(557 prefixed blocks averaging 7–20 lines of prose each) and *under*-commented (**205 top-level
routines with nothing above them at all**). Both halves are the same defect — comment volume is
not being spent where it buys anything.

---

## 2. The defect classes

### D-01 · The explanatory apparatus cites documents that do not exist · **severity: high**

`.devdocs/PLANS.md` and `.devdocs/TODOS.md` were deleted in commit `c5111ce`
(*"Remove AGENTS.md file containing operational directives…"*), together with ten other process
files. Verified:

```
$ git log --all --pretty=format: --name-only --diff-filter=AD | grep -iE 'PLANS|TODOS' | sort -u
.devdocs/PLANS.md
.devdocs/TODOS.md
$ ls PLANS.md TODOS.md
ls: cannot access 'PLANS.md': No such file or directory
ls: cannot access 'TODOS.md': No such file or directory
```

What still points at them, in `src/`:

| Dangling | Count |
|---|---|
| `PLANS.md` by name | 16 |
| `TODOS.md` by name | 4 |
| `.devdocs/` by path | 3 |
| **Bare labels** (`G-30`, `D-BQ`, `A-17`, `T-17`, `N-30`, `S-1`, `W-01`, `E-01` …) | **689 references, 142 distinct labels** |

Not one of the 142 labels is defined anywhere in the repository. Spot-checked against `docs/`,
`.devdocs/` and every `*.md`: `D-AF`, `D-BD`, `Q-24`, `G-31`, `A-61`, `B-13` resolve to **zero**
files. The two that do appear in a `.md` (`T-17`, `N-30`) appear only inside `.devdocs/03`,
which is itself quoting the code.

Worst concentrations: `gui.nim` **251**, `jenova_core.nim` **131**, `pipeline.nim` **54**,
`api.nim` **39**, `fssync.nim` **27**.

**Fifteen matches are legitimate and must survive**: `SHA-256` (×9), `PDF-1` (×4, inside literal
PDF headers such as `jenova_core.nim:839`), `UTF-8` (×1), `SHA-1` (×1). A blind regex sweep
corrupts a PDF writer.

### D-02 · Comments are changelog entries, not explanations · **severity: high**

The prose does not say why the code is the way it is; it recounts what a past session changed and
what the previous version got wrong. Counted inside comments: `defect` ×67, `shipped` ×27,
`"the old"` ×20, `"used to"` ×14, `"no longer"` ×13, `"before this"` ×7, `"the fix"` ×6,
`"was missing"` ×4, `previously` ×3, `regression` ×1.

`gui.nim:3243-3249` is representative — nine lines above `forkFrom`, of which the operative fact
is one clause:

```nim
## Action purpose: **`api.forkConversation` has taken an `atMessageId` since it
## was written and this window has only ever passed an empty one.** With no
## message named it forks from the conversation's own read position, which is
## what the sidebar's fork button means; naming a message is what the Web UI's
## per-message fork does, and it is the difference between "carry on from here"
## and "carry on from wherever I happened to be". The parameter was already
## there — only a caller was missing.
```

*"The parameter was already there — only a caller was missing"* is a commit message. It tells a
reader of today's code nothing, and it will be false the moment anything moves. The same block
also carries a `Function purpose:` that is really a second `Action purpose:` for the same proc.

`rag.nim:1-34` is the extreme case: a 34-line header that argues against `lib/search.lua` — a file
that **does not exist in this repository** (verified: no `search.lua`, no `proxy.lua`, no
`jenova-ui/src/main.c`, no `llama.nim`, no `inference.nim` anywhere in the tree). Three numbered
paragraphs describe defects in code no reader can open.

### D-03 · Comparative archaeology against deleted predecessors · **severity: medium**

Distinct from D-02: headers define modules by what they *replace* rather than what they *do*.
`gui.nim:1-3` ("replacing `jenova-ui/src/main.c` … and `lib/ui.lua`"), `rag.nim:2`
("replacing `lib/search.lua`"), `hardware.nim`, `config.nim`, `theme.nim` (`app.css:270-271`),
`pipeline.nim`. Every named file is gone. The upstream provenance belongs in `UPSTREAM-COPYRIGHT`
and `docs/architecture.md`, which already exist and are maintained; it does not belong above
`proc`.

### D-04 · Prose formatting inside comments · **severity: medium**

**671 comment lines** contain `**markdown bold**`. Headers use `## ## Heading` sub-sections
(`gui.nim:12`, `gui.nim:44`, `workspace.nim:10`, `workspace.nim:39`), numbered essays
(`rag.nim:7-16`) and bullet lists. This is documentation-generator output styling applied to
source a person reads in a terminal, and the emphasis is applied so uniformly it no longer marks
anything.

### D-05 · Coverage is inverted · **severity: medium**

**205 top-level routines have no comment above them.** Concentrated in exactly the modules whose
headers are longest: `gui.nim` 54, `fssync.nim` 20, `api.nim` 17, `rag.nim` 15, `db.nim` 11,
`server.nim` 10, `lifecycle.nim` 10. Meanwhile 103 prefixed blocks run past 10 lines.

The 82 FFI declarations are **correctly** uncommented — a 1:1 `importc` binding to
`sqlite3_bind_text` restates its C prototype and nothing else. `{.push importc … .}` blocks
(`db.nim:67`, `vte.nim:20`, `sourceview.nim:21`, `sourceview.nim:53`, `dbus.nim:32`,
`zlib.nim:13`) need **one** `Action purpose:` on the block, not one per line.

### D-06 · Stale absence claims · **severity: low, but each one is a live lie**

43 comment lines assert something is missing, unimplemented or uncalled. Most are false
positives (the word "placeholder" in its GTK sense). The genuine ones are dated statements that
rot: `rag.nim:34` — *"until 2026-09-01 `indexContent` had no caller outside the self-test"*;
`rag.nim:326` — the same claim again; `jenova_core.nim:8-10` — *"was **deleted** on 2026-08-31"*.
There are **no** `TODO`/`FIXME`/`XXX` markers, which is the one thing this codebase gets right.

---

## 3. The standard to enforce

Derived directly from your instruction, made concrete and testable.

### 3.1 Every file — exactly one header

```nim
## Script function and purpose: <what this module is for, and its place in the system>
```

**Budget: 1–4 lines. Hard ceiling 6.** No sub-headings, no bold, no bullet lists, no numbered
arguments, no comparison to a predecessor, no dates. Current mean is 19.8 lines.

### 3.2 Every non-FFI routine — one line, above the declaration

```nim
## Function purpose: <why it exists / how it is used>
proc forkFrom(app: AppState, sourceId, atMessageId: string) =
```

**Budget: 1 line. 2 only where a single line genuinely cannot carry it.** It must not restate
the name or signature; it must say *why*. The test: if the sentence stays true when you rename
the proc to `doThing`, it is a *what* comment and it goes.

An FFI declaration gets nothing; its `{.push .}` block gets one `Action purpose:` line naming the
library and why it is bound directly.

### 3.3 Non-obvious logic — one comment, above the block

```nim
# Action purpose: <why this logic, and how it is meant to work>
```

**Budget: 1–3 lines.** Only where the code is genuinely not self-explanatory: a workaround for
external behaviour, an ordering constraint, a non-obvious invariant, a deliberate omission. If
the block below reads clearly, the comment is deleted, not shortened.

### 3.4 Absolute rules

1. **No `what`.** If the comment restates the code, delete it.
2. **No labels.** No `G-30`, `D-BQ`, `T-17`, `A-17`. Where a label carried real information,
   state the information in words. (`SHA-256`, `PDF-1`, `UTF-8`, `SHA-1` are not labels.)
3. **No dangling references.** No `PLANS.md`, no `TODOS.md`, no `.devdocs/*`, no `lib/*.lua`,
   no `jenova-ui/`. References to files that exist (`docs/install.md`, `db.nim`, `search.lua`
   → nothing) are fine.
4. **No history.** No "used to", "was missing", "shipped", "the old", "this commit", no dates.
   Present tense, describing the code as it stands.
5. **No markdown formatting.** No `**`, no `## ##` headings, no bullet or numbered lists.
6. **Native syntax.** Nim: `##` for the file header and above declarations, `#` for logic inside
   bodies. See §4.1 — this is a compiler constraint, not a style preference.

### 3.5 Target

Applying the budgets to the current structure:

| | Now | Target |
|---|---|---|
| `Script function and purpose:` | 37 blocks / ~733 lines | 37 / ~150 |
| `Function purpose:` | 310 / ~2,000 lines | ~500 (covering the 205 uncommented) / ~550 |
| `Action purpose:` | 210 / ~1,590 lines | ~200 / ~450 |
| Other inline comments | 3,283 lines | ~700 |
| **Total comment lines** | **7,106 (32.5%)** | **~1,850 (≈9%)** |

**Roughly 5,300 comment lines removed, ~350 one-line comments added.** Coverage of top-level
routines goes from 54% to 100%; volume drops by three quarters.

---

## 4. Constraints — what must not be touched, and why

### 4.1 `##` is a syntax-tree token, not a comment

The Nim manual, *Lexical Analysis* (`doc/manual.md`, `version-2-2`, "Comments"):

> "Comments start anywhere outside a string or character literal with the hash character `#`.
> Comments consist of a concatenation of `comment pieces`. A comment piece starts with `#` and
> runs until the end of the line."

and, immediately after:

> "`Documentation comments` are comments that start with two `##`. Documentation comments are
> tokens; they are only allowed at certain places in the input file as they belong to the syntax
> tree."

*"Only allowed at certain places"* is load-bearing. Verified empirically against the installed
compiler (Nim 1.6.14), each case a minimal file run through `nim check`:

| Position | `##` | `#` |
|---|---|---|
| Above a top-level `proc` | OK | OK |
| Mid-body, after a statement | OK | OK |
| After an object field | OK | OK |
| First line of an `if` branch | OK | OK |
| Last line of a proc body | OK | OK |
| Between a `case` selector and its first `of` | **`Error: expression expected, but found 'keyword of'`** | OK |
| Inside a parameter list | **`Error: expected closing ')'`** | OK |
| Inside an array literal | **`Error: expression expected`** | OK |

**Therefore:** rewriting a `#` as `##` is not a safe mechanical substitution, and moving a `##`
block is not free. Every conversion is checked, not assumed.

### 4.2 Comments that are load-bearing at runtime

| Location | Why it cannot be swept |
|---|---|
| `theme.nim:198-…` | 67 `/* … */` **CSS** comment lines live inside a Nim `"""` string literal that is fed to GTK. They contain labels (`G-31`, `G-34`, `G-30`, `A-70`). They must be cleaned as CSS comments, keeping the string syntactically valid, and can never be treated as Nim comments. |
| `jenova_core.nim:30` | `Stage = "N-S6 — harness with lifecycle; llama-server is the engine (D-AF)"` — printed to the user by `usage()` and `version`. A user-facing string containing two dead labels. |
| `jenova_core.nim:48` | `echo "  hardware <sub>  Detect hardware and select a profile (S-1)"` — user-facing help text. |
| `jenova_core.nim:3172` | `if d.awaiting.contains("Step 7b") or d.awaiting.contains("G-30"):` — **a self-test guard whose control flow depends on those exact substrings**, matched against `settings.nim`'s `awaiting:` fields. Editing either side alone silently disarms the guard. |
| `jenova_core.nim:2080, 2154, 2423, 2753, 2903` | Self-test `check()` descriptions carrying labels — printed on failure. |
| `jenova_core.nim:839, 879, 903, 947` | `%PDF-1.4` in literal PDF bytes. Not a label. |

Everything in this table is **code**, not comments, and therefore strictly outside the brief. It
is listed so the sweep does not touch it by accident, and so the three user-facing cases can be
raised separately.

### 4.3 The build cannot be run here

`src/jenova_core.nim:19` and `src/jenova_gui.nim:20` refuse to compile off FreeBSD
(`{.error: "jenova-core targets FreeBSD only — see docs/install.md.".}`). The project targets Nim
2.2.10 with GTK4/libadwaita and owlkettle; this container has Nim 1.6.14 on Linux with neither.
**No binary can be produced and no self-test can be executed here.** §5 is what is achievable
instead, and its limits are stated rather than implied.

---

## 5. Verification

Already built and proven at `scratchpad/verify.sh`. It copies the tree, neutralises the two
FreeBSD guards, runs `nim check --threads:on` over every file against empty owlkettle stubs, and
records each diagnostic with line and column stripped — so a comment edit that shifts line numbers
produces no diff, while a *new or vanished* diagnostic does.

**Baseline at `e495c8f`: 1,239 diagnostic lines.** The baseline is per-commit, not per-branch —
regenerate it against the tree you are about to edit.

- **28 of 37 files type-check clean.**
- `server.nim`, `serverselftest.nim`, `jenova_core.nim` fail on one Nim 1.6-only diagnostic
  (`server.nim:76` — `expression has no address; maybe use 'unsafeAddr'`; Nim 2.x relaxed this).
  Not a defect, and identical before and after.
- `gui.nim`, `theme.nim`, `canvas.nim`, `sourceview.nim`, `vte.nim`, `jenova_gui.nim` cannot
  type-check without owlkettle; against stubs every owlkettle symbol is missing identically in
  both runs, so the signature set is stable noise. A *new* signature means a real error, and the
  file parsing to end of file is what catches a broken `##`.

**The harness was proven to discriminate**, not assumed to: renaming `rag.chunkText` to
`chunkTextBROKEN` in a scratch copy produced 14 new diagnostic lines against the baseline.

**Gate for every batch: `diff baseline.log after.log` is empty.** Any non-empty diff is
investigated before the batch is committed.

**What this does not cover:** anything owlkettle-typed in `gui.nim`. Since this work touches only
comments, the residual risk is confined to a `##` landing where §4.1 forbids it — which is a
*parse* error, and parse errors are exactly what the stub run does catch.

---

## 6. Execution plan

Ordered smallest-first so the standard is proven on cheap files before `gui.nim`. One commit per
batch, each gated on §5.

| Batch | Files | Lines | Comments | Labels | Why this grouping |
|---|---|---|---|---|---|
| **0** | *(no source)* — record the standard | — | — | — | Write §3 into `docs/` or a `CLAUDE.md` so the rule outlives this pass |
| **1** | `sha256`, `prompts`, `zlib`, `websearch`, `dbselftest`, `serverselftest`, `tests/nvimctl_check` | 839 | 165 | 7 | Self-contained, no FFI, no GUI. Proves the target shape. |
| **2** | `paths`, `config`, `convmd`, `routes`, `http`, `upstream`, `nvimctl`, `pdf`, `workspace`, `models`, `composer` | 2,127 | 843 | 52 | Pure logic modules. `composer.nim` is 61% comment — the worst ratio in the tree. |
| **3** | `dbus`, `zlib`(done), `vte`, `sourceview`, `db` | 1,056 | 308 | 24 | The FFI modules. Establishes the `{.push .}`-block rule (§3.2) in one place. |
| **4** | `settings`, `hardware`, `markdown`, `lifecycle`, `server`, `rag`, `fssync` | 4,221 | 1,403 | 102 | Core logic. `rag.nim:1-34` and `lifecycle.nim:145-177` are the reference rewrites for D-02/D-03. |
| **5** | `pipeline`, `api` | 2,366 | 923 | 93 | The two largest non-GUI files. |
| **6** | `theme`, `canvas`, `tray`, `jenova_gui` | 1,409 | 335 | 29 | GUI support. **`theme.nim` includes the 67 CSS comment lines inside the string literal (§4.2)** — the one batch needing a second pair of eyes on a string. |
| **7** | `jenova_core` | 4,384 | 1,045 | 131 | Entry point plus 17 self-tests. 54 `Action purpose:` blocks, only 1 `Function purpose:` for 34 uncommented routines. |
| **8** | `gui` | 5,472 | 2,084 | 251 | **38% comment, 251 labels, 54 uncommented top-level routines, the 56-line header.** Alone, and last, because it is a third of the whole job and the only file with no type-check safety net. |

**Total: 37 files, 21,874 lines, 7,106 comment lines, 689 labels.**

### Per-file procedure

1. Read the file whole. The rewrite is judgement, not regex — a label sometimes encodes a real
   constraint that must be restated in words before it is deleted.
2. Header → §3.1. Delete predecessor comparison, sub-headings, numbered arguments, dates.
3. Each non-FFI routine → exactly one `Function purpose:` line. Add where missing; compress where
   present; delete where it restates the signature and put nothing back.
4. Each `Action purpose:` → 1–3 lines, or delete outright if the code below is self-explanatory.
5. Sweep the residue: bold, headings, labels, dangling filenames, history verbs.
6. `verify.sh` → diff against baseline → commit.

### What this plan deliberately does not do

- **It does not touch code.** Not one statement, not one string literal — except `theme.nim`'s
  CSS comments, which are comments living inside a string and are named explicitly in §4.2.
- **It does not fix the three user-facing label leaks** (`Stage`, the `hardware` help line, the
  self-test descriptions). They are strings; changing them is a separate, smaller change and
  `jenova_core.nim:3172` proves at least one such string is load-bearing.
- **It does not restore the deleted `.devdocs/` corpus.** Option 1 of D-11 stays rejected: the
  labels are being removed, so there is nothing left to look up.
- **It does not add new documentation files** beyond batch 0's record of the standard.

---

## 7. Recommendation

Start at batch 1 and stop after batch 2 for review. Those 18 files are 14% of the lines and 14%
of the comments, they carry every defect class except the CSS and FFI special cases, and they cost
little to redo if the target shape is not what you meant. `gui.nim` should not be attempted until
the standard has survived a review pass on real files.
