# Report 08 — Math Rendering (P-A5): the plan

**Status as of 2026-09-29T22:38Z (baseline `4acedfa0`; host Arch Linux).** M-1, M-2 and M-3 are
implemented: inline markup in `markdown.nim`, layout in `mathtex.nim`, the font in `mathfont.nim`,
and `gui.nim`'s `bkMath` draw — size variants drawn by FreeType glyph index, the formula's own LaTeX
source as the fallback, and a layout whose metrics come partly from HarfBuzz: the MATH constants,
a glyph's horizontal advance, and a size variant's advance and italic correction are the font's,
while a glyph's ascent and descent are fixed fractions of the size (0.75/0.25, italic correction
0.08 of the size) and a variant's are 0.8/0.2 of its advance, with its width fixed at 0.55 of the
size. Open: M-4, and M-3's screenshot gate. §9 lists the remaining work and §10
the maths fonts per OS; forward work is in PLANS.md.
**Re-checked 2026-09-30T01:16Z:** every claim a code verification flagged was read against the code
and corrected in place.

**Ruling:** the USER put math **in scope** (session 9). Report 05's "Open decisions" item 1 —
*"Pango-drawn subset (native, limited), external TeX renderer (correct, heavy), or out of
scope"* — is answered here, and the answer is neither of the first two as posed.
**Method:** every capability claim below was **measured on a real host**, with the probe source
kept. Where a claim comes from a header, a library or `jca_web`'s own code it is quoted verbatim.
[2026-09-29T22:38Z: the probe sources, `mathprobe.c` and `pangoprobe.c`, were session-local and
are not in the tree.]
**Measured at commit:** `2f30d1c` (reflog-only; its content reached main in `989c2b5d`)

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
literal seven characters `$\alpha$`. *(It said five. It is seven — counted after the fact, which
is exactly the kind of number this report is supposed to measure rather than estimate.)*
[2026-09-29T22:38Z: shipped — `markdown.inlineMarkup` renders it as α.]

### The three options as report 05 framed them

| Option | Verdict |
|---|---|
| External TeX renderer | **Rejected.** It needs a TeX installation, a process spawn per formula, and a temp file. `gui.nim`'s own code starts processes for two purposes — `route`/`ifconfig` for the LAN address and `xdg-open` for the Web UI, both through `runOutput` — and the window reaches more through the modules it calls: `lifecycle` forks and execs the backends, `nvimctl` runs `nvim --server … --remote-expr`, and `vte.nim` spawns the editor in its terminal. One more per rendered formula, on the GTK thread, is not in the same class as any of those. It also fails offline-first: a formula that renders only when a toolchain is installed is a formula that usually does not render. |
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
grows a delimiter to fit its contents. **A math layout engine here needs no package outside the
GTK/Pango/Cairo stack, and no process.** That is the fact the whole plan rests on, and it is why
"native" stopped being the expensive option. It is not "no new library" in the build, though: the
code links HarfBuzz explicitly — `pkgConfig("harfbuzz", "print/harfbuzz")` in `mathfont.nim`, which
`jenova_core.nim` also imports for `math-selftest`, so `jenova-core` links it too — and M-3's
glyph-index draw links FreeType into the window (`pkgConfig("freetype2", "print/freetype2")` in
`gui.nim`). Both are build-time pkg-config requirements, so a build without their development files
fails, even though GTK, Pango and Cairo depend on the same libraries. The install docs list neither —
see PLANS.md. The Arch host has HarfBuzz 14.5.0 and Pango 1.58.2, and `hb-ot-math.h` is present.

The window already draws with Cairo (`import owlkettle/cairo`) and already owns a
`DrawingArea`-backed renderable (`NeuralCanvas`), so the drawing surface is precedent, not new
ground.

---

## 2. The font policy, and the trap in it

### `hb_ot_math_has_data()` returning true is **not** sufficient

