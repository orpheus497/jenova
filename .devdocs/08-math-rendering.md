# Report 08 — Math Rendering (P-A5): the plan

**Status:** plan, **no source changed**
**Ruling:** the USER put math **in scope** (session 9). Report 05's "Open decisions" item 1 —
*"Pango-drawn subset (native, limited), external TeX renderer (correct, heavy), or out of
scope"* — is answered here, and the answer is neither of the first two as posed.
**Method:** every capability claim below was **measured on a real host**, with the probe source
kept. Where a claim comes from a header, a library or `jca_web`'s own code it is quoted verbatim.
**Measured at commit:** `2f30d1c`

---

## 0. The decision, up front

**Build it natively, in two tiers, with no new library and no new process.** The measurements
below establish that the hard part — TeX-quality math metrics — is already linked into this
binary through Pango, and that the easy part needs nothing at all.

| | Tier 1 — inline | Tier 2 — display |
|---|---|---|
| Triggers | `$…$`, `\(…\)` | `$$…$$`, `\[…\]` |
| Output | Pango markup inside the existing `bkText` block | a new `bkMath` block drawn with Cairo |
| Needs | nothing new | a font with a usable OpenType MATH table |
| Handles | Greek, operators, sub/superscripts, upright vs italic | fractions, radicals, big operators, matrices, growable delimiters |
| Testable without a window | **entirely** — it is `string -> string` | **the layout, yes**; only the final blit is not |

**The split is not a compromise between ambition and effort.** It is what the two cases actually
are. An inline formula lives inside a wrapping, selectable paragraph and must flow with it;
splitting that paragraph into widgets to draw one symbol would break selection and wrapping for
every line that contains maths. A display formula is a block that owns its own line and needs
two-dimensional layout that no markup language can express. Tier 1 in a widget would be wrong;
Tier 2 in markup is impossible.

**Tier 1 alone is already worth shipping**, and it ships first: today `$\alpha$` renders as the
literal five characters `$\alpha$`.

### The three options as report 05 framed them

| Option | Verdict |
|---|---|
| External TeX renderer | **Rejected.** It needs a TeX installation, a process spawn per formula, and a temp file. `gui.nim`'s header documents exactly two process spawns and the argument for each; a third, per rendered formula, on the GTK thread, is not in the same class. It also fails offline-first: a formula that renders only when a toolchain is installed is a formula that usually does not render. |
| Pango-drawn subset | **Adopted as Tier 1 only.** Correct for inline, and provably incapable of display maths — Pango markup has no fraction, no radical and no vertical stacking. |
| Out of scope | Overtaken by the ruling. |
| **A native Cairo layout over the font's own MATH table** | **Adopted as Tier 2.** Not offered in report 05's framing, because the enabling fact below had not been measured: this needs no new dependency. |

---

## 1. The enabling measurement: the MATH table is already linked

```
$ pkg-config --libs pango
-lpango-1.0 -lgobject-2.0 -lglib-2.0 -lharfbuzz
$ pkg-config --modversion harfbuzz
8.3.0
$ ls /usr/include/harfbuzz/hb-ot-math.h        # present
```

**Pango links HarfBuzz, and HarfBuzz exposes the entire OpenType MATH table.** The full surface,
from `hb-ot-math.h`:

`hb_ot_math_has_data` · `hb_ot_math_get_constant` · `hb_ot_math_get_glyph_italics_correction` ·
`hb_ot_math_get_glyph_top_accent_attachment` · `hb_ot_math_get_glyph_kerning` ·
`hb_ot_math_get_glyph_variants` · `hb_ot_math_get_glyph_assembly` ·
`hb_ot_math_get_min_connector_overlap` · `hb_ot_math_is_glyph_extended_shape`

Those constants are the same quantities *The TeXbook*'s Appendix G lays out over — axis height,
numerator and denominator shifts, rule thickness, gaps, and the variant/assembly machinery that
grows a delimiter to fit its contents. **A math layout engine here needs no new library, no new
port entry, and no process.** That is the fact the whole plan rests on, and it is why "native"
stopped being the expensive option.

The window already draws with Cairo (`import owlkettle/cairo`) and already owns a
`DrawingArea`-backed renderable (`NeuralCanvas`), so the drawing surface is precedent, not new
ground.

