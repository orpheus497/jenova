## Script function and purpose: the maths font — choosing one, and reading the
## layout constants out of it (P-A5, report 08 phase M-3).
##
## ## Why a font is involved in laying out a formula at all
##
## Drawing a fraction is not "numerator, rule, denominator". It needs numbers:
## how far above the rule the numerator sits, how thick the rule is, where the
## rule sits relative to the middle of the line, how much a `(` must grow to
## wrap two stacked lines. **Those numbers live inside the font file**, in an
## OpenType table called `MATH` — TeX keeps the same quantities in its own font
## metric files, and *The TeXbook*'s Appendix G is the algorithm that consumes
## them. A layout engine does not invent them; it reads them from whichever
## font it has been pointed at.
##
## `mathtex.nim` therefore takes a `MathConstants` as an argument and stays
## pure, which is what makes its geometry assertable without a font, a window
## or a display. **This module is the impure half**: it is the only place that
## touches a font file, and it hands `mathtex` a filled-in table.
##
## ## Why this needs no new dependency
##
## `pkg-config --libs pango` returns `-lharfbuzz`. Pango is built on HarfBuzz,
## the window already links Pango through GTK, and HarfBuzz exposes the entire
## `MATH` table through `hb-ot-math.h`. So TeX-quality metrics were already
## linked into this binary before a line of this was written — which is the
## fact that made a native layout cheaper than shelling out to a TeX
## installation, and is recorded in report 08 §1.
##
## ## The trap this module exists to avoid
##
## **`hb_ot_math_has_data()` answering true is not sufficient, and the
## counterexample ships on nearly every desktop.** Measured, not assumed:
##
## | Font | axisHeight | fracNumShift | `(` variants |
## |---|---|---|---|
## | DejaVu Sans / Serif | 313 | **0** | **0** |
## | FreeSerif (GNU FreeFont) | 330 | 500 | 4 |
## | STIX Two Math | 250 | 480 | 5 |
## | Latin Modern Math | 250 | 394 | 8 |
##
## DejaVu advertises a `MATH` table and answers `has_data` with true, but its
## `FRACTION_NUMERATOR_SHIFT_UP` is **zero** — a fraction would draw its
## numerator on the baseline, through its own rule — and it carries no glyph
## variants, so a delimiter could never grow. A probe that asks only
## `has_data` picks DejaVu on almost every machine and renders confident
## nonsense.
##
## So `usable` asks **three** questions, not one, and `chooseFont` walks a
## preference list taking the first that passes all three. When none does,
## the caller is told so and renders the formula as plain text: **a formula
## drawn badly is worse than one drawn plainly, because only one of the two
## tells the reader to distrust it.**
##
## No font is a build dependency and none is in `docs/install.md`. A font
## cannot stop the build, so it does not belong in the table that lists things
## which can; the preference is a runtime one, the same shape as `fetch(1)`
## before `curl`.

import std/[os, strutils]
import ./pkgconfig

# Through the template and not a bare `staticExec`, for the reason
# `pkgconfig.nim` gives: `staticExec` discards the exit status, so on a machine
# without HarfBuzz pkg-config's own error text is spliced into `passC`/`passL`
# and the build ends in compiler errors naming no missing dependency. This was
# the last hand-written binding still doing it (report 07, V-04).
pkgConfig("harfbuzz", "print/harfbuzz")