Measured with `scratchpad/mathprobe.c` (session-local; built against `pkg-config --cflags --libs harfbuzz`),
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
delimiter. Walk a preference list, take the first that passes all three, and **if none does,
render something plain with a visible note rather than draw something wrong.** A formula rendered
badly is worse than a formula rendered plainly, because only one of them tells the reader to
distrust it.

As built (`mathfont.chooseFont`): if `JENOVA_MATH_FONT` is set, that file is the only font tried,
and an unusable one is reported as not found with no fallback search. Otherwise one walk of five
fixed font roots collects candidates, and the first copy of these, in this order, that passes all
three checks wins: `latinmodern-math.otf`, `STIXTwoMath-Regular.otf`, `STIXMath-Regular.otf`,
`DejaVuMathTeXGyre.ttf`, `texgyrepagella-math.otf`, `texgyretermes-math.otf`, `FreeSerif.ttf`. The
degrade, as §8 decides, is to plain source rather than Tier 1: a display formula with no usable font
— or one the parser refuses — renders as its literal LaTeX in a plain `Label` inside a code-block
frame, and with no font `mathfont.unavailableReason` sits beside it, naming the files and
directories searched.

**FreeBSD port names are deliberately not asserted here.** They must be read off the target with
`pkg search`, and `docs/install.md` updated from what that says — this session could not reach a
FreeBSD ports index and will not guess. What *is* safe to state: GNU FreeFont carries a usable
table, so **the fallback tier does not require a TeX installation**, and math is not gated on the
user installing anything. [2026-09-29T22:38Z: the targets are now FreeBSD and Linux (Arch, Debian,
Fedora). §10 lists what is known per OS — verified for Arch only — and §8 puts the recommendation
in docs/usage.md, not docs/install.md.]

---

## 3. Tier 1's primitives are verified against a real Pango parser

`scratchpad/pangoprobe.c` (session-local) calls `pango_parse_markup()` directly:

```
pango runtime 1.52.1
x<sup>2</sup>                                  OK   text="x2"
a<sub>i</sub>                                  OK   text="ai"
<span rise='6000' size='smaller'>2</span>      OK   text="2"
&#945; &#8721; &#8747; &#8730;                 OK   text="α ∑ ∫ √"
<i>f</i>(<i>x</i>)                             OK   text="f(x)"
```

Everything in that probe parses: superscript, subscript, numeric character references, and
italic — the last being the one piece of real mathematical typography Pango gives for free, since
TeX sets variables in italic and function names upright.

> **Correction, made while implementing M-1: the numeric-character-reference line above was the
> wrong verification, and it contradicted a requirement two paragraphs below.** Pango does accept
> `&#945;`, which is what the probe shows. But this codebase does not let a string reach Pango
> unchecked — every markup fragment must pass `markupBalanced`, and that guard
> (its `'&'` branch, `src/jenova/markdown.nim:128-131`) accepts exactly five entity names:
>
> ```nim
> if semi < 0 or s[i + 1 ..< semi] notin ["amp", "lt", "gt", "quot", "apos"]:
>   return false
> ```
>
> A `&#945;` therefore fails the guard and the Greek letter never draws. (As built, the guard runs
> per formula first: `mathMarkup` returns an empty string for a fragment that fails
> `markupBalanced`, and `inlineMarkup` then leaves only that formula's source visible while the rest
> of the line still renders; the whole-line fallback is not reached for this case.) **The two requirements in this section could not both be satisfied**,
> and the error was verifying the wrong layer: the toolkit's parser rather than the guard this
> project puts in front of it. M-1 emits the UTF-8 codepoint directly, which needs no entity, no
> guard exemption and no probe.

