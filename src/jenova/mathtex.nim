## Script function and purpose: display maths, from LaTeX source to a tree of
## positioned boxes. It parses the subset a chat model actually writes, then
## lays that tree out over the rules of Appendix G of The TeXbook using metrics
## the caller supplies from the font's OpenType MATH table. It draws nothing.
##
## Nothing here imports owlkettle, GTK, Cairo or Pango, and that is the point:
## the window links into no test binary, so a layout engine that lived there
## could only be checked by looking at a screenshot. Everything below is
## numbers in and numbers out, and `math-selftest` asserts the numbers.
##
## The subset is "what a chat model writes in a reply", not LaTeX. There is no
## mhchem (`\ce`, `\pu`), no TikZ, no `\newcommand`, no `\usepackage`, no
## MathML, and no `\begin{align}`, `\begin{cases}` or per-column alignment.
## A command outside the subset is not silently dropped: it lays out as its own
## literal source, so a reader sees `\wobble` and knows what was written. An
## environment outside the subset is refused by name instead, because skipping
## one means guessing where its `\end` is and laying out the guess.
##
## Two conventions the drawing phase depends on. Coordinates grow down, as
## Cairo's do; a box's origin is its left edge on its baseline, `ascent` is a
## positive distance above that baseline and `descent` a positive distance
## below, and a child's `x`/`y` are offsets from its parent's origin. Font
## metrics arrive through `MathFont`'s two closures rather than being computed
## here, because the shaping library is what knows them and it is not linkable
## into this module.

import std/[strutils, tables]

type
  ## The eight styles of The TeXbook, in the order that makes `cramped` the odd
  ## neighbour of each. Cramped styles exist so that a superscript inside a
  ## radical or a denominator is not raised into the rule above it.
  MathStyle* = enum
    msDisplay, msDisplayCramped
    msText, msTextCramped
    msScript, msScriptCramped
    msScriptScript, msScriptScriptCramped

  ## Carried on every atom because the inter-atom spacing table of Appendix G
  ## reads it. That table is not applied yet, so today the class only decides
  ## whether a symbol is set upright.
  AtomClass* = enum
    acOrd, acOp, acBin, acRel, acOpen, acClose, acPunct

  ## Whether `\sum_a^b` sets its scripts above and below or beside. `lmDefault`
  ## defers to the operator: TeX gives `\sum` limits and `\int` none, and both
  ## only in display style.
  LimitMode* = enum
    lmDefault, lmLimits, lmNoLimits

  MathNodeKind* = enum
    mnList, mnAtom, mnFrac, mnScripts, mnRadical, mnBigOp, mnMatrix,
    mnFenced, mnSpace, mnStyled

  ## The parse tree. It records what was written, not what it will look like:
  ## `\sum_0^n` is an `mnScripts` over an `mnBigOp` in every style, and only
  ## layout — which knows the style — decides whether those scripts become
  ## limits.
  MathNode* = ref object
    case kind*: MathNodeKind
    of mnList:
      items*: seq[MathNode]
    of mnAtom:
      text*: string
      cls*: AtomClass
      upright*: bool
    of mnFrac:
      num*, den*: MathNode
      ## Negative means the font's `FractionRuleThickness`; zero means a bare
      ## stack, which is what `\binom` is under its parentheses.
      barThickness*: float
    of mnScripts:
      base*: MathNode
      sup*, sub*: MathNode
    of mnRadical:
      radicand*: MathNode
      index*: MathNode
    of mnBigOp:
      opText*: string
      opUpright*: bool
      ## Whether this operator sets limits above and below when nothing says
      ## otherwise. It is a property of the operator, not of the style, so it
      ## is decided where the command is read and not where it is laid out.
      defaultLimits*: bool
      limits*: LimitMode
    of mnMatrix:
      rows*: seq[seq[MathNode]]
    of mnFenced:
      left*, right*: string
      body*: MathNode
    of mnSpace:
      ## Fractions of an em, so it survives every style change unscaled.
      amount*: float
    of mnStyled:
      forced*: MathStyle
      inner*: MathNode

  ## Every field but the last two is one `HB_OT_MATH_CONSTANT_*` value in the
  ## font's design units; `unitsPerEm` scales them to the size in use. Only the
  ## constants this layout actually reads are here — a field a caller fills in
  ## that changes nothing is worse than a missing one, because it looks answered. They are
  ## an input rather than a lookup so this module needs no font: the self-test
  ## drives it with a known table, and the drawing phase fills it from
  ## HarfBuzz.
  ##
  ## `matrixColumnGap` and `matrixRowGap` have no equivalent in the MATH table.
  ## TeX takes them from `\arraycolsep` and `\baselineskip`, which are document
  ## parameters rather than font ones, so the caller states them too rather
  ## than this module inventing a number.
  MathConstants* = object
    unitsPerEm*: float
    scriptPercentScaleDown*: float
    scriptScriptPercentScaleDown*: float
    delimitedSubFormulaMinHeight*: float
    displayOperatorMinHeight*: float
    axisHeight*: float
    subscriptShiftDown*: float
    subscriptTopMax*: float
    subscriptBaselineDropMin*: float
    superscriptShiftUp*: float
    superscriptShiftUpCramped*: float
    superscriptBottomMin*: float
    superscriptBaselineDropMax*: float
    subSuperscriptGapMin*: float
    superscriptBottomMaxWithSubscript*: float
    spaceAfterScript*: float
    upperLimitGapMin*: float
    upperLimitBaselineRiseMin*: float
    lowerLimitGapMin*: float
    lowerLimitBaselineDropMin*: float
    stackTopShiftUp*: float
    stackTopDisplayStyleShiftUp*: float
    stackBottomShiftDown*: float
    stackBottomDisplayStyleShiftDown*: float
    stackGapMin*: float
    stackDisplayStyleGapMin*: float
    fractionNumeratorShiftUp*: float
    fractionNumeratorDisplayStyleShiftUp*: float
    fractionDenominatorShiftDown*: float
    fractionDenominatorDisplayStyleShiftDown*: float
    fractionNumeratorGapMin*: float
    fractionNumDisplayStyleGapMin*: float
    fractionRuleThickness*: float
    fractionDenominatorGapMin*: float
    fractionDenomDisplayStyleGapMin*: float
    radicalVerticalGap*: float
    radicalDisplayStyleVerticalGap*: float
    radicalRuleThickness*: float
    radicalExtraAscender*: float
    radicalKernBeforeDegree*: float
    radicalKernAfterDegree*: float
    radicalDegreeBottomRaisePercent*: float
    matrixColumnGap*: float
    matrixRowGap*: float

  ## What one shaped run occupies, in output units at the size it was measured.
  ## `italicCorrection` is separate from `width` because Appendix G moves a
  ## superscript right by it and leaves a subscript where it is.
  GlyphBox* = object
    width*: float
    ascent*, descent*: float
    italicCorrection*: float

  ## One entry of the font's vertical variant list for a stretchy glyph, in
  ## the order HarfBuzz returns them: smallest first.
  MathVariant* = object
    width*: float
    ascent*, descent*: float
    italicCorrection*: float

  ## The two questions layout has to ask a font. Supplying them as closures is
  ## what keeps this module free of the shaping library.
  MathFont* = object
    constants*: MathConstants
    measure*: proc (text: string, fontSize: float, upright: bool): GlyphBox {.closure.}
    variants*: proc (text: string, fontSize: float): seq[MathVariant] {.closure.}

  BoxKind* = enum
    ## A shaped run of text, a filled rectangle, or a container whose children
    ## carry their own offsets. One container kind rather than an hlist and a
    ## vlist, because a child that states both `x` and `y` needs no second
    ## packing rule and the drawing phase is then a translate and a recursion.
    bxGlyph, bxRule, bxList

  MathBox* = object
    x*, y*: float
    width*: float
    ascent*, descent*: float
    italicCorrection*: float
    case kind*: BoxKind
    of bxGlyph:
      text*: string
      fontSize*: float
      upright*: bool
      ## -1 selects the base glyph; otherwise the index into the font's
      ## vertical variant list, which the drawing phase re-reads from the same
      ## font and so gets the same glyph.
      variant*: int
      ## Non-zero when even the largest variant is too short and the glyph must
      ## be built from its extensible parts to reach this height.
      stretchTo*: float
    of bxRule:
      discard
    of bxList:
      children*: seq[MathBox]

  ## `ok` false means the source was refused rather than laid out wrong, and
  ## `error` is the sentence to show in its place.
  MathLayout* = object
    ok*: bool
    error*: string
    errorPos*: int
    box*: MathBox

  MathParse* = object
    ok*: bool
    error*: string
    errorPos*: int
    root*: MathNode