type
  HbBlob = distinct pointer
  HbFace = distinct pointer
  HbFont* = distinct pointer
  HbBool = cint
  HbPosition = cint
  HbCodepoint = uint32

  ## `hb_ot_math_constant_t`, by ordinal. Only the constants the layout
  ## actually consumes are named: an enum that mirrors all fifty-six would be
  ## fifty-six chances to mistype an ordinal for no gain, and a wrong ordinal
  ## reads a real value from the wrong field, which is the failure mode that
  ## looks like a subtle layout bug rather than an error.
  MathConstant* = enum
    mcScriptPercentScaleDown = 0
    mcScriptScriptPercentScaleDown = 1
    mcDisplayOperatorMinHeight = 3
    mcAxisHeight = 5
    mcSubscriptShiftDown = 8
    mcSubscriptTopMax = 9
    mcSubscriptBaselineDropMin = 10
    mcSuperscriptShiftUp = 11
    mcSuperscriptBottomMin = 13
    mcSuperscriptBaselineDropMax = 14
    mcSubSuperscriptGapMin = 15
    mcSpaceAfterScript = 17
    mcUpperLimitGapMin = 18
    mcUpperLimitBaselineRiseMin = 19
    mcLowerLimitGapMin = 20
    mcLowerLimitBaselineDropMin = 21
    mcStackTopDisplayStyleShiftUp = 23
    mcStackBottomDisplayStyleShiftDown = 25
    mcStackDisplayStyleGapMin = 27
    mcFractionNumeratorShiftUp = 32
    mcFractionNumeratorDisplayStyleShiftUp = 33
    mcFractionDenominatorShiftDown = 34
    mcFractionDenominatorDisplayStyleShiftDown = 35
    mcFractionNumeratorGapMin = 36
    mcFractionNumDisplayStyleGapMin = 37
    mcFractionRuleThickness = 38
    mcFractionDenominatorGapMin = 39
    mcFractionDenomDisplayStyleGapMin = 40
    mcOverbarVerticalGap = 43
    mcOverbarRuleThickness = 44
    mcOverbarExtraAscender = 45
    mcRadicalVerticalGap = 49
    mcRadicalDisplayStyleVerticalGap = 50
    mcRadicalRuleThickness = 51
    mcRadicalExtraAscender = 52

const
  ## `hb_direction_t`. `TTB` is what a growable delimiter grows along.
  HbDirectionTtb = cint(6)
  ## The em this module reports in. Every value out of here is in these units,
  ## so a caller scales by `pointSize / UnitsPerEm` and nothing has to know
  ## what the font's own `unitsPerEm` happens to be.
  UnitsPerEm* = 1000

{.push cdecl, importc.}
proc hb_blob_create_from_file(path: cstring): HbBlob
proc hb_blob_destroy(b: HbBlob)
proc hb_face_create(b: HbBlob, index: cuint): HbFace
proc hb_face_destroy(f: HbFace)
proc hb_font_create(f: HbFace): HbFont
proc hb_font_destroy(f: HbFont)
proc hb_font_set_scale(f: HbFont, xScale, yScale: cint)
proc hb_font_get_nominal_glyph(f: HbFont, unicode: HbCodepoint,
                               glyph: var HbCodepoint): HbBool
proc hb_ot_math_has_data(f: HbFace): HbBool
proc hb_ot_math_get_constant(f: HbFont, c: cint): HbPosition
proc hb_ot_math_get_glyph_italics_correction(f: HbFont,
                                             g: HbCodepoint): HbPosition
proc hb_ot_math_get_glyph_variants(f: HbFont, g: HbCodepoint, dir: cint,
                                   startOffset: cuint,
                                   variantsCount: ptr cuint,
                                   variants: pointer): cuint
{.pop.}

type
  ## An open maths font, and the one thing a caller may ask that is not a
  ## constant: whether a delimiter can grow.
  MathFont* = object
    blob: HbBlob
    face: HbFace
    font*: HbFont
    path*: string      ## the file it came from, for the diagnostic that names it
    family*: string    ## the preference-list entry that matched

  ## Everything `mathtex.nim` needs, in font units, resolved once.
  ##
  ## **A flat object rather than a proc taking a `MathFont`** so the layout
  ## module can be handed a literal table in a self-test and never see a font
  ## at all. That is the whole reason the geometry is assertable.
  MathConstants* = object
    axisHeight*: int
    fractionRuleThickness*: int
    fractionNumeratorShiftUp*: int
    fractionDenominatorShiftDown*: int
    fractionNumeratorGapMin*: int
    fractionDenominatorGapMin*: int
    superscriptShiftUp*: int
    superscriptBottomMin*: int
    subscriptShiftDown*: int
    subscriptTopMax*: int
    subSuperscriptGapMin*: int
    spaceAfterScript*: int
    scriptPercentScaleDown*: int
    scriptScriptPercentScaleDown*: int
    overbarRuleThickness*: int
    overbarVerticalGap*: int
    overbarExtraAscender*: int
    radicalRuleThickness*: int
    radicalVerticalGap*: int
    radicalExtraAscender*: int
    upperLimitGapMin*: int
    lowerLimitGapMin*: int
    displayOperatorMinHeight*: int
    unitsPerEm*: int