---

## 2. The font policy, and the trap in it

### `hb_ot_math_has_data()` returning true is **not** sufficient

Measured with `scratchpad/mathprobe.c` (built against `pkg-config --cflags --libs harfbuzz`),
reading `AXIS_HEIGHT`, `FRACTION_NUMERATOR_SHIFT_UP` and `FRACTION_RULE_THICKNESS`, and counting
vertical glyph variants for `U+0028`:

| Font | axis | numShift | rule | `(` variants | verdict |
|---|---|---|---|---|---|
| DejaVuSans.ttf | 313 | **0** | 44 | **0** | advertises MATH; the table is a **stub** |
| DejaVuSerif.ttf | 313 | **0** | 44 | **0** | same |
| FreeSerif.ttf (GNU FreeFont) | 330 | 500 | 42 | 4 | **usable** |
| STIXMath-Regular.otf | 250 | 480 | 66 | 5 | good |
| latinmodern-math.otf | 250 | 394 | 40 | **8** | best — TeX's own metrics |
| texgyre{bonum,pagella,schola,termes,dejavu}-math.otf | 250–275 | 395–469 | 52–72 | 7 | good |

**DejaVu is the trap.** It ships on essentially every Unix desktop, it answers `has_data` with
true, and `FRACTION_NUMERATOR_SHIFT_UP = 0` means a fraction would draw its numerator *on the
baseline*, through the rule. Zero glyph variants means a delimiter can never grow. A probe that
asks only `has_data` picks DejaVu on almost every machine and renders confident nonsense.

**So the probe is three questions, not one:** `hb_ot_math_has_data(face)`, *and*
`FRACTION_NUMERATOR_SHIFT_UP != 0`, *and* at least one vertical variant for a known stretchy
delimiter. Walk a preference list — Latin Modern Math, STIX Two Math, a TeX Gyre math face,
FreeSerif — take the first that passes all three, and **if none does, degrade Tier 2 to Tier 1
rendering with a visible note rather than drawing something wrong.** A formula rendered badly is
worse than a formula rendered plainly, because only one of them tells the reader to distrust it.

**FreeBSD port names are deliberately not asserted here.** They must be read off the target with
`pkg search`, and `docs/install.md` updated from what that says — this session could not reach a
FreeBSD ports index and will not guess. What *is* safe to state: GNU FreeFont carries a usable
table, so **the fallback tier does not require a TeX installation**, and math is not gated on the
user installing anything.

---

## 3. Tier 1's primitives are verified against a real Pango parser

`scratchpad/pangoprobe.c` calls `pango_parse_markup()` directly:

```
pango runtime 1.52.1
x<sup>2</sup>                                  OK   text="x2"
a<sub>i</sub>                                  OK   text="ai"
<span rise='6000' size='smaller'>2</span>      OK   text="2"
&#945; &#8721; &#8747; &#8730;                 OK   text="α ∑ ∫ √"
<i>f</i>(<i>x</i>)                             OK   text="f(x)"
```

Everything Tier 1 needs parses: superscript, subscript, numeric character references for Greek
and operators, and italic — which is the one piece of real mathematical typography Pango gives
for free, since TeX sets variables in italic and function names upright.

**Two spellings work, and that matters for the target.** `<sup>`/`<sub>` are the newer tags;
`<span rise='…' size='smaller'>` is older and accepted wherever `rise` is. This host is Pango
1.52.1; **the FreeBSD target's Pango version was not checked in this session.** If `<sup>` is
used, that version is a precondition to verify with `pkg-config --modversion pango`. If it is not
verified, use the `rise` form, which needs no check. **Do not assert which Pango release added
`<sup>` without reading Pango's own NEWS — this session did not.**

Pango markup is XML, so `<`, `>` and `&` must be escaped before reaching it. `markdown.nim`
already solves this for `bkText`; **reuse that path, do not write a second escaper.** This is not
hypothetical tidiness — session 9 fixed three defects in the emphasis passes, one of which made
Pango reject an entire markup string and draw an empty label (report 02, second correction).
**Malformed markup does not degrade in Pango; it deletes the line.** Every Tier 1 output must go
through the same `markupBalanced` guard that fix introduced.

