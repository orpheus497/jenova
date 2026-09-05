## Script function and purpose: split an assistant message into renderable blocks
## and turn inline markdown into Pango markup, so the transcript reads like the
## Web UI's `MarkdownContent` rather than one flat string.

import std/[strutils, tables]

type
  BlockKind* = enum bkText, bkCode, bkTable
  Block* = object
    kind*: BlockKind
    text*: string
    lang*: string
    ## Rows of marked-up cells rather than one string, because Pango has no
    ## table and it has to become a real `Grid` of `Label`s. Row 0 is the header
    ## and `aligns` is one `xAlign` per column, so the widget layer applies the
    ## alignment without re-parsing anything.
    rows*: seq[seq[string]]
    aligns*: seq[float]
    ## False only for a fenced code block whose closing fence has not arrived,
    ## which is every code block while the reply is still streaming. The widget
    ## layer refuses to copy one: half a snippet on the clipboard looks whole
    ## and pastes as something that does not run.
    complete*: bool

const CodeCapLines* = 24
  ## Above this many lines a code block is capped in place and scrolls inside
  ## itself, so one long answer cannot push the rest of the transcript off
  ## screen. Roughly a screenful, which is the point at which scrolling the
  ## block beats scrolling the conversation. Here rather than beside the widget
  ## that applies it, so which blocks are too long to read in place is decidable
  ## — and asserted — with no window.

## Function purpose: whether a code block is longer than can be read where it
## sits, which is what the preview surface exists for.
proc isLongCode*(b: Block): bool =
  b.kind == bkCode and b.text.countLines > CodeCapLines

## Function purpose: runs before every other pass, because Pango markup and
## the source text share these three characters.
proc escape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