const
  ## TeX's `mu` is one eighteenth of a quad, and these are the six spacing
  ## commands expressed in ems so that a style change does not rescale them
  ## twice.
  ThinSpace = 3.0 / 18.0
  MedSpace = 4.0 / 18.0
  ThickSpace = 5.0 / 18.0
  Quad = 1.0
  QQuad = 2.0

type SymDef = tuple[text: string, cls: AtomClass, upright: bool]

## Lowercase Greek is italic and uppercase Greek is upright, which is TeX's
## convention and the one thing about Greek that a reader notices when it is
## wrong.
let Symbols: Table[string, SymDef] = {
  "alpha": ("α", acOrd, false), "beta": ("β", acOrd, false),
  "gamma": ("γ", acOrd, false), "delta": ("δ", acOrd, false),
  "epsilon": ("ϵ", acOrd, false), "varepsilon": ("ε", acOrd, false),
  "zeta": ("ζ", acOrd, false), "eta": ("η", acOrd, false),
  "theta": ("θ", acOrd, false), "vartheta": ("ϑ", acOrd, false),
  "iota": ("ι", acOrd, false), "kappa": ("κ", acOrd, false),
  "lambda": ("λ", acOrd, false), "mu": ("μ", acOrd, false),
  "nu": ("ν", acOrd, false), "xi": ("ξ", acOrd, false),
  "omicron": ("ο", acOrd, false), "pi": ("π", acOrd, false),
  "varpi": ("ϖ", acOrd, false), "rho": ("ρ", acOrd, false),
  "varrho": ("ϱ", acOrd, false), "sigma": ("σ", acOrd, false),
  "varsigma": ("ς", acOrd, false), "tau": ("τ", acOrd, false),
  "upsilon": ("υ", acOrd, false), "phi": ("ϕ", acOrd, false),
  "varphi": ("φ", acOrd, false), "chi": ("χ", acOrd, false),
  "psi": ("ψ", acOrd, false), "omega": ("ω", acOrd, false),
  "Gamma": ("Γ", acOrd, true), "Delta": ("Δ", acOrd, true),
  "Theta": ("Θ", acOrd, true), "Lambda": ("Λ", acOrd, true),
  "Xi": ("Ξ", acOrd, true), "Pi": ("Π", acOrd, true),
  "Sigma": ("Σ", acOrd, true), "Upsilon": ("Υ", acOrd, true),
  "Phi": ("Φ", acOrd, true), "Psi": ("Ψ", acOrd, true),
  "Omega": ("Ω", acOrd, true),

  "leq": ("≤", acRel, true), "le": ("≤", acRel, true),
  "geq": ("≥", acRel, true), "ge": ("≥", acRel, true),
  "neq": ("≠", acRel, true), "ne": ("≠", acRel, true),
  "approx": ("≈", acRel, true), "equiv": ("≡", acRel, true),
  "sim": ("∼", acRel, true), "simeq": ("≃", acRel, true),
  "cong": ("≅", acRel, true), "propto": ("∝", acRel, true),
  "ll": ("≪", acRel, true), "gg": ("≫", acRel, true),
  "subset": ("⊂", acRel, true), "supset": ("⊃", acRel, true),
  "subseteq": ("⊆", acRel, true), "supseteq": ("⊇", acRel, true),
  "in": ("∈", acRel, true), "notin": ("∉", acRel, true),
  "ni": ("∋", acRel, true), "mid": ("∣", acRel, true),
  "parallel": ("∥", acRel, true), "perp": ("⊥", acRel, true),
  "models": ("⊨", acRel, true),
  "to": ("→", acRel, true), "rightarrow": ("→", acRel, true),
  "leftarrow": ("←", acRel, true), "gets": ("←", acRel, true),
  "leftrightarrow": ("↔", acRel, true),
  "Rightarrow": ("⇒", acRel, true), "Leftarrow": ("⇐", acRel, true),
  "Leftrightarrow": ("⇔", acRel, true), "mapsto": ("↦", acRel, true),
  "uparrow": ("↑", acRel, true), "downarrow": ("↓", acRel, true),
  "implies": ("⟹", acRel, true), "iff": ("⟺", acRel, true),

  "times": ("×", acBin, true), "div": ("÷", acBin, true),
  "cdot": ("⋅", acBin, true), "pm": ("±", acBin, true),
  "mp": ("∓", acBin, true), "ast": ("∗", acBin, true),
  "star": ("⋆", acBin, true), "circ": ("∘", acBin, true),
  "bullet": ("∙", acBin, true), "oplus": ("⊕", acBin, true),
  "ominus": ("⊖", acBin, true), "otimes": ("⊗", acBin, true),
  "oslash": ("⊘", acBin, true), "odot": ("⊙", acBin, true),
  "cup": ("∪", acBin, true), "cap": ("∩", acBin, true),
  "setminus": ("∖", acBin, true), "wedge": ("∧", acBin, true),
  "vee": ("∨", acBin, true), "land": ("∧", acBin, true),
  "lor": ("∨", acBin, true),

  "infty": ("∞", acOrd, true), "partial": ("∂", acOrd, false),
  "nabla": ("∇", acOrd, true), "forall": ("∀", acOrd, true),
  "exists": ("∃", acOrd, true), "neg": ("¬", acOrd, true),
  "lnot": ("¬", acOrd, true), "emptyset": ("∅", acOrd, true),
  "varnothing": ("∅", acOrd, true), "aleph": ("ℵ", acOrd, true),
  "hbar": ("ℏ", acOrd, false), "ell": ("ℓ", acOrd, false),
  "Re": ("ℜ", acOrd, true), "Im": ("ℑ", acOrd, true),
  "prime": ("′", acOrd, true), "cdots": ("⋯", acOrd, true),
  "ldots": ("…", acOrd, true), "dots": ("…", acOrd, true),
  "vdots": ("⋮", acOrd, true), "ddots": ("⋱", acOrd, true),
  "angle": ("∠", acOrd, true), "triangle": ("△", acOrd, true),
  "square": ("□", acOrd, true), "top": ("⊤", acOrd, true),
  "bot": ("⊥", acOrd, true), "degree": ("°", acOrd, true),
  "%": ("%", acOrd, true), "$": ("$", acOrd, true), "&": ("&", acOrd, true),
  "#": ("#", acOrd, true), "_": ("_", acOrd, true), "{": ("{", acOpen, true),
  "}": ("}", acClose, true),
}.toTable