**Two spellings work, and that matters for the target.** `<sup>`/`<sub>` are the newer tags;
`<span rise='…' size='smaller'>` is older and accepted wherever `rise` is. This host is Pango
1.52.1; **the FreeBSD target's Pango version was not checked in this session.** If `<sup>` is
used, that version is a precondition to verify with `pkg-config --modversion pango`. If it is not
verified, use the `rise` form, which needs no check. **Do not assert which Pango release added
`<sup>` without reading Pango's own NEWS — this session did not.** [2026-09-29T22:38Z: settled by
construction — M-1 uses the `rise` form (`MathSup`/`MathSub` in `markdown.nim`), so no Pango version
needs checking on any target. The Arch host has Pango 1.58.2.]

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
   `markdown.nim` separates `bkCode`, which covers fenced blocks. The **inline span** half is
   handled inside `bkText` too: `inlineMarkup` lifts code spans into NUL-delimited placeholders
   before the maths pass, and `mathItem` refuses any formula containing a placeholder byte;
   `markdown-selftest` asserts both.
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

[2026-09-29T22:38Z: every site landed. The `gui.nim` branch is `mdBlock`'s `bkMath` case — at
`4acedfa0` `bkText` is `:3717`, `bkTable` `:3732` and `bkMath` `:3759`. It draws on owlkettle's own
`DrawingArea` inside a `ContentScroll`, not a `NeuralCanvas`-style renderable.]

**`mathtex.nim` must not import owlkettle.** That is what keeps the layout assertable: `gui.nim`
links into no test binary, which is why `composer.nim` and `convmd.nim` exist. The parser and the
box layout are the part that will have the bugs, and they are the part that can be tested.

---

## 6. Phasing

Each phase is independently shippable and independently useful. **Stop after any of them and the
window is better than it was.**

| Phase | Delivers | Gate |
|---|---|---|
| **M-1** ✅ | Inline Tier 1: Greek and operator names to Unicode, `^`/`_` to sup/sub, italic variables, upright function names. Delimiter detection with the `(?<!\\)` rule, code-span exclusion, and streaming half-open handling | `markdown-selftest` — assertions for every negative case in §4, plus the streaming ones |
| **M-2** ✅ | `mathtex.nim`: parse to a tree, lay out to boxes over TeXbook Appendix G rules. **No drawing at all.** Fractions, scripts, radicals, big operators, matrices, stretchy delimiters | new `math-selftest`, registered in **both** `jenova_core.nimble`'s `SelfTests` and `jenova_core.nim`'s `usage()`. Assert box positions and sizes as numbers |

> **Three corrections from implementing M-2. All three are errors in this report.**
>
> 1. **`\int` does not take limits above and below, and saying it did would have made every
>    integral in every reply look wrong.** The M-2 row above lists it beside `\sum` and
>    `\prod`. TeX sets it `\nolimits` — plain TeX defines `\int` as `\intop\nolimits` — so
>    an integral's bounds sit *beside* the sign, not stacked on it, and KaTeX follows TeX.
>    Implemented TeX's way, with `\limits`/`\nolimits` overrides, asserted in both directions.
> 2. **The MATH table does not supply matrix column and row spacing.** §1 implies every layout
>    constant comes from the font; there is no such constant, because TeX takes these from
>    `\arraycolsep` and `\baselineskip` rather than from a font. They are two extra
>    `MathConstants` fields, documented as *not* font values, and M-3 must choose them.
> 3. **This report never says what a refused formula renders as.** `renderMath` returns
>    `ok = false` with an **empty** box, so M-3's `bkMath` branch must fall back to the original
>    source string the caller still holds. An unstated fallback is an empty block on screen.
>
> The M-2 interface, since M-3 draws with it: `MathBox` is `{x, y, width, ascent, descent,
> italicCorrection}` plus `bxGlyph` / `bxRule` / `bxList`. **y grows down, the origin is the left
> edge on the baseline, and ascent/descent are positive distances.** One container kind, because
> a child carrying both `x` and `y` needs no second packing rule — drawing is translate and
> recurse. `MathFont` is `MathConstants` plus two closures, `measure` and `variants`, so the
> module imports only `std/[strutils, tables]` and stays assertable without a font.
| **M-3** ✅ (2026-09-10; gate open) | `mathfont.nim` done — the three-question probe, the constants reader, and a fallback table. The Cairo draw is done too: `bkMath` draws size variants by FreeType glyph index and falls back to its own source; its layout takes the MATH constants, horizontal advances, and variant advances and italic correction from HarfBuzz, while glyph ascent and descent are fixed fractions of the size and no glyph extents are read from the font. Font probe with the three-question test and the honest degrade path | `tests/gui_build.sh` seeds a conversation containing a display formula and photographs it. Report 07 V-14 applies — the gate must actually build the branch. **Open:** `gui_build.sh` seeds no formula, and its mapped-window tier cannot run on this host (no Xvfb, xdotool or xclip) |