## Function purpose: the fallback table, used when no usable font is present.
##
## **These are not invented numbers.** They are Latin Modern Math's, which is
## to say TeX's own, measured with `scratchpad/mathprobe.c` and normalised to
## a 1000-unit em. They exist so the layout module is never handed zeroes —
## the DejaVu failure mode this file is about — and so `math-selftest` has a
## table to assert against without requiring a font on the test machine.
##
## A caller that has no usable font should render plain text rather than draw
## with these; they are a floor for the *layout*, not a licence to draw with
## the wrong glyphs.
proc defaultConstants*(): MathConstants =
  MathConstants(
    axisHeight: 250,
    fractionRuleThickness: 40,
    fractionNumeratorShiftUp: 394,
    fractionDenominatorShiftDown: 394,
    fractionNumeratorGapMin: 40,
    fractionDenominatorGapMin: 40,
    superscriptShiftUp: 363,
    superscriptBottomMin: 108,
    subscriptShiftDown: 247,
    subscriptTopMax: 344,
    subSuperscriptGapMin: 160,
    spaceAfterScript: 41,
    scriptPercentScaleDown: 70,
    scriptScriptPercentScaleDown: 55,
    overbarRuleThickness: 40,
    overbarVerticalGap: 120,
    overbarExtraAscender: 40,
    radicalRuleThickness: 40,
    radicalVerticalGap: 48,
    radicalExtraAscender: 40,
    upperLimitGapMin: 100,
    lowerLimitGapMin: 200,
    displayOperatorMinHeight: 1800,
    unitsPerEm: UnitsPerEm)

## Function purpose: how many pre-drawn larger versions of a glyph the font
## carries, growing downward. Zero means a delimiter can never be stretched to
## fit, which is one of the three questions `usable` asks.
##
## Action purpose: `variantsCount` is an IN/OUT parameter — on the way in it is
## how many entries `variants` has room for, on the way out how many were
## written — and the total is the return value either way. A real variable
## holding 0 says "room for none, tell me the total", which is what this wants
## and is well defined by that contract. Passing `nil` relies instead on
## HarfBuzz treating a null count as "skip the copy", which is a reading of its
## implementation rather than of its interface; there is no maths font on the
## machine this was written on, so that reading could not be tested. The
## variable costs nothing and needs no such assumption. `variants` stays `nil`
## because with room for none there is nothing to write.
proc verticalVariantCount*(f: MathFont, ch: int): int =
  var g: HbCodepoint
  if hb_font_get_nominal_glyph(f.font, HbCodepoint(ch), g) == 0: return 0
  var count: cuint = 0
  int(hb_ot_math_get_glyph_variants(f.font, g, HbDirectionTtb, 0,
                                    addr count, nil))

proc constant*(f: MathFont, c: MathConstant): int =
  int(hb_ot_math_get_constant(f.font, cint(ord(c))))

proc italicCorrection*(f: MathFont, ch: int): int =
  var g: HbCodepoint
  if hb_font_get_nominal_glyph(f.font, HbCodepoint(ch), g) == 0: return 0
  int(hb_ot_math_get_glyph_italics_correction(f.font, g))