## Function purpose: the general form behind every emphasis pass, so a delimiter
## that opens two tags at once can share the scanning rules with one that opens
## a single tag.
##
## Action purpose: three rules, each for a defect seen in real replies. A run
## only opens where a non-blank follows it and only closes where a non-blank
## precedes it, so `2 * 3 * 4` is arithmetic rather than an italic `3`. An empty
## run is not emphasis, so a `**` the bold pass has already declined survives as
## the two characters the model wrote instead of being consumed here as an empty
## italic. An unpaired delimiter is left as literal text, because a reply is
## read while it streams and a half-typed run must not swallow the rest of the
## line.
proc inlineWrap(s, delim, open, close: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    var start = s.find(delim, i)
    while start >= 0 and (start + delim.len >= s.len or
                          s[start + delim.len] in {' ', '\t'}):
      start = s.find(delim, start + delim.len)
    if start < 0:
      result.add s[i .. ^1]
      break
    var stop = s.find(delim, start + delim.len)
    while stop > 0 and s[stop - 1] in {' ', '\t'}:
      stop = s.find(delim, stop + delim.len)
    if stop < 0:
      result.add s[i .. ^1]
      break
    if stop == start + delim.len:
      result.add s[i ..< stop]
      i = stop
      continue
    result.add s[i ..< start]
    result.add open & s[start + delim.len ..< stop] & close
    i = stop + delim.len

proc inlineSpan(s: string, delim: string, tag: string): string =
  inlineWrap(s, delim, "<" & tag & ">", "</" & tag & ">")

## The characters this renderer acts on, and therefore the ones a backslash has
## to be able to take back. `[` and `]` are deliberately absent: `\[` opens
## display math in every model that writes any, and consuming the backslash here
## would destroy the delimiter before anything can decide what to do with it.
## `$` is present for the opposite reason: lifting `\$` out here is what makes
## an escaped dollar a price rather than the opening of a formula.
const Escapable = {'*', '_', '~', '`', '\\', '$'}

## Function purpose: whether the markup handed to Pango is one Pango will
## accept. Pango's parser is XML-shaped and rejects the whole string on a single
## mismatched tag or unknown entity — the label then draws nothing, so one
## crossed `**`/`~~` pair loses the entire line rather than its emphasis.
##
## Action purpose: the emphasis passes run one delimiter at a time and cannot
## see each other, so `*a~~b*c~~` produces correctly-paired tags in the wrong
## order and no ordering of the passes fixes it. This is the check that catches
## what the passes cannot, so the fallback below is reachable rather than
## theoretical.
proc markupBalanced*(s: string): bool =
  var stack: seq[string] = @[]
  var i = 0
  while i < s.len:
    case s[i]
    of '<':
      let shut = s.find('>', i + 1)
      if shut < 0: return false
      var j = i + 1
      let closing = j < s.len and s[j] == '/'
      if closing: j.inc
      var name = ""
      while j < shut and s[j] notin {' ', '/'}: name.add s[j]; j.inc
      if name.len == 0: return false
      if closing:
        if stack.len == 0 or stack[^1] != name: return false
        stack.setLen(stack.len - 1)
      else:
        stack.add name
      # An unbalanced quote inside a tag lets the attribute run past its own
      # `>`, which is how a href would escape into markup.
      if s[i + 1 ..< shut].count('"') mod 2 != 0: return false
      i = shut + 1
    of '>':
      # `escape` turns every `>` in the source into `&gt;`, so one here is a
      # tag this scan did not open.
      return false
    of '&':
      let semi = s.find(';', i + 1)
      if semi < 0 or s[i + 1 ..< semi] notin ["amp", "lt", "gt", "quot", "apos"]:
        return false
      i = semi + 1
    else: i.inc
  stack.len == 0

## Superscript and subscript are spelled with `rise` rather than `<sup>`/`<sub>`
## because `rise` is accepted by every Pango that accepts either and the target
## host's Pango version is not known here. The displacements are measured, not
## chosen: against Pango 1.52.1 they place the script within one pixel of
## `<sup>`/`<sub>` at every size from 9pt to 16pt, which covers the whole range
## a desktop UI font is set at.
const
  MathSup = "<span rise='6000' size='smaller'>"
  MathSub = "<span rise='-3000' size='smaller'>"
  MathScriptEnd = "</span>"

## Function purpose: the character a TeX control sequence names, or the empty
## string for one this renderer does not know — an unknown name is what makes a
## formula decline as a whole rather than render half of itself.
proc mathSymbol(name: string): string =
  case name
  # The `var` forms are separate Unicode letters rather than styles, and TeX
  # spells them the other way round from the reading order most people expect:
  # `\epsilon` is the lunate one.
  of "alpha": "α"
  of "beta": "β"
  of "gamma": "γ"
  of "delta": "δ"
  of "epsilon": "ϵ"
  of "varepsilon": "ε"
  of "zeta": "ζ"
  of "eta": "η"
  of "theta": "θ"
  of "vartheta": "ϑ"
  of "iota": "ι"
  of "kappa": "κ"
  of "lambda": "λ"
  of "mu": "μ"
  of "nu": "ν"
  of "xi": "ξ"
  of "omicron": "ο"
  of "pi": "π"
  of "varpi": "ϖ"
  of "rho": "ρ"
  of "varrho": "ϱ"
  of "sigma": "σ"
  of "varsigma": "ς"
  of "tau": "τ"
  of "upsilon": "υ"
  of "phi": "ϕ"
  of "varphi": "φ"
  of "chi": "χ"
  of "psi": "ψ"
  of "omega": "ω"
  of "digamma": "ϝ"
  of "Gamma": "Γ"
  of "Delta": "Δ"
  of "Theta": "Θ"
  of "Lambda": "Λ"
  of "Xi": "Ξ"
  of "Pi": "Π"
  of "Sigma": "Σ"
  of "Upsilon": "Υ"
  of "Phi": "Φ"
  of "Psi": "Ψ"
  of "Omega": "Ω"
  # Large operators. They render at text size here because Pango has no
  # display style, so a sum sign is the same height as the letters beside it.
  of "sum": "∑"
  of "prod": "∏"
  of "coprod": "∐"
  of "int": "∫"
  of "iint": "∬"
  of "iiint": "∭"
  of "oint": "∮"
  of "bigcup": "⋃"
  of "bigcap": "⋂"
  of "bigoplus": "⨁"
  of "bigotimes": "⨂"
  of "surd": "√"
  # Binary operators.
  of "pm": "±"
  of "mp": "∓"
  of "times": "×"
  of "div": "÷"
  of "cdot": "⋅"
  of "ast": "∗"
  of "star": "⋆"
  of "circ": "∘"
  of "bullet": "∙"
  of "oplus": "⊕"
  of "ominus": "⊖"
  of "otimes": "⊗"
  of "oslash": "⊘"
  of "odot": "⊙"
  of "cap": "∩"
  of "cup": "∪"
  of "sqcap": "⊓"
  of "sqcup": "⊔"
  of "vee", "lor": "∨"
  of "wedge", "land": "∧"
  of "setminus": "∖"
  of "backslash": "∖"
  of "triangleleft": "◁"
  of "triangleright": "▷"
  # Relations.
  of "leq", "le": "≤"
  of "geq", "ge": "≥"
  of "neq", "ne": "≠"
  of "equiv": "≡"
  of "sim": "∼"
  of "simeq": "≃"
  of "cong": "≅"
  of "approx": "≈"
  of "asymp": "≍"
  of "propto": "∝"
  of "doteq": "≐"
  of "ll": "≪"
  of "gg": "≫"
  of "prec": "≺"
  of "succ": "≻"
  of "preceq": "⪯"
  of "succeq": "⪰"
  of "subset": "⊂"
  of "supset": "⊃"
  of "subseteq": "⊆"
  of "supseteq": "⊇"
  of "sqsubseteq": "⊑"
  of "sqsupseteq": "⊒"
  of "in": "∈"
  of "notin": "∉"
  of "ni": "∋"
  of "mid": "∣"
  of "parallel": "∥"
  of "perp": "⊥"
  of "models": "⊨"
  of "vdash": "⊢"
  of "dashv": "⊣"
  # Arrows.
  of "to", "rightarrow": "→"
  of "leftarrow", "gets": "←"
  of "Rightarrow": "⇒"
  of "Leftarrow": "⇐"
  of "leftrightarrow": "↔"
  of "Leftrightarrow": "⇔"
  of "longrightarrow": "⟶"
  of "longleftarrow": "⟵"
  of "implies", "Longrightarrow": "⟹"
  of "iff", "Longleftrightarrow": "⟺"
  of "mapsto": "↦"
  of "hookrightarrow": "↪"
  of "uparrow": "↑"
  of "downarrow": "↓"
  of "nearrow": "↗"
  of "searrow": "↘"
  # Symbols and named constants.
  of "infty": "∞"
  of "partial": "∂"
  of "nabla": "∇"
  of "forall": "∀"
  of "exists": "∃"
  of "nexists": "∄"
  of "neg", "lnot": "¬"
  of "emptyset", "varnothing": "∅"
  of "aleph": "ℵ"
  of "hbar": "ℏ"
  of "ell": "ℓ"
  of "Re": "ℜ"
  of "Im": "ℑ"
  of "wp": "℘"
  of "imath": "ı"
  of "jmath": "ȷ"
  of "angle": "∠"
  of "measuredangle": "∡"
  of "triangle": "△"
  of "square": "□"
  of "top": "⊤"
  of "bot": "⊥"
  of "degree": "°"
  of "prime": "′"
  of "therefore": "∴"
  of "because": "∵"
  of "checkmark": "✓"
  of "dagger": "†"
  of "ldots", "dots": "…"
  of "cdots": "⋯"
  of "vdots": "⋮"
  of "ddots": "⋱"
  # Delimiters. These are the fixed-size forms; growing one to fit its contents
  # needs the font's own glyph variants and is not something markup can ask for.
  of "langle": "⟨"
  of "rangle": "⟩"
  of "lfloor": "⌊"
  of "rfloor": "⌋"
  of "lceil": "⌈"
  of "rceil": "⌉"
  of "lbrace": "{"
  of "rbrace": "}"
  # Explicit spaces, which a model writes to correct spacing TeX would not
  # otherwise give it.
  of "quad": " "
  of "qquad": "  "
  of "thinspace": " "
  else: ""

## Function purpose: the names TeX sets upright instead of italic. That is the
## one piece of real mathematical typography markup can express — upright marks
## an operator and italic marks a variable, so an italic `sin` reads as s times
## i times n.
proc mathUpright(name: string): bool =
  case name
  of "arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth",
     "csc", "deg", "det", "dim", "exp", "gcd", "hom", "inf", "ker", "lg",
     "lim", "liminf", "limsup", "ln", "log", "max", "min", "Pr", "sec",
     "sin", "sinh", "sup", "tan", "tanh": true
  else: false

## Function purpose: the double-struck letter `\mathbb` names, for the sets a
## reply actually mentions. Only the letters Unicode gives a character to, so an
## unknown one declines the formula rather than drawing a plain capital that
## means something else.
proc mathDoubleStruck(letter: char): string =
  case letter
  of 'C': "ℂ"
  of 'H': "ℍ"
  of 'N': "ℕ"
  of 'P': "ℙ"
  of 'Q': "ℚ"
  of 'R': "ℝ"
  of 'Z': "ℤ"
  of 'E': "𝔼"
  of 'F': "𝔽"
  of 'K': "𝕂"
  else: ""

## Function purpose: the combining mark a TeX accent puts over its argument.
## A combining character follows the one it modifies in the text stream, which
## is exactly where an accent belongs, so this needs no drawing of its own.
proc mathAccent(name: string): string =
  case name
  of "hat", "widehat": "\u0302"
  of "bar", "overline": "\u0304"
  of "tilde", "widetilde": "\u0303"
  of "vec": "\u20D7"
  of "dot": "\u0307"
  of "ddot": "\u0308"
  of "check": "\u030C"
  of "acute": "\u0301"
  of "grave": "\u0300"
  of "breve": "\u0306"
  of "mathring": "\u030A"
  else: ""

const MathMaxDepth = 64
  ## The nesting these three will follow before declining the formula. They are
  ## mutually recursive over a structure the *source* dictates — a braced group
  ## contains a run, a run contains items, an item opens a group — so a reply
  ## carrying `{{{{`…`}}}}` recurses once per level with nothing but the C stack
  ## to stop it. That source is an assistant message, and messages arrive over
  ## the network and through import: a long enough line of balanced braces
  ## overflows the stack, which is a crash and not a rendering fault.
  ##
  ## Sixty-four is about twenty brace levels — one costs three frames,
  ## `mathItem` into `mathArg` into `mathRun` — against a real formula that
  ## rarely passes six.
  ## Declining costs the reader the markup and leaves the source visible, which
  ## is what every other refusal in this renderer already does.

# Mutually recursive: an argument is a run of items and an item can take an
# argument, so both names exist before either body.
proc mathItem(src: string, i: var int, stop: int, dst: var string,
              upright: bool, atoms: var int, depth: int): bool
proc mathRun(src: string, i: var int, stop: int, dst: var string,
             upright: bool, atoms: var int, depth: int): bool

## Function purpose: what TeX takes after `^`, `_` or `\sqrt` — a braced group,
## a control sequence or a single character — so `x^2` and `x^{n+1}` are one
## code path rather than two.
proc mathArg(src: string, i: var int, stop: int, dst: var string,
             upright: bool, atoms: var int, depth: int): bool =
  if depth > MathMaxDepth: return false
  if i >= stop: return false
  if src[i] != '{':
    return mathItem(src, i, stop, dst, upright, atoms, depth + 1)
  # `nest` and not `depth`: the brace counter is a different quantity from the
  # recursion depth above it, and spelling both the same shadowed the parameter
  # so that every recursive call passed this counter — which is zero at the
  # break — and the cap could never be reached.
  var nest = 0
  var j = i
  while j < stop:
    if src[j] == '{': nest.inc
    elif src[j] == '}':
      nest.dec
      if nest == 0: break
    j.inc
  # An unclosed group is a formula still being typed, and rendering half of it
  # would show a subscript that is about to grow.
  if j >= stop: return false
  var k = i + 1
  if not mathRun(src, k, j, dst, upright, atoms, depth + 1): return false
  i = j + 1
  true

## Function purpose: one atom of a formula. `atoms` counts what was emitted at
## this level, because a radical has to know whether its radicand is one thing
## or several and Pango draws no line over it to say.
proc mathItem(src: string, i: var int, stop: int, dst: var string,
              upright: bool, atoms: var int, depth: int): bool =
  if depth > MathMaxDepth: return false
  let c = src[i]
  case c
  of '&':
    # `escape` has already run, so `<`, `>` and `&` arrive as entities. They are
    # copied whole: splitting `&lt;` across an italic tag would make Pango
    # reject the entity and draw the line empty.
    let semi = src.find(';', i + 1)
    if semi < 0 or semi >= stop: return false
    dst.add src[i .. semi]
    atoms.inc
    i = semi + 1
    true
  of 'a' .. 'z', 'A' .. 'Z':
    if upright: dst.add c
    else: dst.add "<i>" & c & "</i>"
    atoms.inc
    i.inc
    true
  of '0' .. '9':
    # A whole numeral is one atom: `\sqrt{10}` has a single radicand, not two.
    while i < stop and src[i] in {'0' .. '9'}: dst.add src[i]; i.inc
    atoms.inc
    true
  of '\'':
    dst.add "′"
    atoms.inc
    i.inc
    true
  of '{':
    mathArg(src, i, stop, dst, upright, atoms, depth + 1)
  of '}':
    # A closing brace with nothing open is a formula this renderer has
    # misread, and guessing past it is how half a formula gets drawn.
    false
  of '^', '_':
    # A script binds to what precedes it, so it adds no atom of its own.
    dst.add(if c == '^': MathSup else: MathSub)
    var k = i + 1
    var inner = 0
    if not mathArg(src, k, stop, dst, upright, inner, depth + 1): return false
    dst.add MathScriptEnd
    i = k
    true
  of '\\':
    var j = i + 1
    var name = ""
    while j < stop and src[j] in {'a' .. 'z', 'A' .. 'Z'}: name.add src[j]; j.inc
    if name.len == 0:
      # A control sequence whose name is punctuation: TeX's literal braces and
      # its explicit spacing, which is what a model writes to correct spacing
      # that a real typesetter would have got right on its own.
      if j >= stop: return false
      case src[j]
      of '{', '}', '%', '#': dst.add src[j]; atoms.inc
      of '|': dst.add "\u2016"; atoms.inc
      of ',', ';', ':': dst.add " "
      of '!': discard
      of ' ': dst.add " "
      of '&':
        # A source ampersand reached `escape` before this pass did.
        if not src.substr(j, min(j + 4, stop - 1)).startsWith("&amp;"):
          return false
        dst.add "&amp;"
        atoms.inc
        j += 4
      else: return false
      i = j + 1
      return true
    i = j
    if name == "sqrt":
      dst.add "√"
      atoms.inc
      if i < stop and src[i] == '{':
        var inner = ""
        var innerAtoms = 0
        var k = i
        if not mathArg(src, k, stop, inner, upright, innerAtoms, depth + 1):
          return false
        i = k
        # Pango has no vinculum, so nothing marks where the radicand ends. A
        # radicand of more than one atom is parenthesised, or `√x+1` reads as
        # the square root of x, plus one.
        if innerAtoms > 1: dst.add "(" & inner & ")"
        else: dst.add inner
      return true
    if name == "mathbb":
      # One letter only, because the double-struck alphabet is the reason this
      # exists and a longer group would be a set name, not a set.
      if i + 2 < stop and src[i] == '{' and src[i + 2] == '}':
        let g = mathDoubleStruck(src[i + 1])
        if g.len == 0: return false
        dst.add g
        atoms.inc
        i += 3
        return true
      return false
    case name
    # A size or fence command styles the delimiter that follows it, and the
    # delimiter renders itself; there is nothing left for these to emit.
    of "left", "right", "big", "Big", "bigg", "Bigg",
       "bigl", "bigr", "Bigl", "Bigr", "displaystyle", "textstyle", "limits":
      return true
    of "text", "mathrm", "operatorname", "mathsf", "mathtt":
      var k = i
      if not mathArg(src, k, stop, dst, true, atoms, depth + 1): return false
      i = k
      return true
    of "mathbf", "mathit":
      let tag = if name == "mathbf": "b" else: "i"
      dst.add "<" & tag & ">"
      var k = i
      if not mathArg(src, k, stop, dst, true, atoms, depth + 1): return false
      i = k
      dst.add "</" & tag & ">"
      return true
    else: discard
    let accent = mathAccent(name)
    if accent.len > 0:
      var accented = ""
      var accentedAtoms = 0
      var k = i
      if not mathArg(src, k, stop, accented, upright, accentedAtoms,
                     depth + 1):
        return false
      # A combining mark lands on one character. An accent over more than one
      # would sit over the last of them and assert something the formula does
      # not, so the formula stays as its source instead.
      if accentedAtoms != 1: return false
      i = k
      dst.add accented & accent
      atoms.inc
      return true
    if mathUpright(name):
      dst.add name
      atoms.inc
      return true
    let sym = mathSymbol(name)
    if sym.len == 0: return false
    dst.add sym
    atoms.inc
    true
  of ' ', '\t':
    dst.add ' '
    i.inc
    true
  of '$':
    # A dollar inside a formula is a delimiter the scanner did not pair, which
    # means the formula was never closed where it looked closed.
    false
  else:
    if c < ' ':
      # A placeholder byte from the code-span, link or backslash pass. Maths
      # that overlaps one of those is not maths.
      return false
    dst.add c
    # A UTF-8 continuation byte is the tail of a character already counted.
    if (c.uint8 and 0xC0'u8) != 0x80'u8: atoms.inc
    i.inc
    true

## Function purpose: renders `src[i ..< stop]`, failing as a whole rather than
## in part, so a formula either arrives correct or stays visible as its source.
proc mathRun(src: string, i: var int, stop: int, dst: var string,
             upright: bool, atoms: var int, depth: int): bool =
  if depth > MathMaxDepth: return false
  while i < stop:
    if not mathItem(src, i, stop, dst, upright, atoms, depth + 1): return false
  true

## Function purpose: the Pango markup for one inline formula's already-escaped
## source, or the empty string when this renderer declines it. The caller then
## leaves the source visible: a formula rendered wrongly does not tell the
## reader to distrust it, and an unrendered one does.
proc mathMarkup(src: string): string =
  if src.len == 0: return ""
  var i = 0
  var atoms = 0
  var dst = newStringOfCap(src.len * 6)
  if not mathRun(src, i, src.len, dst, false, atoms, 0): return ""
  # The same guard the whole line ends on, applied to the fragment, so a
  # formula that cannot be marked up costs its own delimiters rather than every
  # word around it.
  if not markupBalanced(dst): return ""
  dst

const LinkSchemes = ["http://", "https://"]

## Function purpose: the security boundary of the whole link feature. GTK hands
## an activated `<a href>` to the desktop URI handler, so a model writing a
## `file:`, `javascript:` or `data:` destination would be handing the desktop an
## instruction. Only `http` and `https` become anchors and everything else
## renders as its own text with no destination, which is a visible loss rather
## than a silent one.
##
## Action purpose: an allowlist, because the set of schemes a desktop will act
## on is open-ended and a denylist cannot be completed.
proc allowedHref(href: string): bool =
  let lower = href.toLowerAscii
  for s in LinkSchemes:
    if href.len > s.len and lower.startsWith(s): return true
  false

## Function purpose: code spans are lifted out before the emphasis passes and
## put back after. Marking them up in place leaves their contents in the string,
## so `*` and `_` inside a span are still read as emphasis — the one thing a code
## span exists to prevent. The NUL placeholder cannot occur in escaped text and
## carries no emphasis delimiter of its own.
proc inlineMarkup*(line: string): string =
  # Action purpose: a backslash escape is lifted before anything else, because
  # its whole job is to hide the character from every pass below. The
  # placeholder is a control byte for the reason the code-span one is: it
  # cannot occur in the source and carries no delimiter of its own. A backslash
  # in front of anything outside the set is not an escape and stays as written,
  # which is what keeps a Windows path readable.
  var literals: seq[char] = @[]
  var unescaped = newStringOfCap(line.len)
  var e = 0
  while e < line.len:
    if line[e] == '\\' and e + 1 < line.len and line[e + 1] in Escapable:
      literals.add line[e + 1]
      unescaped.add "\x03" & $(literals.len - 1) & "\x03"
      e += 2
    else:
      unescaped.add line[e]
      e.inc

  let escaped = escape(unescaped)
  var codes: seq[string]
  var protected = newStringOfCap(escaped.len)
  var i = 0
  while i < escaped.len:
    if escaped[i] == '`':
      let stop = escaped.find('`', i + 1)
      if stop > 0:
        codes.add escaped[i + 1 ..< stop]
        protected.add "\0" & $(codes.len - 1) & "\0"
        i = stop + 1
        continue
    protected.add escaped[i]
    i.inc

  # Action purpose: links are lifted after the code-span pass and before the
  # emphasis passes, and that position is the whole design. After, so a link
  # inside a code span stays literal — it has already left the string. Before,
  # because a URL is full of characters the emphasis passes eat, and one
  # underscore pair in a path turns half a sentence bold. The href leaves the
  # string entirely and only the link text stays inline, where emphasis still
  # applies to it.
  #
  # Distinct placeholder bytes from the code pass so the two schemes cannot
  # collide, on that pass's own reasoning.
  var hrefs: seq[string]
  var linked = newStringOfCap(protected.len)
  var j = 0
  while j < protected.len:
    let open = protected.find('[', j)
    if open < 0:
      linked.add protected[j .. ^1]
      break
    let close = protected.find(']', open + 1)
    let shut =
      if close > 0 and close + 1 < protected.len and protected[close + 1] == '(':
        protected.find(')', close + 2)
      else: -1
    if shut < 0:
      # Emit up to and including the bracket and carry on, so a stray `[`
      # cannot swallow the rest of the line.
      linked.add protected[j .. open]
      j = open + 1
      continue

    # Action purpose: an image renders as its alt text linked to the source
    # rather than being fetched. Displaying it would put a network request per
    # image inside a render path, which is a decision to be made deliberately
    # rather than acquired as a side effect.
    let isImage = open > j and protected[open - 1] == '!'
    let cut = if isImage: open - 1 else: open
    if cut > j: linked.add protected[j ..< cut]

    let href = protected[close + 2 ..< shut]
    var text = protected[open + 1 ..< close]
    if text.len == 0: text = href
    if allowedHref(href):
      hrefs.add href
      linked.add "\x01" & $(hrefs.len - 1) & "\x01" & text & "\x02"
    else:
      # Refused by the allowlist, or not a URL at all: the text survives and
      # the destination does not.
      linked.add text
    j = shut + 1

  # Action purpose: inline maths is lifted out like a code span and put back
  # after the emphasis passes, because a formula is dense in the characters
  # those passes eat and one `*` in `$a*b$` would open an italic run across the
  # rest of the line. After the link pass, so a `$` inside a URL has already
  # left the string with its href.
  #
  # A backslash-escaped delimiter never reaches here at all: the escape pass
  # above has already turned `\\(` and `\\[` into a placeholder followed by a
  # bare bracket, which is what keeps chapter 20 of The TeXbook,
  # `Definitions\\(also called macros)`, and the LaTeX line break `\\[4pt]` out
  # of maths. That is the rule a regex would write as a negative lookbehind,
  # obtained from the pass that already exists rather than from a second one.
  var maths: seq[string]
  var withMath = newStringOfCap(linked.len)
  var m = 0
  while m < linked.len:
    # `$$` is display maths, which is a block of its own and a later phase's
    # work, so it is stepped over rather than consumed: a pass that ate the
    # first `$` of a `$$` would leave the second to open a formula running to
    # the end of the line. The other display spelling, `\[`, needs nothing —
    # a bracket is never an opening delimiter here.
    if linked[m] == '$' and m + 1 < linked.len and linked[m + 1] == '$':
      withMath.add "$$"
      m += 2
      continue
    var openLen = 0
    if linked[m] == '$': openLen = 1
    elif linked[m] == '\\' and m + 1 < linked.len and linked[m + 1] == '(':
      openLen = 2
    # An opening delimiter is followed by something that is not a space, which
    # is the rule the emphasis passes already use and the one that keeps
    # `$5 and $10` a pair of prices.
    if openLen == 0 or m + openLen >= linked.len or
       linked[m + openLen] in {' ', '\t'}:
      withMath.add linked[m]
      m.inc
      continue

    var stop = -1
    var k = m + openLen
    while k < linked.len:
      if openLen == 1:
        if linked[k] == '$':
          if not (k + 1 < linked.len and linked[k + 1] == '$') and
             linked[k - 1] notin {' ', '\t'}:
            stop = k
          break
      elif linked[k] == '\\' and k + 1 < linked.len and linked[k + 1] == ')':
        if linked[k - 1] notin {' ', '\t'}: stop = k
        break
      k.inc

    # Action purpose: a formula whose closing delimiter has not arrived is
    # every formula while the reply is still streaming. It renders as its own
    # source and scanning resumes one character in, so the opening delimiter
    # cannot swallow the rest of the line waiting for a partner.
    var markup = ""
    if stop > 0: markup = mathMarkup(linked[m + openLen ..< stop])
    if markup.len == 0:
      withMath.add linked[m]
      m.inc
      continue
    maths.add markup
    withMath.add "\x04" & $(maths.len - 1) & "\x04"
    # Both delimiter pairs are as long closing as opening, which is why one
    # length serves for the skip past either.
    m = stop + openLen

  result = withMath
  # Action purpose: the triple runs go first, and they are not a convenience.
  # Left to the passes below, `***both***` opened bold on the first two stars
  # and italic on the third, then closed bold before italic — `<b><i>x</b></i>`,
  # which Pango rejects outright, so the line drew as nothing. Emitting both
  # tags from one pass is what keeps them nested.
  result = result.inlineWrap("***", "<b><i>", "</i></b>")
  result = result.inlineWrap("___", "<b><i>", "</i></b>")
  result = result.inlineSpan("**", "b")
  result = result.inlineSpan("__", "b")
  # Between the double- and single-asterisk passes: earlier and the double pass
  # would claim the tildes, later and the single pass would.
  result = result.inlineSpan("~~", "s")
  result = result.inlineSpan("*", "i")
  for idx, code in codes:
    result = result.replace("\0" & $idx & "\0", "<tt>" & code & "</tt>")
  for idx, markup in maths:
    result = result.replace("\x04" & $idx & "\x04", markup)
  # `escape` has already dealt with `&`, `<` and `>`; a quote is the one
  # character left that would end the attribute early.
  for idx, href in hrefs:
    result = result.replace("\x01" & $idx & "\x01",
                            "<a href=\"" & href.replace("\"", "&quot;") & "\">")
  result = result.replace("\x02", "</a>")
  for idx, ch in literals:
    result = result.replace("\x03" & $idx & "\x03", escape($ch))

  # Action purpose: the last line of defence, and the reason it is here rather
  # than at the widget. Emphasis delimiters can cross — `*a~~b*c~~` pairs both
  # runs correctly and nests them wrongly — and Pango answers malformed markup
  # by drawing nothing at all. Falling back to the source line escaped costs
  # that line its emphasis; not falling back costs the reader the line.
  if not markupBalanced(result): result = escape(line)

## Function purpose: indentation has to be measured before the line is stripped,
## or a nested item and a top-level one are indistinguishable by the time any
## branch sees them and every list renders flat.
##
## Action purpose: a tab counts as four columns, because that is what the editors
## writing these replies emit. Nothing here can know the reader's tab stop, so
## four is the only answer that agrees with how the text was written.
proc leadingIndent(line: string): tuple[cols, chars: int] =
  var i = 0
  var cols = 0
  while i < line.len:
    if line[i] == ' ': cols.inc
    elif line[i] == '\t': cols += 4
    else: break
    i.inc
  (cols, i)

## Two source columns per nesting level, which is what a model writing markdown
## emits. Capped because a reply is a narrow column and a runaway indent pushes
## text off the edge instead of showing structure.
const MaxListDepth = 6

## Function purpose: converts a measured column count into the leading spaces a
## Pango label needs, since Pango has no list indentation of its own.
proc listIndent(cols: int): string =
  repeat("  ", min(cols div 2, MaxListDepth) + 1)

## Function purpose: a `---` under a paragraph is a setext heading in CommonMark,
## but this renderer is line-based and treats it as a rule — which degrades
## better, since a visible divider beats a heading that silently consumes the
## line above it. A table separator is not caught here: it requires a pipe, and
## the table pass has already run.
proc isHorizontalRule(t: string): bool =
  if t.len < 3: return false
  let c = t[0]
  if c notin {'-', '*', '_'}: return false
  var n = 0
  for ch in t:
    if ch == c: n.inc
    elif ch != ' ': return false
  n >= 3

## Function purpose: the author's own number is kept rather than renumbered.
## CommonMark renumbers a list from its first item, but this renderer draws one
## line at a time with no list to renumber within, and a model that writes `1.`
## three times meant three steps.
proc orderedMarker(t: string): tuple[num: int, rest: string] =
  var i = 0
  while i < t.len and t[i] in {'0' .. '9'}: i.inc
  if i == 0 or i > 9: return (-1, "")
  if i + 1 >= t.len: return (-1, "")
  if t[i] notin {'.', ')'}: return (-1, "")
  if t[i + 1] != ' ': return (-1, "")
  let n = try: parseInt(t[0 ..< i]) except ValueError: return (-1, "")
  (n, t[i + 2 .. ^1])

## Function purpose: one line at a time, because the transcript is drawn while
## it streams and a block-level parser cannot render a half-arrived list.
proc lineMarkup(line: string): string =
  let (cols, _) = leadingIndent(line)
  let t = line.strip(trailing = false)
  let pad = listIndent(cols)
  # Action purpose: task lists are checked before the plain bullet, because
  # every task item is also a bullet and that branch would swallow it and render
  # the raw brackets. The box is a character rather than a widget: this is one
  # line of a Pango label, and the checkbox is not interactive anywhere.
  if t.startsWith("- [ ] ") or t.startsWith("* [ ] ") or t.startsWith("+ [ ] "):
    pad & "☐ " & inlineMarkup(t[6 .. ^1])
  elif t.startsWith("- [x] ") or t.startsWith("* [x] ") or
       t.startsWith("+ [x] ") or
       t.startsWith("- [X] ") or t.startsWith("* [X] ") or
       t.startsWith("+ [X] "):
    pad & "☑ " & inlineMarkup(t[6 .. ^1])
  # A rule is tested before the bullet branch: `***` and `---` are both, and
  # the bullet branch would render the remainder as a bullet's text.
  elif isHorizontalRule(t):
    # Action purpose: Pango has no rule, so one is drawn. A fixed run rather
    # than a measured one, because the column's width is not known here and a
    # run that guesses too wide forces a horizontal scrollbar.
    "─".repeat(24)
  # Deepest first: `###` must be tested before `##`, or the shorter prefix
  # matches and the third character renders as text.
  elif t.startsWith("###### "): "<b>" & inlineMarkup(t[7 .. ^1]) & "</b>"
  elif t.startsWith("##### "): "<b>" & inlineMarkup(t[6 .. ^1]) & "</b>"
  elif t.startsWith("#### "): "<b>" & inlineMarkup(t[5 .. ^1]) & "</b>"
  elif t.startsWith("### "): "<b>" & inlineMarkup(t[4 .. ^1]) & "</b>"
  elif t.startsWith("## "): "<big><b>" & inlineMarkup(t[3 .. ^1]) & "</b></big>"
  elif t.startsWith("# "): "<big><b>" & inlineMarkup(t[2 .. ^1]) & "</b></big>"
  elif t.startsWith("- ") or t.startsWith("* ") or t.startsWith("+ "):
    pad & "• " & inlineMarkup(t[2 .. ^1])
  elif t.startsWith("> "): "<i>" & inlineMarkup(t[2 .. ^1]) & "</i>"
  else:
    # Tested last among the structural branches: it is the only one that is not
    # a prefix comparison, and every non-list line has to fail it.
    let (num, rest) = orderedMarker(t)
    if num >= 0: pad & $num & ". " & inlineMarkup(rest)
    else: inlineMarkup(line)

## Function purpose: the outer pipes are optional in the input, so they are
## dropped here and `| a | b |` and `a | b` give the same two cells.
proc tableCells(line: string): seq[string] =
  var t = line.strip
  if t.startsWith("|"): t = t[1 .. ^1]
  if t.endsWith("|"): t = t[0 ..< ^1]
  for cell in t.split('|'): result.add cell.strip

## Function purpose: the separator line is the only thing distinguishing a table
## from a paragraph that happens to contain a pipe, which is why it is required
## rather than inferred.
proc isTableSeparator(line: string): bool =
  let cells = tableCells(line)
  if cells.len == 0 or not line.contains('|'): return false
  for cell in cells:
    if cell.len == 0: return false
    for ch in cell:
      if ch notin {'-', ':', ' '}: return false
    if not cell.contains('-'): return false
  true

## Function purpose: converts the colon markers to an `xAlign` here, so the
## widget layer applies alignment without re-reading the separator row.
proc alignOf(cell: string): float =
  let c = cell.strip
  let left = c.startsWith(":")
  let right = c.endsWith(":")
  if left and right: 0.5
  elif right: 1.0
  else: 0.0

## Function purpose: an unterminated fence — which is every code block while it
## is still streaming — is emitted as code rather than held back, so a block
## appears as it is generated instead of arriving whole at the closing fence.
proc parse*(content: string): seq[Block] =
  var
    blocks: seq[Block] = @[]
    cur: seq[string] = @[]
    inCode = false
    lang = ""

  proc flush(kind: BlockKind, l = "", complete = true) =
    if cur.len > 0:
      let body = cur.join("\n").strip(leading = false)
      if body.len > 0:
        blocks.add Block(kind: kind, text: body, lang: l, complete: complete)
      cur.setLen(0)

  for line in content.splitLines():
    if line.strip.startsWith("```"):
      if inCode:
        flush(bkCode, lang)
        inCode = false
        lang = ""
      else:
        flush(bkText)
        inCode = true
        lang = line.strip.strip(chars = {'`'}).strip
      continue
    cur.add line

  # Only the trailing block can be unfinished, and it is unfinished exactly when
  # the fence that opened it never closed.
  flush(if inCode: bkCode else: bkText, lang, not inCode)

  # Action purpose: tables are lifted out here rather than inside the fence loop
  # above, so the streaming behaviour of a fence is untouched and a pipe inside
  # a code block is never seen — those blocks are already separate by now.
  #
  # A local rather than writing into `result`, because the closure below would
  # capture `result`, which Nim refuses as a memory-safety violation.
  var outp: seq[Block] = @[]
  for b in blocks:
    if b.kind != bkText:
      outp.add b
      continue
    let lines = b.text.splitLines()
    var pending: seq[string] = @[]

    proc flushText() =
      if pending.len > 0:
        var marked: seq[string] = @[]
        for l in pending: marked.add lineMarkup(l)
        outp.add Block(kind: bkText, text: marked.join("\n"), complete: true)
        pending.setLen(0)

    var i = 0
    while i < lines.len:
      # A header row, a separator row, then rows until something that is not
      # one. The separator is what makes it a table at all.
      if i + 1 < lines.len and lines[i].contains('|') and
         isTableSeparator(lines[i + 1]):
        flushText()
        var tbl = Block(kind: bkTable, complete: true)
        let header = tableCells(lines[i])
        var marked: seq[string] = @[]
        for cell in header: marked.add inlineMarkup(cell)
        tbl.rows.add marked
        for cell in tableCells(lines[i + 1]): tbl.aligns.add alignOf(cell)
        i += 2
        while i < lines.len and lines[i].contains('|'):
          var row: seq[string] = @[]
          for cell in tableCells(lines[i]): row.add inlineMarkup(cell)
          # Padded rather than dropped: a model miscounting its own pipes
          # should cost an empty cell, not the whole table.
          while row.len < tbl.rows[0].len: row.add ""
          tbl.rows.add row
          i.inc
        outp.add tbl
        continue
      pending.add lines[i]
      i.inc
    flushText()
  result = outp

type
  BlockMemo* = object
    ## `parse` is called from `view`, so without this it runs on every frame,
    ## once per message on the branch, over that message's whole text — a cost a
    ## long conversation pays on every token of every reply.
    ##
    ## `parses` exists to be asserted: a per-frame cost that comes back is
    ## invisible to a compile, a self-test and a screenshot alike, right up until
    ## the window stops responding.
    blocks: Table[string, seq[Block]]
    stamps: Table[string, int]
    ## Insertion order, so the oldest can be dropped when the memo is over its
    ## cap. Only a new id is appended — a re-parse under an existing id replaces
    ## the entry without moving it, so one message cannot occupy two slots.
    order: seq[string]
    parses*: int

const BlockMemoCap* = 512
  ## A ceiling on growth, not a working-set size. Far more than the one branch
  ## of one conversation the transcript ever draws, so the cap never engages
  ## during normal reading and the per-frame guarantee below is untouched — it
  ## exists only so a process that renders for hours cannot hold every message
  ## it ever showed.

## Function purpose: evicts in batches rather than one entry per insert.
## Dropping a single oldest id shifts the whole sequence, an O(n) cost on every
## insert once the cap is reached — paid on the one path whose entire reason for
## existing is that `view` does no work proportional to anything. A quarter at a
## time amortises that to O(1).
##
## An id already removed by `invalidate` is simply absent, and deleting a
## missing key is a no-op, so the queue needs no tombstones.
proc evict(memo: var BlockMemo) =
  if memo.order.len <= BlockMemoCap: return
  let drop = max(1, BlockMemoCap div 4)
  for i in 0 ..< drop:
    memo.blocks.del(memo.order[i])
    memo.stamps.del(memo.order[i])
  memo.order = memo.order[drop .. ^1]

## Function purpose: a message with no id is never memoised. An assistant turn
## is a live buffer while it streams and only becomes a row when it finishes, so
## caching it would freeze the transcript on its first token.
##
## Action purpose: the stamp is the text length, which catches the one way a
## saved message still changes — an append always changes it.
proc blocksFor*(memo: var BlockMemo, id, text: string): seq[Block] =
  if id.len == 0:
    inc memo.parses
    return parse(text)
  if memo.stamps.getOrDefault(id, -1) == text.len and memo.blocks.hasKey(id):
    return memo.blocks[id]
  inc memo.parses
  result = parse(text)
  if not memo.blocks.hasKey(id):
    memo.order.add id
    memo.evict()
  memo.blocks[id] = result
  memo.stamps[id] = text.len

## Function purpose: for a surface whose text changes under a key that does not.
## The length stamp is sound for a message — an edit becomes a new row with a
## new id, and Continue only appends — but a note keeps its id across every
## edit, so correcting a transposition leaves the stamp equal and the view
## renders the pre-edit text indefinitely, which reads as a save that failed.
##
## Action purpose: hashing the text would fix it and is forbidden, because this
## is reached from `view` and nothing there may do work proportional to a
## payload. So invalidation is explicit and O(1), called where the text is
## re-baselined.
proc invalidate*(memo: var BlockMemo, id: string) =
  memo.blocks.del(id)
  memo.stamps.del(id)
  # Action purpose: the queue entry goes too, because `blocksFor` appends an id
  # only when `blocks` does not already hold it. Leaving the entry behind means
  # the next render of the same note appends a second one, and a note edited
  # repeatedly fills the queue with copies of itself — `evict` then drops live
  # entries while `blocks` sits well under the cap. The search is O(n) and that
  # is affordable here and nowhere near `view`: this is called where the text is
  # re-baselined, not per frame.
  let at = memo.order.find(id)
  if at >= 0: memo.order.delete(at)

## Function purpose: the transcript draws one branch of one conversation, so
## switching conversation makes every entry here dead at once — cheaper to empty
## than to let the cap evict them one insert at a time.
proc clear*(memo: var BlockMemo) =
  memo.blocks.clear()
  memo.stamps.clear()
  memo.order.setLen(0)

## Function purpose: exported for the assertion, so a cap that stops working is
## a failing test rather than a slow leak.
proc len*(memo: BlockMemo): int = memo.blocks.len