> **M-3's draw had a prerequisite this report never stated, and it is now closed.** The two
> modules declared *separate* `MathConstants` types — `mathfont`'s of 24 fields, `mathtex`'s of 44
> — and nothing converted between them, so the mismatch could not fail: `readConstants` had no
> caller and `renderMath`'s only caller was the self-test, which built its table by hand.
>
> **The fix is not a bridge. It is one type.** A converter between two structures is a third thing
> to keep in step, and the reason this went unnoticed is precisely that two declarations of the
> same table drifted without either file being wrong on its own. `mathtex` declares
> `MathConstants` — it is the consumer, and it is the pure half that stays assertable without a
> font — and `mathfont` now imports it and fills it in. There is no second declaration to drift.
> A field the layout adds is not a type error, though: `MathConstants` is a plain object with no
> `{.requiresInit.}`, so a constructor that omits the field still compiles and leaves it at 0.0. The
> build fails only through the `static:` block's `fieldPairs` walk over `defaultConstants()`;
> `readConstants` is unchecked and would read the new field as zero at run time until it is added
> there.
>
> What the old reader actually did, recorded because the shape of it is the lesson: it filled 24
> of the 44 fields, left 20 at zero, and read **five display-style constants into the text-style
> fields beside them** — `FRACTION_NUMERATOR_DISPLAY_STYLE_SHIFT_UP` into `fractionNumeratorShiftUp`
> and the same substitution for the denominator shift, both fraction gaps and the radical gap. A
> display value in a text position renders *plausibly*: every inline fraction set with the shifts
> of a displayed one. That is the error a reader distrusts last, which is why §0's argument — a
> formula drawn badly is worse than one drawn plainly — applies to the metrics and not only to the
> glyphs.
>
> **Guarded at compile time, as far as a compile-time guard can reach.** `mathfont`'s `static:`
> block pins four ordinals to their `hb_ot_math_constant_t` values (0, 55, 5 and 38) — the others
> are not checked against HarfBuzz — asserts for all eight text/display pairs that the display-style
> constant immediately follows its text-style one (which catches a transposition in the enum),
> walks `defaultConstants()` with `fieldPairs` to refuse any field left at zero, naming it, and
> asserts that display-style values exceed their text-style partners in the default table. What it
> cannot reach is `readConstants`, which runs at run time against a font: reading a display-style
> constant into a text-style field there, or omitting a field from its constructor, still compiles.
> So a mis-numbered paired ordinal or a zero field in `defaultConstants` fails the build — only the
> latter names the field — while the original reader's mapping would not.
>
> Two values are still not font values and are stated as such: the `MATH` table has no matrix
> column or row spacing, so those come from plain TeX — the `\quad` `\matrix` puts between columns,
> and `\jot` between the lines of a display. §6's correction 2 predicted exactly this and it holds.

| **M-4** — open, not started (§9) | Polish: display-math alignment, `\begin{align}`, spacing classes (ord/op/bin/rel), and `docs/usage.md` stating exactly which LaTeX subset is supported | assertions per feature; **the doc must name what is *not* supported**, per §4 item 4 |

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
  price of not shipping a browser. Inline maths — the common case — sits inside the paragraph's own
  markup `Label` through Tier 1, but that `Label` is not selectable either: owlkettle's `Label` at
  `ac61ecf` has no `selectable` property and nothing in `src/` calls `gtk_label_set_selectable`, so
  no transcript text is selectable in the window.