## Whether the operator sets its scripts as limits in display style. TeX gives
## `\int` `\nolimits` and this matches it: an integral's bounds sit beside the
## sign, not over it, and `\limits` is how a reader asks for the other.
let BigOps: Table[string, bool] = {
  "sum": true, "prod": true, "coprod": true, "bigcup": true, "bigcap": true,
  "bigoplus": true, "bigotimes": true, "bigvee": true, "bigwedge": true,
  "bigsqcup": true, "biguplus": true,
  "int": false, "iint": false, "iiint": false, "oint": false,
  "lim": true, "limsup": true, "liminf": true, "max": true, "min": true,
  "sup": true, "inf": true, "det": true, "gcd": true, "Pr": true,
}.toTable

## The glyph a big operator draws. The word operators draw their own name
## upright, which is why the value carries the text rather than the key being
## used directly.
let BigOpGlyphs: Table[string, string] = {
  "sum": "∑", "prod": "∏", "coprod": "∐", "bigcup": "⋃",
  "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
  "bigvee": "⋁", "bigwedge": "⋀", "bigsqcup": "⨆",
  "biguplus": "⨄", "int": "∫", "iint": "∬", "iiint": "∭",
  "oint": "∮",
}.toTable

## Set upright and never italic, because TeX sets a function name as a word and
## an italic `sin` reads as three multiplied variables.
let FunctionNames = [
  "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
  "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "dim", "ker",
  "deg", "hom", "arg", "sgn",
]

let Delimiters: Table[string, string] = {
  "(": "(", ")": ")", "[": "[", "]": "]", "|": "∣", "/": "/",
  "\\{": "{", "\\}": "}", "\\|": "∥", "\\vert": "∣",
  "\\Vert": "∥", "\\langle": "⟨", "\\rangle": "⟩",
  "\\lfloor": "⌊", "\\rfloor": "⌋", "\\lceil": "⌈",
  "\\rceil": "⌉", "\\backslash": "\\", "\\uparrow": "↑",
  "\\downarrow": "↓", ".": "",
}.toTable

## The matrix environments and the pair of delimiters each wraps its body in.
let MatrixEnvs: Table[string, (string, string)] = {
  "matrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"),
  "Bmatrix": ("{", "}"), "vmatrix": ("∣", "∣"),
  "Vmatrix": ("∥", "∥"), "smallmatrix": ("", ""),
}.toTable

# ---------------------------------------------------------------- styles

## Function purpose: the odd member of each pair is the cramped one, so the
## transition is arithmetic rather than a nine-case table that can disagree
## with itself.
proc cramped*(s: MathStyle): MathStyle =
  if ord(s) mod 2 == 1: s else: MathStyle(ord(s) + 1)

proc isCramped*(s: MathStyle): bool = ord(s) mod 2 == 1

proc isDisplay*(s: MathStyle): bool = s in {msDisplay, msDisplayCramped}

## Function purpose: the style a superscript is set in. Script of a script is
## scriptscript and script of scriptscript is scriptscript again — that floor
## is why nested exponents stop shrinking instead of vanishing.
proc supStyle*(s: MathStyle): MathStyle =
  let base =
    if s in {msDisplay, msDisplayCramped, msText, msTextCramped}: msScript
    else: msScriptScript
  if isCramped(s): cramped(base) else: base

## Function purpose: a subscript is always cramped, because nothing may be
## raised out of it into the base's own superscript.
proc subStyle*(s: MathStyle): MathStyle = cramped(supStyle(s))

## Function purpose: a numerator drops one size but keeps its crampedness; the
## denominator below uses the cramped form of the same style.
proc numStyle*(s: MathStyle): MathStyle =
  let base =
    case s
    of msDisplay, msDisplayCramped: msText
    of msText, msTextCramped: msScript
    else: msScriptScript
  if isCramped(s): cramped(base) else: base

## Function purpose: the denominator sits under the rule with nothing above it
## to collide with, so it is the cramped form of the numerator's own style.
proc denStyle*(s: MathStyle): MathStyle = cramped(numStyle(s))

## Function purpose: the point size a style is set at. Display and text share
## one size — they differ in spacing and limit placement, not in scale.
proc styleSize*(mc: MathConstants, baseSize: float, s: MathStyle): float =
  case s
  of msDisplay, msDisplayCramped, msText, msTextCramped: baseSize
  of msScript, msScriptCramped: baseSize * mc.scriptPercentScaleDown / 100.0
  of msScriptScript, msScriptScriptCramped:
    baseSize * mc.scriptScriptPercentScaleDown / 100.0

## Function purpose: a MATH-table value in design units, at the size in use.
proc du*(mc: MathConstants, value, size: float): float =
  if mc.unitsPerEm <= 0.0: 0.0 else: value * size / mc.unitsPerEm

# ---------------------------------------------------------------- parser

type
  Parser = object
    s: string
    i: int
    err: string
    errPos: int

  ListMode = enum
    lmTop, lmGroup, lmCell, lmFence

proc parseList(p: var Parser, mode: ListMode): MathNode

proc fail(p: var Parser, msg: string) =
  if p.err.len == 0:
    p.err = msg
    p.errPos = p.i

proc atEnd(p: Parser): bool = p.i >= p.s.len

proc skipSpace(p: var Parser) =
  while p.i < p.s.len and p.s[p.i] in {' ', '\t', '\n', '\r'}: inc p.i

## Function purpose: read the name after a backslash. A control word is a run of
## letters; a control symbol is the single character after the backslash, which
## is how `\\`, `\,` and `\{` are named at all.
proc readCommand(p: var Parser): string =
  inc p.i
  if p.i >= p.s.len: return ""
  if p.s[p.i] in Letters:
    let start = p.i
    while p.i < p.s.len and p.s[p.i] in Letters: inc p.i
    return p.s[start ..< p.i]
  result = $p.s[p.i]
  inc p.i

proc peekCommand(p: var Parser): string =
  let save = p.i
  result = p.readCommand()
  p.i = save

proc atom(text: string, cls = acOrd, upright = true): MathNode =
  MathNode(kind: mnAtom, text: text, cls: cls, upright: upright)

proc list(items: seq[MathNode]): MathNode = MathNode(kind: mnList, items: items)