proc close*(f: var MathFont) =
  if not pointer(f.font).isNil: hb_font_destroy(f.font); f.font = HbFont(nil)
  if not pointer(f.face).isNil: hb_face_destroy(f.face); f.face = HbFace(nil)
  if not pointer(f.blob).isNil: hb_blob_destroy(f.blob); f.blob = HbBlob(nil)

## Function purpose: open a font file and scale it to the reporting em.
## Returns a font whose `font` is nil if the file cannot be read at all.
proc openFont*(path: string): MathFont =
  result.path = path
  result.blob = hb_blob_create_from_file(path.cstring)
  if pointer(result.blob).isNil: return
  result.face = hb_face_create(result.blob, 0)
  if pointer(result.face).isNil: return
  result.font = hb_font_create(result.face)
  if not pointer(result.font).isNil:
    hb_font_set_scale(result.font, UnitsPerEm, UnitsPerEm)

## Function purpose: **the three-question test, and the reason this file
## exists.** See the header for the measurements behind it.
##
## 1. The font declares a `MATH` table at all.
## 2. `FRACTION_NUMERATOR_SHIFT_UP` is non-zero — DejaVu's is zero, and a
##    fraction laid out with it draws its numerator through its own rule.
## 3. A round parenthesis has at least one taller variant — without that, a
##    delimiter can never grow to wrap what it delimits.
##
## Any one of the three failing disqualifies the font. Passing all three does
## not promise beauty; it promises the layout will not be geometrically wrong.
proc usable*(f: MathFont): bool =
  if pointer(f.font).isNil or pointer(f.face).isNil: return false
  if hb_ot_math_has_data(f.face) == 0: return false
  if f.constant(mcFractionNumeratorShiftUp) == 0: return false
  f.verticalVariantCount(0x28) > 0

## The preference order, best first.
##
## Latin Modern Math is the digital descendant of the font Knuth designed for
## TeX, so its constants *are* TeX's and it carries the most delimiter sizes
## (8, against FreeSerif's 4). GNU FreeFont is last because it is the one most
## likely to be installed already, and it is genuinely usable rather than a
## consolation — it passes all three questions.
##
## Filenames rather than family names: this is a file probe, not a fontconfig
## query, so that a missing font is a missing file and not a substitution
## fontconfig made silently. **Substitution is the danger here** — asking
## fontconfig for "a maths font" on a machine without one returns DejaVu,
## which is exactly the failure this module is written to prevent.
const FontCandidates* = [
  ("Latin Modern Math", "latinmodern-math.otf"),
  ("STIX Two Math", "STIXTwoMath-Regular.otf"),
  ("STIX Math", "STIXMath-Regular.otf"),
  ("TeX Gyre Pagella Math", "texgyrepagella-math.otf"),
  ("TeX Gyre Termes Math", "texgyretermes-math.otf"),
  ("GNU FreeSerif", "FreeSerif.ttf"),
]

## Where to look. Deliberately a fixed list of standard font roots rather than
## a fontconfig call, for the substitution reason above. `JENOVA_MATH_FONT`
## overrides the whole search with one explicit path, which is what makes the
## choice testable and lets a user point at a font this list does not know.
const FontRoots = [
  "/usr/local/share/fonts",          # FreeBSD's ports font root
  "/usr/local/share/texmf/fonts",
  "/usr/share/fonts",
  "/usr/share/texmf/fonts",
  "/usr/X11R6/lib/X11/fonts",
]

## Function purpose: find the best usable maths font, or report that there is
## none. The caller renders plain text in the second case — it must not draw.
##
## The returned `MathFont` owns three HarfBuzz handles and must be `close`d.
proc chooseFont*(): tuple[found: bool, font: MathFont] =
  let override = getEnv("JENOVA_MATH_FONT")
  if override.len > 0:
    var f = openFont(override)
    if f.usable():
      f.family = "JENOVA_MATH_FONT"
      return (true, f)
    f.close()
    # An explicit override that is unusable is a failure worth being loud
    # about rather than falling through to a search the user did not ask for:
    # they named a file, and silently using a different one is the
    # substitution problem in another costume.
    return (false, MathFont(path: override, family: "unusable override"))

  for (family, filename) in FontCandidates:
    for root in FontRoots:
      if not dirExists(root): continue
      for path in walkDirRec(root):
        if path.extractFilename != filename: continue
        var f = openFont(path)
        if f.usable():
          f.family = family
          return (true, f)
        f.close()
  (false, MathFont())