* **The FreeBSD font port names and the target's Pango version are unverified** (§2, §3). Both
  are preconditions to check on the target before M-3 lands, not assumptions to build on.
  [2026-09-29T22:38Z: M-3 landed without either. The Pango question is moot because M-1 uses
  `rise`. The font packages are now a four-OS question — §10, with the recommendation to go in
  docs/usage.md; see PLANS.md.]

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

`docs/install.md:53` (`:46` when this was written), verbatim:

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
already distinguishes these: `fetch(1)` is tried before `curl` and the document says so at `:99`
(`:92` when this was written) — *"`curl` is the fallback, not an optional extra"* — which is a
runtime preference between two things, described outside the dependency table. A font preference
is the same shape.

### The decision

| | |
|---|---|
| **Preference order** | Latin Modern Math → STIX Two Math → a TeX Gyre math face → FreeSerif → **plain text with a visible note** |
| **`docs/install.md`** | **unchanged.** No font is added to the dependency table, because no font can stop the build |
| **`docs/usage.md`** | states, where the maths feature is documented, that a maths font improves the result, names Latin Modern Math, and says what happens without one |
| **Rationale** | Latin Modern's constants *are* TeX's — it is the digital descendant of the font Knuth designed for it — and it carries 8 delimiter sizes against FreeSerif's 4. But FreeSerif is far more likely to be present already, and it is genuinely usable (§2), so the fallback is not a consolation prize |

[2026-09-29T22:38Z: as built, `mathfont.FontCandidates` runs Latin Modern Math → STIX Two Math →
STIX Math → DejaVu Math TeX Gyre → TeX Gyre Pagella Math → TeX Gyre Termes Math → GNU FreeSerif
(`FreeSerif.ttf`) → the formula's source with a note. It lacks TeX Gyre Bonum, Schola and DejaVu as
`.otf`, `FreeSerif.otf`, Noto Sans Math and Libertinus Math (§9). docs/install.md is unchanged, as
decided. docs/usage.md has no maths section yet — that is M-4 (§9).]