---

## 4. Delimiters and the boundary, from `jca_web`'s own source

`jca_web/src/lib/constants/latex-protection.ts`, verbatim:

```js
export const CODE_BLOCK_REGEXP = /(```[\s\S]*?```|`[^`\n]+`)/g;

export const LATEX_MATH_AND_CODE_PATTERN =
  /(```[\S\s]*?```|`.*?`)|(?<!\\)\\\[([\S\s]*?[^\\])\\]|(?<!\\)\\\((.*?)\\\)/g;

export const LATEX_LINEBREAK_REGEXP = /\$\$([\s\S]*?\\\\[\s\S]*?)\$\$/;

export const MHCHEM_PATTERN_MAP: readonly [RegExp, string][] = [
  [/(\s)\$\\ce{/g, "$1$\\\\ce{"],
  [/(\s)\$\\pu{/g, "$1$\\\\pu{"],
] as const;
```

Four obligations follow, and the third is the one that gets missed:

1. **Delimiters:** `\(…\)` and `$…$` inline; `\[…\]` and `$$…$$` display.
2. **Code is excised first.** A `$` inside a fenced block or a code span is never maths.
   `markdown.nim` already separates `bkCode`, which covers fenced blocks; the **inline span**
   half still has to be handled within `bkText`.
3. **`(?<!\\)` is load-bearing, and the Web UI's comment cites its sources**: `Definitions\\(also
   called macros)` — the title of chapter 20 of *The TeXbook* — and `\\[4pt]`, a LaTeX line
   break. An escaped delimiter is not maths. Getting this wrong turns ordinary prose into a
   formula, which is a worse failure than not rendering at all.
4. **mhchem (`\ce{}`, `\pu{}`) is out of scope.** It is a KaTeX extension for chemistry. Stating
   that is not optional: P-C1 is this project's standing lesson that an unstated omission reads
   as work forgotten rather than deferred.

**One more boundary, which `jca_web` does not have to face.** A reply *streams*. A `$$` arrives
before its closing `$$`, so a half-open display formula must render as its own literal source
until it closes, and must not swallow the rest of the transcript while the model is still
typing. Same for a lone `$`. This is the streaming analogue of the unpaired-`**` defect session 9
fixed, and it needs assertions of its own.

---

## 5. Where it lands

| Site | Change |
|---|---|
| `src/jenova/markdown.nim:8` | `BlockKind` gains `bkMath` — a fourth case beside `bkText`, `bkCode`, `bkTable` |
| `src/jenova/markdown.nim` | inline math becomes part of the `bkText` markup pass, beside the emphasis passes and **behind the same `markupBalanced` guard** |
| new `src/jenova/mathtex.nim` | the parser and the box layout. Pure: `string -> tree -> boxes`. No GTK, no Cairo, no owlkettle — so it links into `jenova-core` and is asserted there |
| new `src/jenova/mathfont.nim` | the three-question font probe and the HarfBuzz MATH constants. Thin FFI, the shape `sourceview.nim` already uses |
| `src/jenova/gui.nim` | one more branch beside `bkText` (`:3373`) and `bkTable` (`:3388`), drawing a `bkMath` box tree on a `DrawingArea` renderable modelled on `NeuralCanvas` |

**`mathtex.nim` must not import owlkettle.** That is what keeps the layout assertable: `gui.nim`
links into no test binary, which is why `composer.nim` and `convmd.nim` exist. The parser and the
box layout are the part that will have the bugs, and they are the part that can be tested.

---

## 6. Phasing

Each phase is independently shippable and independently useful. **Stop after any of them and the
window is better than it was.**

| Phase | Delivers | Gate |
|---|---|---|
| **M-1** | Inline Tier 1: Greek and operator names to Unicode, `^`/`_` to sup/sub, italic variables, upright function names. Delimiter detection with the `(?<!\\)` rule, code-span exclusion, and streaming half-open handling | `markdown-selftest` — assertions for every negative case in §4, plus the streaming ones |
| **M-2** | `mathtex.nim`: parse to a tree, lay out to boxes over TeXbook Appendix G rules. **No drawing at all.** Fractions, scripts, radicals, big operators, matrices, stretchy delimiters | new `math-selftest`, registered in **both** `jenova_core.nimble`'s `SelfTests` and `jenova_core.nim`'s `usage()`. Assert box positions and sizes as numbers |
| **M-3** | `mathfont.nim` and the Cairo draw: `bkMath` renders. Font probe with the three-question test and the honest degrade path | `tests/gui_build.sh` seeds a conversation containing a display formula and photographs it. Report 07 V-14 applies — the gate must actually build the branch |
| **M-4** | Polish: display-math alignment, `\begin{align}`, spacing classes (ord/op/bin/rel), and `docs/usage.md` stating exactly which LaTeX subset is supported | assertions per feature; **the doc must name what is *not* supported**, per §4.4 |

**M-1 is the whole of the visible win for most replies.** M-2 is the real engineering and it is
pure, testable code. M-3 is the smallest of the three and the only one that needs a window.

---

## 7. What this plan does not do, stated rather than discovered later

* **No mhchem**, no `\begin{tikzpicture}`, no macro definition (`\newcommand`), no `\usepackage`.
  The subset is "what a chat model writes in a reply", not "LaTeX".
* **No MathML**, in or out.
* **No copy-as-LaTeX from a rendered formula** in M-1…M-4. The source is in `messages.content`
  and message-level Copy already yields it; a per-formula copy is a later call site, not a
  mechanism, exactly as P-B4's per-block copy turned out to be.
* **No selection inside a display formula.** A Cairo-drawn block is a picture to GTK. That is a
  real regression against the Web UI, where KaTeX output is selectable HTML, and it is the honest
  price of not shipping a browser. Inline maths — the common case — stays selectable, because
  Tier 1 keeps it inside the paragraph's own `Label`.
* **The FreeBSD font port names and the target's Pango version are unverified** (§2, §3). Both
  are preconditions to check on the target before M-3 lands, not assumptions to build on.

---

## 8. The font question, asked and then answered

An earlier draft of this report left one open question for the USER: which font Tier 2 should
prefer, and whether it may be a dependency. **It is withdrawn — it answers itself, and it was
posed against a misreading of this project's own install rule.**

### What was actually at stake

Only two things: the order of the preference list in §2, and whether `docs/install.md` gains a
line. The program probes fonts at startup, takes the first that passes all three questions, and
degrades to plain text if none does. It renders either way.

### Why it looked like a blocker

`docs/install.md:46`, verbatim:

> Everything installs from `pkg(8)`. **There is no optional tier** — a package that cannot be
> installed stops the build.

So a "recommended font" appeared to have nowhere to live: either a hard build dependency, or a
violation of a stated rule.

### Why it is not one

**That rule is about packages that stop the build.** A maths font stops nothing — it is not
linked, not called, not read at compile time, and its absence produces a correct render in a
plainer face or, in the worst case, the same plain text the transcript shows today. It is not the
kind of thing that table describes, so it does not belong in that table, and the rule is not in
tension with anything.

The misreading was treating "no optional tier" as "no optional anything". `docs/install.md`
already distinguishes these: `fetch(1)` is tried before `curl` and the document says so at `:92`
— *"`curl` is the fallback, not an optional extra"* — which is a runtime preference between two
things, described outside the dependency table. A font preference is the same shape.

### The decision

| | |
|---|---|
| **Preference order** | Latin Modern Math → STIX Two Math → a TeX Gyre math face → FreeSerif → **plain text with a visible note** |
| **`docs/install.md`** | **unchanged.** No font is added to the dependency table, because no font can stop the build |
| **`docs/usage.md`** | states, where the maths feature is documented, that a maths font improves the result, names Latin Modern Math, and says what happens without one |
| **Rationale** | Latin Modern's constants *are* TeX's — it is the digital descendant of the font Knuth designed for it — and it carries 8 delimiter sizes against FreeSerif's 4. But FreeSerif is far more likely to be present already, and it is genuinely usable (§2), so the fallback is not a consolation prize |

**M-3 therefore has no precondition on the USER.** The two real preconditions stand and are
technical, not editorial: read the FreeBSD font port names off the target with `pkg search`
before writing them into any document (§2), and check the target's Pango version before relying
on `<sup>` rather than the `rise` spelling (§3).