## Function purpose: `{a}` in braces, or the single next token — `\frac12` is
## valid LaTeX and a model writes it. Returns nil and sets the error when the
## argument is simply not there, which is what `\frac{a}` with no denominator
## looks like from here.
proc parseArgument(p: var Parser, what: string): MathNode

## Function purpose: one syntactic unit with no scripts attached yet.
proc parseUnit(p: var Parser, mode: ListMode): MathNode =
  p.skipSpace()
  if p.atEnd: return nil
  let c = p.s[p.i]
  if c == '{':
    inc p.i
    return p.parseList(lmGroup)
  if c != '\\':
    inc p.i
    if c in {'0' .. '9'}:
      # A run of digits is one atom: it is one shaped run to the font, and TeX
      # puts no space between the digits of a number either.
      let start = p.i - 1
      while p.i < p.s.len and (p.s[p.i] in {'0' .. '9'} or
            (p.s[p.i] == '.' and p.i + 1 < p.s.len and p.s[p.i + 1] in {'0' .. '9'})):
        inc p.i
      return atom(p.s[start ..< p.i], acOrd, true)
    if c in Letters:
      return atom($c, acOrd, false)
    case c
    of '+', '-', '*': return atom((if c == '-': "−" else: $c), acBin, true)
    of '=', '<', '>': return atom($c, acRel, true)
    of '(', '[': return atom($c, acOpen, true)
    of ')', ']': return atom($c, acClose, true)
    of ',', ';': return atom($c, acPunct, true)
    of '/', '!', '?', ':', '.', '\'': return atom($c, acOrd, true)
    else: return atom($c, acOrd, true)

  let save = p.i
  let cmd = p.readCommand()
  if cmd.len == 0:
    p.i = save
    p.fail("a trailing backslash names no command")
    return nil

  case cmd
  of "frac", "dfrac", "tfrac", "binom", "tbinom", "dbinom", "atop":
    let num = p.parseArgument("\\" & cmd & " needs a numerator")
    if num == nil: return nil
    let den = p.parseArgument("\\" & cmd & " needs a denominator")
    if den == nil: return nil
    let bare = cmd in ["binom", "tbinom", "dbinom", "atop"]
    let f = MathNode(kind: mnFrac, num: num, den: den,
                     barThickness: (if bare: 0.0 else: -1.0))
    if cmd == "atop": return f
    if bare: return MathNode(kind: mnFenced, left: "(", right: ")", body: f)
    if cmd == "dfrac":
      return MathNode(kind: mnStyled, forced: msDisplay, inner: f)
    if cmd == "tfrac":
      return MathNode(kind: mnStyled, forced: msText, inner: f)
    return f
  of "sqrt":
    var index: MathNode = nil
    p.skipSpace()
    if p.i < p.s.len and p.s[p.i] == '[':
      inc p.i
      var items: seq[MathNode]
      while true:
        p.skipSpace()
        if p.atEnd:
          p.fail("\\sqrt[ is never closed by ]")
          return nil
        if p.s[p.i] == ']':
          inc p.i
          break
        let u = p.parseUnit(mode)
        if u == nil: return nil
        items.add u
      index = list(items)
    let rad = p.parseArgument("\\sqrt needs a radicand")
    if rad == nil: return nil
    return MathNode(kind: mnRadical, radicand: rad, index: index)
  of "left":
    p.skipSpace()
    if p.atEnd:
      p.fail("\\left names no delimiter")
      return nil
    var open: string
    if p.s[p.i] == '\\': open = "\\" & p.readCommand()
    else:
      open = $p.s[p.i]
      inc p.i
    if not Delimiters.hasKey(open):
      p.fail("\\left " & open & " is not a delimiter")
      return nil
    let body = p.parseList(lmFence)
    if p.err.len > 0: return nil
    p.skipSpace()
    if p.atEnd or p.s[p.i] != '\\' or p.peekCommand() != "right":
      p.fail("\\left has no matching \\right")
      return nil
    discard p.readCommand()
    p.skipSpace()
    if p.atEnd:
      p.fail("\\right names no delimiter")
      return nil
    var close: string
    if p.s[p.i] == '\\': close = "\\" & p.readCommand()
    else:
      close = $p.s[p.i]
      inc p.i
    if not Delimiters.hasKey(close):
      p.fail("\\right " & close & " is not a delimiter")
      return nil
    return MathNode(kind: mnFenced, left: Delimiters[open],
                    right: Delimiters[close], body: body)
  of "begin":
    p.skipSpace()
    if p.atEnd or p.s[p.i] != '{':
      p.fail("\\begin needs an environment name in braces")
      return nil
    inc p.i
    let start = p.i
    while p.i < p.s.len and p.s[p.i] != '}': inc p.i
    if p.atEnd:
      p.fail("\\begin{ is never closed")
      return nil
    let env = p.s[start ..< p.i]
    inc p.i
    if not MatrixEnvs.hasKey(env):
      p.fail("\\begin{" & env & "} is outside the supported subset")
      return nil
    var rows: seq[seq[MathNode]] = @[@[]]
    while true:
      let cell = p.parseList(lmCell)
      if p.err.len > 0: return nil
      rows[^1].add cell
      p.skipSpace()
      if p.atEnd:
        p.fail("\\begin{" & env & "} has no matching \\end")
        return nil
      if p.s[p.i] == '&':
        inc p.i
        continue
      let cmdSave = p.i
      let inner = p.readCommand()
      if inner == "\\":
        rows.add @[]
        continue
      if inner == "end":
        p.skipSpace()
        if p.atEnd or p.s[p.i] != '{':
          p.fail("\\end needs an environment name in braces")
          return nil
        inc p.i
        let es = p.i
        while p.i < p.s.len and p.s[p.i] != '}': inc p.i
        if p.atEnd:
          p.fail("\\end{ is never closed")
          return nil
        let closing = p.s[es ..< p.i]
        inc p.i
        if closing != env:
          p.fail("\\begin{" & env & "} is closed by \\end{" & closing & "}")
          return nil
        break
      p.i = cmdSave
      p.fail("\\begin{" & env & "} has no matching \\end")
      return nil
    # A trailing `\\` opens a row that never gets a cell; dropping it keeps a
    # formula written with a line break after every row from growing a blank
    # one at the bottom.
    if rows.len > 1 and rows[^1].len == 1 and rows[^1][0].kind == mnList and
       rows[^1][0].items.len == 0:
      rows.setLen(rows.len - 1)
    let m = MathNode(kind: mnMatrix, rows: rows)
    let (l, r) = MatrixEnvs[env]
    if l.len == 0 and r.len == 0: return m
    return MathNode(kind: mnFenced, left: l, right: r, body: m)
  of "text", "mathrm", "operatorname", "mathbf", "mathsf", "mathtt":
    let arg = p.parseArgument("\\" & cmd & " needs an argument")
    if arg == nil: return nil
    # Upright is applied to the atoms rather than carried as a node, so the
    # layout has one fewer case and the box tree records the face that was
    # actually chosen.
    proc uprightify(n: MathNode) =
      if n == nil: return
      case n.kind
      of mnAtom: n.upright = true
      of mnList:
        for it in n.items: uprightify(it)
      else: discard
    uprightify(arg)
    return arg
  of "displaystyle": return MathNode(kind: mnStyled, forced: msDisplay, inner: nil)
  of "textstyle": return MathNode(kind: mnStyled, forced: msText, inner: nil)
  of "scriptstyle": return MathNode(kind: mnStyled, forced: msScript, inner: nil)
  of "scriptscriptstyle":
    return MathNode(kind: mnStyled, forced: msScriptScript, inner: nil)
  of ",": return MathNode(kind: mnSpace, amount: ThinSpace)
  of ":", ">": return MathNode(kind: mnSpace, amount: MedSpace)
  of ";": return MathNode(kind: mnSpace, amount: ThickSpace)
  of "!": return MathNode(kind: mnSpace, amount: -ThinSpace)
  of " ": return MathNode(kind: mnSpace, amount: MedSpace)
  of "quad": return MathNode(kind: mnSpace, amount: Quad)
  of "qquad": return MathNode(kind: mnSpace, amount: QQuad)
  else:
    if BigOps.hasKey(cmd):
      let glyph = if BigOpGlyphs.hasKey(cmd): BigOpGlyphs[cmd] else: cmd
      return MathNode(kind: mnBigOp, opText: glyph,
                      opUpright: not BigOpGlyphs.hasKey(cmd),
                      defaultLimits: BigOps[cmd], limits: lmDefault)
    if cmd in FunctionNames:
      return atom(cmd, acOp, true)
    if Symbols.hasKey(cmd):
      let d = Symbols[cmd]
      return atom(d.text, d.cls, d.upright)
    if Delimiters.hasKey("\\" & cmd):
      let d = Delimiters["\\" & cmd]
      if d.len > 0: return atom(d, acOrd, true)
    # An unknown command is not dropped. It lays out as the source that was
    # written, so a reader sees what the model asked for rather than a hole
    # where it used to be.
    return atom("\\" & cmd, acOrd, true)

