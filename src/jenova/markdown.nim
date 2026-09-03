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

## Function purpose: runs before every other pass, because Pango markup and
## the source text share these three characters.
proc escape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

## Function purpose: an unpaired delimiter is left as literal text, because a
## reply is read while it streams and a half-typed run must not swallow the rest
## of the line.
proc inlineSpan(s: string, delim: string, tag: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let start = s.find(delim, i)
    if start < 0:
      result.add s[i .. ^1]
      break
    let stop = s.find(delim, start + delim.len)
    if stop < 0:
      result.add s[i .. ^1]
      break
    result.add s[i ..< start]
    result.add "<" & tag & ">" & s[start + delim.len ..< stop] & "</" & tag & ">"
    i = stop + delim.len

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
  let escaped = escape(line)
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

  result = linked
  result = result.inlineSpan("**", "b")
  result = result.inlineSpan("__", "b")
  # Between the double- and single-asterisk passes: earlier and the double pass
  # would claim the tildes, later and the single pass would.
  result = result.inlineSpan("~~", "s")
  result = result.inlineSpan("*", "i")
  for idx, code in codes:
    result = result.replace("\0" & $idx & "\0", "<tt>" & code & "</tt>")
  # `escape` has already dealt with `&`, `<` and `>`; a quote is the one
  # character left that would end the attribute early.
  for idx, href in hrefs:
    result = result.replace("\x01" & $idx & "\x01",
                            "<a href=\"" & href.replace("\"", "&quot;") & "\">")
  result = result.replace("\x02", "</a>")

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

  proc flush(kind: BlockKind, l = "") =
    if cur.len > 0:
      let body = cur.join("\n").strip(leading = false)
      if body.len > 0:
        blocks.add Block(kind: kind, text: body, lang: l)
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

  flush(if inCode: bkCode else: bkText, lang)

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
        outp.add Block(kind: bkText, text: marked.join("\n"))
        pending.setLen(0)

    var i = 0
    while i < lines.len:
      # A header row, a separator row, then rows until something that is not
      # one. The separator is what makes it a table at all.
      if i + 1 < lines.len and lines[i].contains('|') and
         isTableSeparator(lines[i + 1]):
        flushText()
        var tbl = Block(kind: bkTable)
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
