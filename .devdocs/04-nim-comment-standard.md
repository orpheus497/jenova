# Report 04 — The Nim comment standard: audit and cleanup plan

**Status as of 2026-09-29T22:31Z (baseline `4acedfa0`; host Arch Linux).** Executed 2026-09-03:
batches 1–8 and a residue sweep, squashed into main in `989c2b5d` (#117). No batch is pending.
AGENTS.md's CODE DOCUMENTATION STANDARDS (new and touched code only) now govern and win wherever this
report differs; the differences are marked inline. The cross-reference lines §1 still counts are
fixed where code is touched, never by a mass repair (the USER's ruling 7, DECISIONS_LOG
2026-09-29T23:30Z). §1 carries the dated HEAD census; §3.5–§7 are historical.
**Re-checked 2026-09-30T01:16Z:** every census figure a code verification flagged was re-measured and
corrected in place.

**Scope:** `src/**/*.nim`, `tests/**/*.nim` — **37 files, 21,874 lines** at the commit measured;
**44 files, 29,534 lines** at `51ffdbf1` (2026-09-04); **44 files, 32,592 lines** at `4acedfa0`, see
§1. Nothing else.
Explicitly out of scope: `jca_web/`, `jvim/`, `bin/`, `etc/`, `hardware-profiles/`,
`external/`, `docs/`, `README.md`.
**Measured at commit:** `c8fb564` (reflog-only; its content reached main in `989c2b5d`) on
`claude/gui-webui-parity-audit-avmj8w`, a branch no longer present. These are a point-in-time
census, not a constant. Regenerate the whole worksheet with:

```sh
# Cross-references counted on comment lines only. The original pattern was the first alternative
# alone, which misses every other shape below.
XREF='\b[A-Z]{1,4}-[A-Z0-9]{1,3}\b|\b[0-9]+[a-z]-[0-9]+\b|\bStep [0-9]+[a-z]?\b|\bDirective [0-9]+\b|\breports? 0?[0-9]{1,2}\b|§[0-9A-Za-z]+|\b[Pp]hase [0-9]|\b[[:alnum:]_./-]+\.(nim|nimble|md|sh|lua|svelte|css|ts|js|c|h):[0-9]+'
for f in $(find src tests -name '*.nim' | sort); do
  printf '%s %d %d %d\n' "$f" "$(wc -l <"$f")" "$(grep -cE '^[[:space:]]*#' "$f")" \
    "$(grep -E '^[[:space:]]*#' "$f" | grep -oE "$XREF" | grep -vE '^(SHA-256|SHA-1|UTF-8|PDF-1|AGPL-3)$' | wc -l)"
done
```

Discount by eye: standards citations (`RFC 3986 §3.1`, `PDF 32000-1 §7.3.4.3`) and
`serverselftest.nim`'s names for its own test phases. The conclusions do not move with a few dozen
lines; the batch table below does, so re-run it before starting a batch. [2026-09-29T22:31Z: every
batch has run; the command now serves the §1 HEAD census.]
**Method:** every number below was produced by a command against the tree at that commit;
every compiler claim was produced by running `nim check`. Nothing is estimated.

This report closes finding **D-11** in `03-error-memory-wiring.md`, which left the dangling-label
question open as *"the user's call, not a defect to fix unilaterally"* and offered three options.
The decision is now made: **option 3 — strip them** — widened to the whole comment apparatus.

---

## 1. Census

Measured, not sampled:

The first column is the original census at `c8fb564`. **The second is the same measurement re-run
at `51ffdbf1`** (2026-09-04, reflog-only), because the report warned these move and they had: the
tree had grown by seven files and a third again as many lines. The third is the content of
`4acedfa0`, measured 2026-09-29T22:31Z.

| Measure | At `c8fb564` | At `51ffdbf1` | At `4acedfa0` |
|---|---|---|---|
| Nim files (`src/` + `tests/`) | **37** | **44** | **44** |
| Total lines | **21,874** | **29,534** | **32,592** |
| Comment lines (`^\s*#`) | **7,106 — 32.5% of the file set** | **9,227 — 31.2%** | **10,416 — 32.0%** |
| ├─ `##` documentation comments | 3,928 | 4,522 | 4,947 |
| └─ `#` plain comments | 3,178 | 4,705 | 5,469 |
| Trailing comments (code then `#`) | 103 | 192 | not re-derived |
| `#[ … ]#` multiline comments | **0** (the codebase does not use them) | **0** — still none | **0** |
| Prefixed comments (`Script`/`Function`/`Action purpose:`) | **557** (37 / 310 / 210) | **1,102** (44 / 634 / 424) | **1,239** (44 / 670 / 525) |
| Routine declarations (`proc`/`func`/`template`/`macro`/`method`/`iterator`/`converter`) | **776** | **983** | **1,042** (121 FFI) ¹ |
| ├─ With no comment line immediately above | **338** (of which **205 are top-level**) | **269** | **318**: 111 FFI and 207 others, 37 of those at column 0 ¹ |

¹ Re-measured 2026-09-30 by a line-start match over `src/` and `tests/`. A routine counts as FFI when
it sits inside a `{.push importc/dynlib.}` block or carries `importc`/`dynlib` in its own signature,
continuation lines included: `gui` 32, `dbus` 27, `db` 19, `sourceview` 17, `mathfont` 13, `vte` 6,
`zlib` 3, `theme` 2, `lifecycle` 1, `shortcuts` 1. The 37 column-0 routines with nothing above them:
`mathtex` 16, `gui` 7, `mathfont` 4, `db` 2, `markdown` 2, and `api`, `fssync`, `models`, `rag`,
`sourceview`, `upstream` 1 each. This column's walk is not the one behind the other two, so compare
within a column rather than across.

Two of those rows are worth reading against each other. **Prefixed comments have doubled while
undocumented routines have fallen by 69** — the coverage inversion §2's D-05 names is being
corrected from the under-commented end, which is the half worth correcting. The comment share of
the file set has drifted *down* slightly, 32.5% to 31.2%, so the growth has not been prose.
[2026-09-29T22:31Z: correction — this was misattributed when written. All eight batches had already
run: they took the share from 32.5% to 30.4% (6,642 comment lines at the residue sweep `f3ebb8be`,
reflog-only; in `989c2b5d`). Code added 2026-09-04/05 at ~37% comment density then raised it to
31.2% here and 32.5% at `989c2b5d`; #118 added code at ~22%.]

> **Re-run 2026-09-09, and the drift has reversed.** 44 files, **31,109 lines**, **10,096 comment
> lines — 32.4%**, prefixed blocks **1,179**. So the share is back to where it started and the
> target in §3.5 is ~9%. The one measure that improved is D-04's: comment lines carrying
> `**markdown bold**` are down from 671 to **164**. [2026-09-29T22:31Z: these are exactly the
> `989c2b5d` (2026-09-05) figures; the 2026-09-09 tree measured 31,382 / 10,180 / 1,193.]
>
> The reading above still holds and is the point: batches 1 and 2 added coverage where it was
> missing and cut no volume where it was excessive, and everything written since has been written
> at the old density. `composer.nim` is **59.4%** comment and `upstream.nim` **51.4%** — both
> inside the batch this report calls done. **Batch 3 should not start until that is settled**,
> because continuing the same shape over 26 more files makes the number worse, not better.
> [2026-09-29T22:31Z: false when written. Batches 1 and 2 did cut volume (165 → 126 and 843 → 561
> comment lines; `composer.nim` 57.3% → 48.9%, `upstream.nim` 45.6% → 34.7%), and both files grew
> back through later feature work. Batches 3–8 had run on 2026-09-03, six days before this note.
> Nothing is waiting to start; see the status block.]

> The re-measured FFI row is omitted rather than guessed: a count of `importc`/`dynlib`/`header:`
> on the declaration line alone gives 30, which is not comparable to the original 82 because that
> figure included declarations inheriting the pragma from an enclosing `{.push .}`. Re-deriving it
> needs the push-block walk the original used, and no conclusion here turns on it.

**At `4acedfa0`, measured 2026-09-29T22:31Z** (`src/`, 43 files, unless stated). Each figure is
checked against AGENTS.md's standard, which applies to new and touched code, so the legacy counts
describe the tree and are not a work list:

| Measure | Value |
|---|---|
| Comment share | 32.0% (src + tests; `src/` alone 10,404 / 32,527). Ten largest files 31.6%. Highest: `version` 66.7%, `composer` 59.4%, `upstream` 51.4%, `assetview` 50.8%, `models` 47.1%, `pkgconfig` 43.5%, `gui` 41.8% |
| Share over time | 32.5% (`c8fb564`) → 30.4% after the eight batches (`f3ebb8be`) → 31.2% (`51ffdbf1`) → 32.5% (`989c2b5d`) → 32.0% (`4acedfa0`) |
| Prefixed blocks, `src/` | 43 `Script` / 669 `Function` / 523 `Action` |
| Over budget | headers 29 of 43 past the 6-line ceiling (mean 11.1; largest `mathfont.nim`'s, 57); `Function purpose` 381 of 669 past 2 lines (mean 3.4); `Action purpose` 398 of 523 past 3 lines (mean 6.4) |
| New code under AGENTS.md (#118) | 356 comment lines, no cross-references; 24 of 37 new `Action purpose` and 9 of 28 new `Function purpose` blocks past budget |
| Cross-references (widened `XREF`, comment text only; re-measured 2026-09-30) | **91 lines in 9 files.** 71 carry labels or report references (`gui` 54, `jenova_core` 11, `mathfont` 3, `fssync` 2, `api` 1); 20 carry `file:line` citations — 18 on full-line comments (`gui` 13, `version` 3, `serverselftest` 2) and 2 trailing (`canvas` 1, `pipeline` 1). Discounted by eye: four standards citations (`PDF 32000-1 §7.3.4.3` twice, `RFC 3986 §3.1` twice) and `serverselftest`'s own phase names |
| …by shape | hyphen labels 14 (11 distinct), plan items such as `8c-3`/`12d-4` 23, `Step NN` 19, `Directive N` 3, `report 0N` 18, `§N` 8, report 05's `Phase N` 5, `file:line` 22 |
| History phrasing | 110 raw hits on *used to / was missing / shipped / the old / no longer / previously / session / an ISO date*; **54 genuine** by hand (`gui` 25, `jenova_core` 15, `serverselftest` 5, `server` 4, `models` 2, `api`/`config`/`fssync` 1 each). The rest are present tense — "the old name" of a renamed file, "the shipped profiles" |
| Markdown in comments | 170 lines carry `**`; `## ##` sub-headings survive only in `mathfont.nim` (3) |

**Average size of a prefixed block** (at `c8fb564`; the HEAD means are in the table above):

| Prefix | Blocks | Mean lines | Blocks > 10 lines |
|---|---|---|---|
| `Script function and purpose:` | 37 | **19.8** | — (the largest is 56) |
| `Function purpose:` | 303 | **6.6** | 54 |
| `Action purpose:` | 212 | **7.5** | 49 |

The five largest single comment blocks in the tree: `gui.nim:1` (56 lines), `workspace.nim:1`
(44), `theme.nim:1` (36), `rag.nim:1` (34), `settings.nim:1` (33). [2026-09-29T22:31Z: at
`4acedfa0` they are the `mathfont.nim` header (57), the block above `fssync.moveFileAssetMirror`
(39), the `gui.nim` header (29), the block above `mathfont.readConstants` (26) and the `mathtex.nim`
header (25).]

**The shape of the problem in one sentence:** the codebase is simultaneously *over*-commented
(557 prefixed blocks averaging 7–20 lines of prose each) and *under*-commented (**205 top-level
routines with nothing above them at all**). Both halves are the same defect — comment volume is
not being spent where it buys anything.

> **The under-commented half is the one that has moved.** At `51ffdbf1`, routines with nothing above
> them were down to 269 out of 983 — 69 fewer in absolute terms across a file set a third larger.
> The over-commented half has not: prefixed blocks have doubled to 1,102. Batches 1 and 2 added
> coverage where it was missing without cutting volume where it was excessive, so of the two
> halves named here only one is being worked. [2026-09-29T22:31Z: false when written — all eight
> batches had run. Batches 1 to 7 each cut comment lines (batch 2 843 → 561, batch 4 1,454 → 1,181,
> batch 5 923 → 720), and batch 8 took 249 labels and 211 lines of bold out of `gui.nim` while
> adding coverage. The regrowth is code written afterwards.]

---

## 2. The defect classes

### D-01 · The explanatory apparatus cites documents that do not exist · **severity: high** · **largely done**

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

[2026-09-29T22:31Z: both were recreated on 2026-09-09. V-17 bars code comments from citing them —
or any document — whether or not the target exists.]

What still points at them, in `src/` — as first measured, and at `51ffdbf1`:

| Dangling | At `c8fb564` | At `51ffdbf1` |
|---|---|---|
| `PLANS.md` by name | 16 | **0** |
| `TODOS.md` by name | 4 | **0** |
| `.devdocs/` by path | 3 | **0** |
| **Bare labels** (`G-30`, `D-BQ`, `A-17`, `T-17`, `N-30`, `S-1`, `W-01`, `E-01` …) | **689 references, 142 distinct labels** | **18 references, 14 distinct** |

**This finding has substantially been carried out.** Option 3 — strip — was chosen and applied:
689 label references became 18, and the three document references became none. The four `TODOS.md`
mentions that survive are in `tests/*.sh`, outside the `src/` scope measured here and recorded in
report 01's D-11. Those four "(TODOS.md A-2)" mentions are still there, and the recreated TODOS.md
has no A-2. The "18" counted one label shape only: with the widened `XREF`, §1's HEAD table finds
91 comment lines carrying a cross-reference.

**And the class changed as well as the count.** Eight of the fourteen surviving labels now resolve
to a report that exists — `E-06`, `P-A5`, `P-E8`, `M-3`, `V-04`, `V-10`, `V-16` and the `G-30`
discussed in reports 01 and 02 — so following one lands somewhere. That is the outcome §3.4 asks
for, not the defect this finding names. **Six do not resolve to anything: `A-7`, `B-17`, `D-CD`,
`G-31`, `X-A`, and `AGPL-3`** — the last being a licence identifier the regex catches rather than
a label at all, and `G-31`/`A-7` matching only because this report quotes them as examples. So the
true remainder is four dangling labels across `src/`, down from 689. [2026-09-29T22:31Z: two
corrections, each already true when this was written. A label that resolves is still a label —
§3.4 rule 2 said "No labels" then, and AGENTS.md's CODE DOCUMENTATION STANDARDS and V-17 now bar
labels and document references in code comments outright. `X-A` is not a comment label: it is the
`"X-A: 1\r\n"` header literal in `relay-selftest`.]

**As originally measured:** not one of the 142 labels was defined anywhere in the repository.
Spot-checked against `docs/`, `.devdocs/` and every `*.md`, `D-AF`, `D-BD`, `Q-24`, `G-31`, `A-61`
and `B-13` resolved to **zero** files; the two that appeared in a `.md` at all (`T-17`, `N-30`)
appeared only inside `.devdocs/03`, which was itself quoting the code.

Worst concentrations then: `gui.nim` **251**, `jenova_core.nim` **131**, `pipeline.nim` **54**,
`api.nim` **39**, `fssync.nim` **27**. At `4acedfa0` the hyphen shape in comments finds `gui.nim` 5
labels (`E-06`, `B-17`, `P-E8` twice, `G-31`) plus the `AGPL-3` of `AGPL-3.0-or-later` in a comment,
`jenova_core.nim` 3 (`V-16`, and `A-7` with `D-CD` on one line), `mathfont.nim` 3 (`P-A5`, `M-3`,
`V-04`), `fssync.nim` 2 (`V-10` twice) and `api.nim` 1 (`V-10`); `version.nim`'s only match is
`AGPL-3`. Every shape: §1's HEAD table.

**Sixteen matches in `src/` are legitimate and must survive**: `SHA-256` (×5), `PDF-1` (×4, the
`%PDF-1.4` literals `attach-selftest` builds, e.g. `jenova_core.nim:903`) and `UTF-8` (×7). There is
no `SHA-1`; the only near-miss is the unhyphenated `std/sha1`. A blind regex sweep would corrupt
those PDF test fixtures — `src/` has no production PDF writer, since `pdf.nim` only reads.

### D-02 · Comments are changelog entries, not explanations · **severity: high**

The prose does not say why the code is the way it is; it recounts what a past session changed and
what the previous version got wrong. Counted inside comments: `defect` ×67, `shipped` ×27,
`"the old"` ×20, `"used to"` ×14, `"no longer"` ×13, `"before this"` ×7, `"the fix"` ×6,
`"was missing"` ×4, `previously` ×3, `regression` ×1. [2026-09-29T22:31Z: at `4acedfa0`, word-bounded
on comment lines — `defect(s)` 51, `shipped` 17, `the old` 43, `used to` 19, `no longer` 17,
`before this` 7, `the fix` 5, `was missing` 3, `previously` 2, `regression` 1. Raw words over-count:
54 lines narrate history by hand classification (§1); most `the old` / `shipped` hits are present
tense.]

The block above `forkFrom` is representative (`gui.nim:3243-3249` then; `gui.nim:4032-4038` at
`4acedfa0`, bold removed, the closing sentence still there) — nine lines, of which the operative
fact is one clause:

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
paragraphs describe defects in code no reader can open. [2026-09-29T22:31Z: rewritten in batch 4;
the `rag.nim` header is 16 lines at `4acedfa0`.]

### D-03 · Comparative archaeology against deleted predecessors · **severity: medium**

Distinct from D-02: headers define modules by what they *replace* rather than what they *do*.
`gui.nim:1-3` ("replacing `jenova-ui/src/main.c` … and `lib/ui.lua`"), `rag.nim:2`
("replacing `lib/search.lua`"), `hardware.nim`, `config.nim`, `theme.nim` (`app.css:270-271`),
`pipeline.nim`. Every named file is gone. The upstream provenance belongs in `UPSTREAM-COPYRIGHT`
and `docs/architecture.md`, which already exist and are maintained; it does not belong above
`proc`. Those headers were rewritten in the batches: none of the six names a predecessor file now,
though `gui.nim`'s still defines its control surface by what it replaced — *"reproduced feature for
feature from what came before it"*. Predecessor references survive elsewhere: `ui.lua` four times in
`gui.nim`; `proxy.lua` in `api.nim`, `jenova_core.nim` and `pipeline.nim`'s `LargePayloadChars`;
`lib/jenova-model.sh` and `bin/jenova-model-switch` in `jenova_core.nim`'s `models` verb, whose
sentence — like the `hardware` verb's, which now ends at "replacing" — the batches left truncated;
`search.lua` in `rag-selftest`'s printed output (`jenova_core.nim:6702`); `bin/jenova-ca`, which no
longer exists, in comments on the `backends args` and `serve` verbs (`jenova_core.nim:191`, `:7570`);
and `theme.nim`'s stylesheet cites the Web UI's `app.css` by line.

### D-04 · Prose formatting inside comments · **severity: medium**

**671 comment lines** contain `**markdown bold**`. Headers use `## ## Heading` sub-sections
(`gui.nim:12`, `gui.nim:44`, `workspace.nim:10`, `workspace.nim:39`), numbered essays
(`rag.nim:7-16`) and bullet lists. This is documentation-generator output styling applied to
source a person reads in a terminal, and the emphasis is applied so uniformly it no longer marks
anything. [2026-09-29T22:31Z: 17 bold lines were left after the residue sweep; 170 at `4acedfa0`.
`## ##` sub-headings survive only in the `mathfont.nim` header (3), written the day after the
sweep.]

### D-05 · Coverage is inverted · **severity: medium**

**205 top-level routines have no comment above them.** Concentrated in exactly the modules whose
headers are longest: `gui.nim` 54, `fssync.nim` 20, `api.nim` 17, `rag.nim` 15, `db.nim` 11,
`server.nim` 10, `lifecycle.nim` 10. Meanwhile 103 prefixed blocks run past 10 lines.

The 82 FFI declarations counted then are **correctly** uncommented — a 1:1 `importc` binding to
`sqlite3_bind_text` restates its C prototype and nothing else. `{.push importc … .}` blocks need
**one** `Action purpose:` on the block, not one per line.

AGENTS.md now decides what is a defect here: *"An existing file that does not meet this standard is
not thereby a defect to fix"*, and `Function purpose:` is required *"above every new public/exported
function, and above a private one whose purpose the body does not make obvious"*. Legacy gaps close
when the routine is touched. At `4acedfa0` (re-measured 2026-09-30): 121 FFI routine declarations —
85 inside push blocks (`db` 19, `dbus` 27, `mathfont` 13, `sourceview` 17, `vte` 6, `zlib` 3) and
36 carrying `importc` themselves (`gui` 32, `theme` 2, `lifecycle` 1, `shortcuts` 1); 10 of those 36
have a comment directly above them, among them `lifecycle.nim`'s `pipe2`, `shortcuts.nim`'s
`gtk_callback_action_new`, `gui.nim`'s `adw_init` and `theme.nim`'s two. The push blocks are
`db.nim:56`, `vte.nim:24`, `sourceview.nim:21`, `sourceview.nim:51`, `dbus.nim:21`, `zlib.nim:10`
and `mathfont.nim:142` (HarfBuzz); `dbus.nim:21` and `sourceview.nim:51` push only a header, and
their `importc` sits on each proc. 37 column-0 non-FFI routines have no comment line directly above
them, and 106 prefixed blocks run past 10 lines. Every push block has its `Action purpose:` except
`mathfont.nim`'s HarfBuzz block, added 2026-09-04.

### D-06 · Stale absence claims · **severity: low, but each one is a live lie**

43 comment lines assert something is missing, unimplemented or uncalled. Most are false
positives (the word "placeholder" in its GTK sense). The genuine ones are dated statements that
rot: `rag.nim:34` — *"until 2026-09-01 `indexContent` had no caller outside the self-test"*;
`rag.nim:326` — the same claim again; `jenova_core.nim:8-10` — *"was **deleted** on 2026-08-31"*.
There are **no** `TODO`/`FIXME`/`XXX` markers, which is the one thing this codebase gets right.
Those three are gone, and there are still none of the markers. Dated or clock-stamped comments remain
in five places at `4acedfa0`: in `attach-selftest` ("2026-09-03 run", "Step 7b, closed 2026-09-02";
`jenova_core.nim:846`, `:896`), above `gui.nim`'s `quitting` (2026-08-31 — the same comment also
says every timeout checks the flag, which the tray pump does not), above `hwWorker` ("shipped at
16:19"), above `fullscreenButton` ("added at 19:02"), and in a CSS comment inside `theme.nim`'s
stylesheet string ("until 2026-08-31", `theme.nim:192`).

---

## 3. The standard to enforce

Derived directly from your instruction, made concrete and testable. [2026-09-29T22:31Z: superseded
by AGENTS.md's CODE DOCUMENTATION STANDARDS, which apply to *"new and touched code only"* and win
wherever this section differs. The prefixes and budgets agree. Scope differs, and AGENTS.md is
quoted inline where it does. AGENTS.md adds one rule this section lacks: *"when you touch a comment
that runs over its budget, cut it back in the same edit."*]

### 3.1 Every file — exactly one header

```nim
## Script function and purpose: <what this module is for, and its place in the system>
```

**Budget: 1–4 lines. Hard ceiling 6.** No sub-headings, no bold, no bullet lists, no numbered
arguments, no comparison to a predecessor, no dates. The mean was 19.8 lines at `c8fb564`. AGENTS.md
places the header *"at the top of a source file **you create**"*. All 43 `src/` files have one, and
at `4acedfa0` the mean is 11.05 lines (475 contiguous `##` lines from line 1 across the 43).

### 3.2 Every non-FFI routine — one line, above the declaration

```nim
## Function purpose: <why it exists / how it is used>
proc forkFrom(app: AppState, sourceId, atMessageId: string) =
```

**Budget: 1 line. 2 only where a single line genuinely cannot carry it.** It must not restate
the name or signature; it must say *why*. The test: if the sentence stays true when you rename
the proc to `doThing`, it is a *what* comment and it goes. [2026-09-29T22:31Z: AGENTS.md narrows
the scope: *"required above every new public/exported function, and above a private one whose
purpose the body does not make obvious"*.]

An FFI declaration gets nothing; its `{.push .}` block gets one `Action purpose:` line naming the
library and why it is bound directly. [2026-09-29T22:31Z: AGENTS.md: *"its enclosing `{.push .}`
block gets one `Action purpose:` naming the library"*, within the 1–3-line budget.]

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
   → nothing) are fine. [2026-09-29T22:31Z: superseded by V-17 — no document references and no
   line numbers in code comments, whether or not the target exists. Naming a module or identifier
   (`db.nim`, `api.putEntity`) is code, not a citation.]
4. **No history.** No "used to", "was missing", "shipped", "the old", "this commit", no dates, no
   session numbers (the last from AGENTS.md). Present tense, describing the code as it stands.
5. **No markdown formatting.** No `**`, no `## ##` headings, no bullet or numbered lists.
   [2026-09-29T22:31Z: advisory — this rule is not in AGENTS.md, and binds only if the USER adds
   it there.]
6. **Native syntax.** Nim: `##` for the file header and above declarations, `#` for logic inside
   bodies. See §4.1 — this is a compiler constraint, not a style preference.

### 3.5 Target

[2026-09-29T22:31Z: historical and superseded. These targets drove the 2026-09-03 batches. AGENTS.md
now forbids pursuing them retroactively — *"Do not mass-edit existing files solely to add or reformat
comments, and do not add commenting retroactively unless the user explicitly asks for it"*. The gap
between §1's columns is eight batches plus new code, not batches 1 and 2. HEAD figures: §1.]

Applying the budgets to the current structure. **The "Now" column is the `c8fb564` census**, which
is what the targets were derived from; §1's later columns have the head figures:

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
block is not free. Every conversion is checked, not assumed. [2026-09-29T22:31Z: the table was
verified under Nim 1.6.14 only and has not been re-run under 2.2.12, the compiler on this host. The
risk class is real: batch 8 reverted a move of `rowLabel`'s `##` that added a diagnostic.]

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

**The table above is the state at `c8fb564`.** Batches 6 and 7 cleared rows 2, 3 and 5, and most of
row 1. At `4acedfa0` the `css` string literal runs from `theme.nim:165` to `:640`; its first CSS
comment opens at line 185, and it holds 34 `/* … */` comments over 155 lines. They carry no hyphen
labels, but one plan-step label survives (`Step 13a`, `theme.nim:284`), several cite files by line
(`app.css:213-220` and `:166-198`, `adw.nim:653`, `ChatSidebar.svelte:177` and `:186-188`,
`ChatSidebarWorkspaceItem.svelte:27`), and one carries a date ("until 2026-08-31", `:192`) — all of
it CSS inside the string, to be edited as such. `Stage` is now `"harness with lifecycle; llama-server
is the engine"` (`jenova_core.nim:45`), the `hardware` help line has no label (`:65`), and no
`check()` description carries one. `%PDF-1.4` now sits in `attach-selftest` (`jenova_core.nim:903`,
`:987`, `:1007`, `:1052`). The `G-30` guard is now in `pipeline-selftest`'s
`settingsParityWithTheWebUi` block (`jenova_core.nim:5925`). It still runs, and it passes today
because the only two `awaiting` texts — `pdfAsImage` (`settings.nim:129`) and `autoMicOnEmpty`
(`:173`) — contain neither sentinel; it fails only if someone writes `Step 7b` or `G-30` into one
again. Rewriting it against the text `awaiting` actually carries is forward work — see PLANS.md.

### 4.3 ~~The build cannot be run here~~ — obsolete on both counts

**As written this section said `src/jenova_core.nim:19` and `src/jenova_gui.nim:20` refuse to
compile off FreeBSD, so no binary could be produced and no self-test executed. Neither half
still holds.**

The OS guards are gone. `jenova_core.nim`'s header records their removal and the argument for it:
nothing under `src/jenova/` carries an OS conditional, so there was no branch for the guard to
prevent, and the guard's cost was that every check ran against a patched copy and reported a
portability problem that does not exist. Report 07 §0 still describes neutralising those two lines
in a scratch tree; there is nothing left to neutralise.

And the environment moved. The workspace this is now read in is the FreeBSD target reached through
the Linuxulator, with Nim 2.2.10 native: both binaries build and the self-tests run directly.
[2026-09-29T22:31Z: superseded. That described the FreeBSD 15.1 host, the working host until
2026-09-10. The working host is now bare-metal Arch Linux with Nim 2.2.12: `nimble core` builds and
all 22 self-tests pass, and `nimble gui` fails under gcc 16.2 and clang 22.1 on `vte.nim`'s
`GdkRGBA` declaration — see PLANS.md. FreeBSD and Linux (Arch, Debian, Fedora) are both supported
targets by the USER's ruling of 2026-09-29 (DECISIONS_LOG 2026-09-29T22:29Z). The guards went in `b371225d` (reflog-only), which reached
main in `989c2b5d`.]

§5's harness remains useful as a comment-only differential, but it is no longer the *only* thing
achievable — a batch can now be gated on a real build and a real suite.

---

## 5. Verification

[2026-09-29T22:31Z: historical. `scratchpad/verify.sh` was session-local and is not in the tree;
the guards it neutralised are gone; `e495c8f` is reflog-only, its content in `989c2b5d`. Gate a
comment edit on `nimble core` and the self-tests, and on `nimble gui` once it builds on this host.]

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

[2026-09-29T22:31Z: historical — executed on 2026-09-03 in this order, one commit per batch, all
squashed into main in `989c2b5d` (#117). Original hashes, all reflog-only: batch 1 `8033bdd`,
2 `63a7440`, 3 `a5b98522`, 4 `8adf6666`, 5 `6d40a72a`, 6 `c2d0bede`, 7 `54103ad9`, 8 `28b1e52e`,
then a residue sweep `f3ebb8be` that also covered the newly added `shortcuts.nim`. Batch 0 landed in
AGENTS.md on 2026-09-09, narrowed to new and touched code. Nothing in this section is open work.]

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

The batches departed from the first two bullets. Batches 2, 4, 6 and 7 changed label-bearing
user-facing strings after checking each had no reader beyond being printed, the three named here
included. Two label-bearing strings are left: the `G-30` guard in `jenova_core.nim` and the
`Step 13a` inside `theme.nim`'s CSS string (§4.2). The `.devdocs/` trackers were recreated, without
labels, on 2026-09-09.

---

## 7. Recommendation

Start at batch 1 and stop after batch 2 for review. Those 18 files are 14% of the lines and 14%
of the comments, they carry every defect class except the CSS and FFI special cases, and they cost
little to redo if the target shape is not what you meant. `gui.nim` should not be attempted until
the standard has survived a review pass on real files.

[2026-09-29T22:31Z: historical, and not followed as written — batches 3 to 8 ran the same session
with no recorded review stop. Any further retrofit, including a V-17 strip of the cross-reference
lines §1 counts, needs an explicit USER instruction under AGENTS.md; see PLANS.md.]