proc parseArgument(p: var Parser, what: string): MathNode =
  p.skipSpace()
  if p.atEnd or p.s[p.i] == '}' or p.s[p.i] == '&':
    p.fail(what)
    return nil
  if p.s[p.i] == '\\':
    let nxt = p.peekCommand()
    if nxt in ["right", "end", "\\"]:
      p.fail(what)
      return nil
  if p.s[p.i] in {'0' .. '9'}:
    # An unbraced argument is one token, and a digit is one token: `\frac12` is
    # one over two in LaTeX, not twelve over nothing. The digit-run merging that
    # makes `123` a single shaped box must not reach across this boundary.
    result = atom($p.s[p.i], acOrd, true)
    inc p.i
    return
  result = p.parseUnit(lmGroup)
  if result == nil and p.err.len == 0: p.fail(what)

## Function purpose: one unit and every script attached to it. Superscript and
## subscript are collected in either written order into one node, because they
## are laid out against each other and not one after the other.
proc parseScripted(p: var Parser, mode: ListMode): MathNode =
  var base = p.parseUnit(mode)
  if base == nil: return nil
  var sup, sub: MathNode = nil
  var limits = lmDefault
  var primes = 0
  while true:
    p.skipSpace()
    if p.atEnd: break
    let c = p.s[p.i]
    if c == '\'':
      inc p.i
      inc primes
      continue
    if c == '\\':
      let nxt = p.peekCommand()
      if nxt == "limits" or nxt == "nolimits":
        discard p.readCommand()
        if base.kind != mnBigOp:
          p.fail("\\" & nxt & " may only follow a large operator")
          return nil
        limits = if nxt == "limits": lmLimits else: lmNoLimits
        continue
      break
    if c != '^' and c != '_': break
    inc p.i
    let arg = p.parseArgument("'" & c & "' has no argument")
    if arg == nil: return nil
    if c == '^':
      if sup != nil:
        p.fail("two superscripts on one base")
        return nil
      sup = arg
    else:
      if sub != nil:
        p.fail("two subscripts on one base")
        return nil
      sub = arg
  if base.kind == mnBigOp and limits != lmDefault: base.limits = limits
  if primes > 0:
    # Primes are a superscript that was written without one, so they join the
    # superscript rather than becoming a second raised box beside it.
    let mark = atom("′".repeat(primes), acOrd, true)
    sup = if sup == nil: mark else: list(@[mark, sup])
  if sup == nil and sub == nil: return base
  MathNode(kind: mnScripts, base: base, sup: sup, sub: sub)

proc parseList(p: var Parser, mode: ListMode): MathNode =
  var items: seq[MathNode]
  while true:
    p.skipSpace()
    if p.atEnd:
      case mode
      of lmTop: break
      of lmGroup:
        p.fail("'{' is never closed")
        return nil
      of lmCell, lmFence: break
    let c = p.s[p.i]
    if c == '}':
      if mode == lmGroup:
        inc p.i
        break
      p.fail("'}' closes a group that was never opened")
      return nil
    if c == '&':
      if mode == lmCell: break
      p.fail("'&' outside a matrix separates nothing")
      return nil
    if c == '$':
      p.fail("'$' inside a formula: the delimiters are stripped before parsing")
      return nil
    if c == '\\':
      let nxt = p.peekCommand()
      if nxt == "right":
        if mode == lmFence: break
        p.fail("\\right has no matching \\left")
        return nil
      if nxt == "end":
        if mode == lmCell: break
        p.fail("\\end has no matching \\begin")
        return nil
      if nxt == "\\" and mode == lmCell: break
    let it = p.parseScripted(mode)
    if it == nil: return nil
    items.add it
  list(items)

## Function purpose: LaTeX source to a tree, with the failures named. Refusing
## is the point: a formula that cannot be understood is shown as its own source
## by the caller, which is honest, where a formula laid out from a half-read
## tree is confident and wrong.
proc parseMath*(src: string): MathParse =
  var p = Parser(s: src, i: 0)
  let root = p.parseList(lmTop)
  if p.err.len > 0:
    return MathParse(ok: false, error: p.err, errorPos: p.errPos)
  MathParse(ok: true, root: root)

# ---------------------------------------------------------------- layout

proc measureRun(f: MathFont, text: string, size: float, upright: bool): GlyphBox =
  if f.measure == nil: GlyphBox() else: f.measure(text, size, upright)

proc variantList(f: MathFont, text: string, size: float): seq[MathVariant] =
  if f.variants == nil: @[] else: f.variants(text, size)

## Function purpose: a measured run as a box, on the base glyph. Every stretchy
## caller overwrites `variant` and `stretchTo` afterwards, so the defaults here
## are what a glyph that never grows keeps.
proc glyphBox(text: string, size: float, upright: bool, g: GlyphBox): MathBox =
  MathBox(kind: bxGlyph, text: text, fontSize: size, upright: upright,
          variant: -1, stretchTo: 0.0, width: g.width, ascent: g.ascent,
          descent: g.descent, italicCorrection: g.italicCorrection)

proc container(children: seq[MathBox]): MathBox =
  ## The container's own extents are the union of its children's, measured in
  ## the container's coordinates rather than each child's.
  result = MathBox(kind: bxList, children: children)
  var w = 0.0
  var asc = 0.0
  var desc = 0.0
  for c in children:
    w = max(w, c.x + c.width)
    asc = max(asc, -(c.y - c.ascent))
    desc = max(desc, c.y + c.descent)
  result.width = w
  result.ascent = asc
  result.descent = desc