**M-3 therefore has no precondition on the USER.** The two real preconditions stand and are
technical, not editorial: read the FreeBSD font port names off the target with `pkg search`
before writing them into any document (§2), and check the target's Pango version before relying
on `<sup>` rather than the `rise` spelling (§3). [2026-09-29T22:38Z: M-3 shipped with neither
check, and the Pango one no longer applies (§7). The package-name check now covers four OSes (§10).
Since GPL is allowed (USER ruling, DECISIONS_LOG 2026-09-29T22:29Z), GNU FreeFont may be recommended; whether a maths font
should be named as a recommended package per OS is the USER's call — see PLANS.md.]

---

## 9. Remaining work

As of 2026-09-29T22:38Z; sequenced in PLANS.md.

- **Base glyphs can come from a different font than the one measured.** `initMathFont` stores the
  preference-list label as the family, and `drawMathBox` draws every non-variant glyph through
  Cairo's toy text API by that name. "GNU FreeSerif" and "JENOVA_MATH_FONT" are not fontconfig
  family names, so fontconfig substitutes (here `fc-match 'GNU FreeSerif'` → Noto Serif). Draw base
  glyphs by index through the FreeType face already opened for size variants.
- **Italic is a synthetic slant** of the maths face, not the Mathematical Alphanumeric Symbols.
- **`buildMathLayoutFont`'s metrics are proportions, not glyph extents:** ascent 0.75 em, descent
  0.25 em, italic correction 0.08 em, 0.55 em for a rune the font lacks; variants take a 0.55 em
  width and a 0.8/0.2 split of their advance.
- **No glyph assembly.** Past the tallest size variant, `drawMathBox` stretches that glyph;
  `hb_ot_math_get_glyph_assembly` is unbound.
- **The fallback frame hides why** a formula was refused (`MathLayout.error`), and an unusable
  `JENOVA_MATH_FONT` gets the generic "No usable maths font found" text.
- **M-3's gate:** seed a display formula in `tests/gui_build.sh` and photograph it. That needs Xvfb,
  xdotool and xclip, which this host lacks.
- **Font discovery.** `FontRoots` lacks the TeX Live trees — `/usr/share/texmf-dist/fonts` (Arch),
  `/usr/share/texlive/texmf-dist/fonts` (Fedora, Debian's texlive), `/usr/local/share/texmf-dist/fonts`
  (FreeBSD) — and user font directories; `walkDirRec`'s defaults also skip symlinked files and
  directories. `FontCandidates` lacks `FreeSerif.otf` (the only form Arch ships),
  `texgyre{bonum,schola,dejavu}-math.otf`, `NotoSansMath-Regular.ttf` and
  `LibertinusMath-Regular.otf`. Each must pass `usable`'s three questions before joining; Noto and
  Libertinus are unverified.
- **M-4.** TeX's inter-atom spacing table over `AtomClass` — the classes exist, `layoutRow` inserts
  no space, and there is no inner class. `align`, `aligned`, `cases`, `gather`, `array` and a
  top-level `\\` line break, which are today refused by name or drawn as a literal `\\`. And a
  maths section in docs/usage.md: the delimiters, the supported commands and environments, what is
  not supported (§7, plus the environments above until they land), the source fallback,
  `JENOVA_MATH_FONT`, and a font note naming Latin Modern Math. The code is a few hundred lines in
  `mathtex.nim` plus `math-selftest` assertions; `gui.nim` is unaffected.

## 10. Maths fonts per OS

Arch is verified from this host's pacman sync and file databases as of 2026-09-29T22:38Z. The
other rows are best knowledge — confirm with `pkg search`, `apt-file` or `dnf provides` before
documenting them.

| OS | Found by today's `mathfont` | Missed |
|---|---|---|
| **Arch** (verified) | `otf-latinmodern-math` → `/usr/share/fonts/OTF/latinmodern-math.otf`; `ttf-dejavu` → `DejaVuMathTeXGyre.ttf`, the face chosen on this host | `gnu-free-fonts` ships `FreeSerif.otf`, not `.ttf`. `texlive-fontsrecommended` and `texlive-fontsextra` (Latin Modern, TeX Gyre, STIX Two and STIX maths) sit under `/usr/share/texmf-dist`, which is not searched. `noto-fonts` (Noto Sans Math, installed here) and `otf-libertinus` are not candidates. `tex-gyre-fonts` has no maths faces |
| **Debian** (best knowledge) | `fonts-lmodern` and `fonts-texgyre-math` under `/usr/share/texmf/fonts`; `fonts-freefont-ttf` → `/usr/share/fonts/truetype/freefont/FreeSerif.ttf` | `fonts-freefont-otf`; TeX Live under `/usr/share/texlive`; Noto Sans Math (`fonts-noto-core`); `fonts-stix` and `fonts-dejavu-extra` unconfirmed |
| **Fedora** (best knowledge) | `latinmodern-math-fonts` → `/usr/share/fonts/latinmodern-math/` | `texlive-*` under `/usr/share/texlive`; `stix-math-fonts` and `gnu-free-serif-fonts` depend on their file names; Noto Sans Math |
| **FreeBSD** (best knowledge) | `x11-fonts/stix-fonts`, `x11-fonts/freefont-ttf`, `x11-fonts/dejavu` under `/usr/local/share/fonts`, if their file names match | `print/texlive-texmf` under `/usr/local/share/texmf-dist`; no standalone Latin Modern Math port confirmed |