## Function purpose: read every constant the layout consumes, once.
##
## Called at startup rather than per formula: these are fixed properties of a
## file that does not change while the program runs, and re-reading them per
## rendered block would be the same mistake as re-decoding the sidebar logo
## on every canvas frame.
proc readConstants*(f: MathFont): MathConstants =
  if not f.usable(): return defaultConstants()
  result = MathConstants(
    axisHeight: f.constant(mcAxisHeight),
    fractionRuleThickness: f.constant(mcFractionRuleThickness),
    fractionNumeratorShiftUp: f.constant(mcFractionNumeratorDisplayStyleShiftUp),
    fractionDenominatorShiftDown:
      f.constant(mcFractionDenominatorDisplayStyleShiftDown),
    fractionNumeratorGapMin: f.constant(mcFractionNumDisplayStyleGapMin),
    fractionDenominatorGapMin: f.constant(mcFractionDenomDisplayStyleGapMin),
    superscriptShiftUp: f.constant(mcSuperscriptShiftUp),
    superscriptBottomMin: f.constant(mcSuperscriptBottomMin),
    subscriptShiftDown: f.constant(mcSubscriptShiftDown),
    subscriptTopMax: f.constant(mcSubscriptTopMax),
    subSuperscriptGapMin: f.constant(mcSubSuperscriptGapMin),
    spaceAfterScript: f.constant(mcSpaceAfterScript),
    scriptPercentScaleDown: f.constant(mcScriptPercentScaleDown),
    scriptScriptPercentScaleDown: f.constant(mcScriptScriptPercentScaleDown),
    overbarRuleThickness: f.constant(mcOverbarRuleThickness),
    overbarVerticalGap: f.constant(mcOverbarVerticalGap),
    overbarExtraAscender: f.constant(mcOverbarExtraAscender),
    radicalRuleThickness: f.constant(mcRadicalRuleThickness),
    radicalVerticalGap: f.constant(mcRadicalDisplayStyleVerticalGap),
    radicalExtraAscender: f.constant(mcRadicalExtraAscender),
    upperLimitGapMin: f.constant(mcUpperLimitGapMin),
    lowerLimitGapMin: f.constant(mcLowerLimitGapMin),
    displayOperatorMinHeight: f.constant(mcDisplayOperatorMinHeight),
    unitsPerEm: UnitsPerEm)

  # A font may leave an individual constant at zero even when the table is
  # otherwise sound. The two scale-down percentages are the ones that matter:
  # a zero there collapses every script to nothing, which is a blank
  # exponent rather than an ugly one. The defaults are TeX's.
  let d = defaultConstants()
  if result.scriptPercentScaleDown == 0:
    result.scriptPercentScaleDown = d.scriptPercentScaleDown
  if result.scriptScriptPercentScaleDown == 0:
    result.scriptScriptPercentScaleDown = d.scriptScriptPercentScaleDown

## Function purpose: what to tell the user when no font passed. Names the
## files looked for and where, because "maths is not available" over a machine
## that has three maths fonts installed is the report that sends someone
## looking in the wrong place — the same argument the Models panel's empty
## state makes about naming both directories it searched.
proc unavailableReason*(): string =
  var names: seq[string]
  for (family, filename) in FontCandidates: names.add family & " (" & filename & ")"
  "No usable maths font found. Looked for " & names.join(", ") &
    " under " & FontRoots.join(", ") &
    ". Set JENOVA_MATH_FONT to a font file with an OpenType MATH table, " &
    "or install one. Formulae render as their own source until then."