proc layoutNode(n: MathNode, f: MathFont, baseSize: float, st: MathStyle): MathBox

## Function purpose: a horizontal run, each item placed after the last on a
## shared baseline. No inter-atom spacing is inserted: the ord/op/bin/rel table
## of Appendix G is a later phase, and the font's own advances stand until it
## lands.
proc layoutRow(items: seq[MathNode], f: MathFont, baseSize: float,
               st: MathStyle): MathBox =
  var kids: seq[MathBox]
  var pen = 0.0
  var style = st
  var lastItalic = 0.0
  for it in items:
    if it != nil and it.kind == mnStyled and it.inner == nil:
      # `\displaystyle` with no argument changes the style of everything after
      # it in the same list, which is what makes it a switch rather than a
      # wrapper.
      style = it.forced
      continue
    if it != nil and it.kind == mnSpace:
      pen += it.amount * styleSize(f.constants, baseSize, style)
      lastItalic = 0.0
      continue
    var b = layoutNode(it, f, baseSize, style)
    b.x = pen
    b.y = 0.0
    pen += b.width
    lastItalic = b.italicCorrection
    kids.add b
  result = container(kids)
  result.width = max(result.width, pen)
  result.italicCorrection = lastItalic

## Function purpose: the fraction of Appendix G rule 15. The rule is centred on
## the maths axis so that fractions at different sizes line up on one another,
## and the shifts are only ever increased — the font's own numbers are the
## starting point and the minimum gaps are what can push past them.
proc layoutFrac(n: MathNode, f: MathFont, baseSize: float,
                st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  let disp = isDisplay(st)
  var num = layoutNode(n.num, f, baseSize, numStyle(st))
  var den = layoutNode(n.den, f, baseSize, denStyle(st))
  let axis = du(mc, mc.axisHeight, sz)
  let theta =
    if n.barThickness < 0.0: du(mc, mc.fractionRuleThickness, sz)
    else: n.barThickness
  var u: float
  var v: float
  if theta <= 0.0:
    u = du(mc, (if disp: mc.stackTopDisplayStyleShiftUp else: mc.stackTopShiftUp), sz)
    v = du(mc, (if disp: mc.stackBottomDisplayStyleShiftDown
                else: mc.stackBottomShiftDown), sz)
    let gapMin = du(mc, (if disp: mc.stackDisplayStyleGapMin else: mc.stackGapMin), sz)
    let deficit = gapMin - (u + v - num.descent - den.ascent)
    if deficit > 0.0:
      # Split evenly, as TeX does for `\atop`: with no rule to anchor them
      # there is no reason to move one box further than the other.
      u += deficit / 2.0
      v += deficit / 2.0
  else:
    u = du(mc, (if disp: mc.fractionNumeratorDisplayStyleShiftUp
                else: mc.fractionNumeratorShiftUp), sz)
    v = du(mc, (if disp: mc.fractionDenominatorDisplayStyleShiftDown
                else: mc.fractionDenominatorShiftDown), sz)
    let numGap = du(mc, (if disp: mc.fractionNumDisplayStyleGapMin
                         else: mc.fractionNumeratorGapMin), sz)
    let denGap = du(mc, (if disp: mc.fractionDenomDisplayStyleGapMin
                         else: mc.fractionDenominatorGapMin), sz)
    let d1 = numGap - ((u - num.descent) - (axis + theta / 2.0))
    if d1 > 0.0: u += d1
    let d2 = denGap - ((axis - theta / 2.0) - (den.ascent - v))
    if d2 > 0.0: v += d2

  let w = max(num.width, den.width)
  num.x = (w - num.width) / 2.0
  num.y = -u
  den.x = (w - den.width) / 2.0
  den.y = v
  var kids = @[num]
  if theta > 0.0:
    # The rule's own baseline is placed on the axis and it is half its
    # thickness on each side, so `child.y == -axisHeight` is literally the
    # statement that the bar sits on the axis.
    kids.add MathBox(kind: bxRule, x: 0.0, y: -axis, width: w,
                     ascent: theta / 2.0, descent: theta / 2.0)
  kids.add den
  result = container(kids)
  result.width = w

## Function purpose: pick the vertical variant that first reaches `needed`.
## Returning the index rather than a glyph name is what lets the drawing phase
## ask the same font for the same variant; `stretch` non-zero means no variant
## was tall enough and the glyph has to be assembled from its parts.
proc pickVariant(f: MathFont, text: string, size, needed: float):
    tuple[box: GlyphBox, variant: int, stretch: float] =
  let base = measureRun(f, text, size, true)
  if base.ascent + base.descent >= needed:
    return (base, -1, 0.0)
  let vs = variantList(f, text, size)
  for i in 0 ..< vs.len:
    if vs[i].ascent + vs[i].descent >= needed:
      return (GlyphBox(width: vs[i].width, ascent: vs[i].ascent,
                       descent: vs[i].descent,
                       italicCorrection: vs[i].italicCorrection), i, 0.0)
  if vs.len > 0:
    let last = vs[^1]
    return (GlyphBox(width: last.width, ascent: last.ascent,
                     descent: last.descent,
                     italicCorrection: last.italicCorrection), vs.len - 1, needed)
  (base, -1, needed)

## Function purpose: a delimiter grown to cover its contents and centred on the
## axis, which is what makes the two halves of `\left( … \right)` the same
## height regardless of what sits between them.
proc layoutDelimiter(f: MathFont, text: string, size, axis, needed: float): MathBox =
  if text.len == 0:
    return MathBox(kind: bxList, width: 0.0, ascent: 0.0, descent: 0.0)
  let (g, variant, stretch) = pickVariant(f, text, size, needed)
  result = glyphBox(text, size, true, g)
  result.variant = variant
  result.stretchTo = stretch
  # Centre the glyph on the axis: its own midpoint sits `axis` above the
  # baseline of the box it is placed in.
  let shift = -axis + (g.ascent - g.descent) / 2.0
  result.ascent = g.ascent - shift
  result.descent = g.descent + shift
  result.italicCorrection = 0.0

## Function purpose: `\left … \right`. The body is laid out first because the
## delimiters cannot be sized until the thing they surround has been measured,
## which is the whole difference between a growing fence and a fixed one.
proc layoutFenced(n: MathNode, f: MathFont, baseSize: float,
                  st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  let axis = du(mc, mc.axisHeight, sz)
  var body = layoutNode(n.body, f, baseSize, st)
  # Both halves must cover the content measured from the axis, so the taller
  # side decides and the delimiter stays symmetric about it.
  let reach = max(body.ascent - axis, body.descent + axis)
  let needed = max(2.0 * reach, du(mc, mc.delimitedSubFormulaMinHeight, sz))
  var lb = layoutDelimiter(f, n.left, sz, axis, needed)
  var rb = layoutDelimiter(f, n.right, sz, axis, needed)
  lb.x = 0.0
  body.x = lb.width
  rb.x = lb.width + body.width
  var kids: seq[MathBox]
  if n.left.len > 0: kids.add lb
  kids.add body
  if n.right.len > 0: kids.add rb
  result = container(kids)
  result.width = lb.width + body.width + rb.width

## Function purpose: scripts, by Appendix G rule 18. Simultaneous scripts are
## stacked and then pushed apart until the font's minimum gap is met, which is
## the difference between `x^2_i` reading as two marks and reading as one
## smudge.
proc layoutScripts(n: MathNode, f: MathFont, baseSize: float,
                   st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  var base = layoutNode(n.base, f, baseSize, st)
  let delta = base.italicCorrection
  var kids = @[base]
  var supB, subB: MathBox
  var haveSup = n.sup != nil
  var haveSub = n.sub != nil
  var u = 0.0
  var v = 0.0
  if haveSup:
    supB = layoutNode(n.sup, f, baseSize, supStyle(st))
    let shiftUp = du(mc, (if isCramped(st): mc.superscriptShiftUpCramped
                          else: mc.superscriptShiftUp), sz)
    u = max(shiftUp, base.ascent - du(mc, mc.superscriptBaselineDropMax, sz))
    u = max(u, du(mc, mc.superscriptBottomMin, sz) + supB.descent)
  if haveSub:
    subB = layoutNode(n.sub, f, baseSize, subStyle(st))
    v = max(du(mc, mc.subscriptShiftDown, sz),
            base.descent + du(mc, mc.subscriptBaselineDropMin, sz))
    v = max(v, subB.ascent - du(mc, mc.subscriptTopMax, sz))
  if haveSup and haveSub:
    let gapMin = du(mc, mc.subSuperscriptGapMin, sz)
    let deficit = gapMin - (u + v - supB.descent - subB.ascent)
    if deficit > 0.0:
      # TeX pushes the subscript down by the whole shortfall first, then lifts
      # the superscript back up as far as its bottom may rise and takes the
      # same amount off the subscript again. Doing it in that order keeps the
      # gap exact while leaving the pair as close to the baseline as the font
      # allows.
      v += deficit
      let room = du(mc, mc.superscriptBottomMaxWithSubscript, sz) - (u - supB.descent)
      if room > 0.0:
        u += room
        v -= room
  let spaceAfter = du(mc, mc.spaceAfterScript, sz)
  var scriptWidth = 0.0
  if haveSup:
    # Only the superscript moves right by the base's italic correction; the
    # subscript stays under the base's own end, which is what stops `x^2_i`
    # from looking like two separate marks.
    supB.x = base.width + delta
    supB.y = -u
    scriptWidth = max(scriptWidth, supB.width + delta)
    kids.add supB
  if haveSub:
    subB.x = base.width
    subB.y = v
    scriptWidth = max(scriptWidth, subB.width)
    kids.add subB
  result = container(kids)
  result.width = base.width + scriptWidth + spaceAfter
  result.italicCorrection = 0.0

## Function purpose: the radical of Appendix G rule 11. The radicand is set
## cramped so that anything raised inside it stays clear of the over-rule, and
## the surd is grown until it spans the radicand, the gap and the rule.
proc layoutRadical(n: MathNode, f: MathFont, baseSize: float,
                   st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  var rad = layoutNode(n.radicand, f, baseSize, cramped(st))
  let theta = du(mc, mc.radicalRuleThickness, sz)
  var gap = du(mc, (if isDisplay(st): mc.radicalDisplayStyleVerticalGap
                    else: mc.radicalVerticalGap), sz)
  let inner = rad.ascent + rad.descent
  let needed = inner + gap + theta
  let (g, variant, stretch) = pickVariant(f, "√", sz, needed)
  let have = g.ascent + g.descent
  # A variant taller than asked for leaves slack; TeX gives half of it to the
  # gap so the radicand sits centred under the rule rather than pinned to it.
  if have > needed: gap += (have - needed) / 2.0
  var surd = glyphBox("√", sz, true, g)
  surd.variant = variant
  surd.stretchTo = stretch
  let ruleTop = -(rad.ascent + gap + theta)
  surd.x = 0.0
  surd.y = ruleTop + g.ascent
  rad.x = surd.width
  rad.y = 0.0
  var kids = @[surd, rad]
  kids.add MathBox(kind: bxRule, x: surd.width, y: ruleTop + theta / 2.0,
                   width: rad.width, ascent: theta / 2.0, descent: theta / 2.0)
  var degreeWidth = 0.0
  if n.index != nil:
    # The degree is set two sizes down and raised by a percentage of the surd's
    # own height, so it rides the diagonal instead of sitting on the baseline.
    var deg = layoutNode(n.index, f, baseSize, msScriptScript)
    let kernBefore = du(mc, mc.radicalKernBeforeDegree, sz)
    let kernAfter = du(mc, mc.radicalKernAfterDegree, sz)
    let surdHeight = g.ascent + g.descent
    let degreeRaise = mc.radicalDegreeBottomRaisePercent / 100.0 * surdHeight
    deg.x = kernBefore
    deg.y = (ruleTop + surdHeight) - degreeRaise - deg.descent
    degreeWidth = kernBefore + deg.width + kernAfter
    for i in 0 ..< kids.len: kids[i].x += degreeWidth
    kids.insert(deg, 0)
  result = container(kids)
  result.ascent = max(result.ascent,
                      -ruleTop + du(mc, mc.radicalExtraAscender, sz))
  result.width = degreeWidth + surd.width + rad.width

## Function purpose: a large operator on its own, centred vertically on the
## axis. In display style it is grown to the font's `DisplayOperatorMinHeight`,
## which is what makes a display `\sum` visibly larger than an inline one.
proc layoutBigOp(n: MathNode, f: MathFont, baseSize: float,
                 st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  let axis = du(mc, mc.axisHeight, sz)
  var g: GlyphBox
  var variant = -1
  var stretch = 0.0
  if isDisplay(st) and not n.opUpright:
    let needed = du(mc, mc.displayOperatorMinHeight, sz)
    (g, variant, stretch) = pickVariant(f, n.opText, sz, needed)
  else:
    g = measureRun(f, n.opText, sz, n.opUpright)
  result = glyphBox(n.opText, sz, n.opUpright, g)
  result.variant = variant
  result.stretchTo = stretch
  if not n.opUpright:
    # A symbol operator is centred on the axis; a word operator like `lim` is
    # a word and stays on the baseline.
    let shift = -axis + (g.ascent - g.descent) / 2.0
    result.ascent = g.ascent - shift
    result.descent = g.descent + shift

proc opTakesLimits(n: MathNode, st: MathStyle): bool =
  ## Limits go above and below only in display style, and only where the
  ## operator asks for them.
  case n.limits
  of lmLimits: true
  of lmNoLimits: false
  of lmDefault: isDisplay(st) and n.defaultLimits

## Function purpose: limits over and under a large operator, by Appendix G rule
## 13. Each limit is centred on the operator and nudged by half the italic
## correction, which is what keeps a bound over a slanted integral sign from
## drifting left.
proc layoutLimits(scripts: MathNode, f: MathFont, baseSize: float,
                  st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  var op = layoutBigOp(scripts.base, f, baseSize, st)
  let delta = op.italicCorrection
  var upper, lower: MathBox
  let haveUp = scripts.sup != nil
  let haveLow = scripts.sub != nil
  if haveUp: upper = layoutNode(scripts.sup, f, baseSize, supStyle(st))
  if haveLow: lower = layoutNode(scripts.sub, f, baseSize, subStyle(st))
  var w = op.width
  if haveUp: w = max(w, upper.width + delta)
  if haveLow: w = max(w, lower.width)
  op.x = (w - op.width) / 2.0
  op.y = 0.0
  var kids = @[op]
  if haveUp:
    let byGap = -op.ascent - du(mc, mc.upperLimitGapMin, sz) - upper.descent
    let byRise = -op.ascent - du(mc, mc.upperLimitBaselineRiseMin, sz)
    upper.y = min(byGap, byRise)
    upper.x = (w - upper.width) / 2.0 + delta / 2.0
    kids.add upper
  if haveLow:
    let byGap = op.descent + du(mc, mc.lowerLimitGapMin, sz) + lower.ascent
    let byDrop = op.descent + du(mc, mc.lowerLimitBaselineDropMin, sz)
    lower.y = max(byGap, byDrop)
    lower.x = (w - lower.width) / 2.0 - delta / 2.0
    kids.add lower
  var minX = 0.0
  for k in kids: minX = min(minX, k.x)
  if minX < 0.0:
    for i in 0 ..< kids.len: kids[i].x -= minX
  result = container(kids)
  result.width = w - minX

## Function purpose: a matrix, its rows stacked and its columns aligned, the
## whole centred on the axis so that a delimiter around it grows symmetrically.
## Cells are set in text style: a display-size fraction inside a matrix would
## be taller than the row it lives in.
proc layoutMatrix(n: MathNode, f: MathFont, baseSize: float,
                  st: MathStyle): MathBox =
  let mc = f.constants
  let sz = styleSize(mc, baseSize, st)
  let cellStyle = if isDisplay(st): (if isCramped(st): msTextCramped else: msText)
                  else: st
  var cells: seq[seq[MathBox]]
  var cols = 0
  for row in n.rows:
    var r: seq[MathBox]
    for c in row: r.add layoutNode(c, f, baseSize, cellStyle)
    cols = max(cols, r.len)
    cells.add r
  var colWidth = newSeq[float](cols)
  for r in cells:
    for j in 0 ..< r.len: colWidth[j] = max(colWidth[j], r[j].width)
  let colGap = du(mc, mc.matrixColumnGap, sz)
  let rowGap = du(mc, mc.matrixRowGap, sz)
  var totalWidth = 0.0
  for j in 0 ..< cols:
    totalWidth += colWidth[j]
    if j + 1 < cols: totalWidth += colGap
  # Lay the rows out from a zero origin first, then move the whole block so
  # that its vertical middle lands on the axis.
  var kids: seq[MathBox]
  var pen = 0.0
  var firstAscent = 0.0
  for i in 0 ..< cells.len:
    var rowAsc = 0.0
    var rowDesc = 0.0
    for b in cells[i]:
      rowAsc = max(rowAsc, b.ascent)
      rowDesc = max(rowDesc, b.descent)
    if i == 0: firstAscent = rowAsc
    else: pen += rowGap + rowAsc
    var x = 0.0
    for j in 0 ..< cells[i].len:
      var b = cells[i][j]
      b.x = x + (colWidth[j] - b.width) / 2.0
      b.y = pen
      kids.add b
      x += colWidth[j] + colGap
    pen += rowDesc
  let height = firstAscent + pen
  let axis = du(mc, mc.axisHeight, sz)
  let shift = height / 2.0 - firstAscent + axis
  for i in 0 ..< kids.len: kids[i].y -= shift
  result = container(kids)
  result.width = totalWidth

## Function purpose: the single dispatch over node kinds, so that adding a kind
## is a compile error here rather than a node that silently lays out as nothing.
proc layoutNode(n: MathNode, f: MathFont, baseSize: float,
                st: MathStyle): MathBox =
  if n == nil: return MathBox(kind: bxList)
  case n.kind
  of mnList: layoutRow(n.items, f, baseSize, st)
  of mnAtom:
    let sz = styleSize(f.constants, baseSize, st)
    glyphBox(n.text, sz, n.upright, measureRun(f, n.text, sz, n.upright))
  of mnFrac: layoutFrac(n, f, baseSize, st)
  of mnScripts:
    if n.base != nil and n.base.kind == mnBigOp and opTakesLimits(n.base, st):
      layoutLimits(n, f, baseSize, st)
    else:
      layoutScripts(n, f, baseSize, st)
  of mnRadical: layoutRadical(n, f, baseSize, st)
  of mnBigOp: layoutBigOp(n, f, baseSize, st)
  of mnMatrix: layoutMatrix(n, f, baseSize, st)
  of mnFenced: layoutFenced(n, f, baseSize, st)
  of mnSpace:
    MathBox(kind: bxList, width: n.amount * styleSize(f.constants, baseSize, st))
  of mnStyled:
    if n.inner == nil: MathBox(kind: bxList)
    else: layoutNode(n.inner, f, baseSize, n.forced)

## Function purpose: lay a tree out. Split from `parseMath` so a caller that
## already has a tree — a cache, or a test — need not re-parse to re-lay it at
## another size.
proc layoutMath*(root: MathNode, font: MathFont, fontSize: float,
                 style: MathStyle): MathBox =
  layoutNode(root, font, fontSize, style)

## Function purpose: source to boxes, the whole path a renderer needs. A refusal
## comes back as `ok = false` with a sentence, never as an empty box: an empty
## box is indistinguishable from a formula that laid out to nothing.
proc renderMath*(src: string, font: MathFont, fontSize: float,
                 display: bool): MathLayout =
  let parsed = parseMath(src)
  if not parsed.ok:
    return MathLayout(ok: false, error: parsed.error, errorPos: parsed.errorPos)
  MathLayout(ok: true, box: layoutMath(parsed.root, font, fontSize,
                                       if display: msDisplay else: msText))

## Function purpose: the source a box tree came from, for the caller that has to
## show something when layout is refused and for reading a tree back in a test.
proc describe*(n: MathNode): string =
  if n == nil: return ""
  case n.kind
  of mnList:
    for it in n.items: result.add describe(it)
  of mnAtom: result = n.text
  of mnFrac: result = "\\frac{" & describe(n.num) & "}{" & describe(n.den) & "}"
  of mnScripts:
    result = describe(n.base)
    if n.sub != nil: result.add "_{" & describe(n.sub) & "}"
    if n.sup != nil: result.add "^{" & describe(n.sup) & "}"
  of mnRadical:
    result = "\\sqrt"
    if n.index != nil: result.add "[" & describe(n.index) & "]"
    result.add "{" & describe(n.radicand) & "}"
  of mnBigOp: result = n.opText
  of mnMatrix:
    for i, row in n.rows:
      if i > 0: result.add " \\\\ "
      for j, c in row:
        if j > 0: result.add " & "
        result.add describe(c)
  of mnFenced:
    result = n.left & describe(n.body) & n.right
  of mnSpace: result = " "
  of mnStyled: result = describe(n.inner)
