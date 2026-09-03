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
    ## G-34. A table is rows of already-marked-up cells rather than one string,
    ## because Pango has no table: it has to become a real `Grid` of `Label`s in
    ## the widget layer. Row 0 is the header. `aligns` is one `xAlign` per
    ## column, taken from the `:---:` markers, so the widget layer applies it
    ## without re-parsing anything.
    rows*: seq[seq[string]]
    aligns*: seq[float]

proc escape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

proc inlineSpan(s: string, delim: string, tag: string): string =
  ## Wrap paired `delim` runs in `<tag>`. An unpaired delimiter is left as text.
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

## Function purpose: may this destination be handed to the desktop, as an
## allowlist rather than a denylist (A-48).
##
## **This is the security boundary of the whole link feature.** GTK gives an
## activated `<a href>` to the desktop URI handler, so a model that writes
## `[click](file:///etc/passwd)` — or `javascript:`, or a `data:` URL — would
## otherwise have handed the desktop an instruction. Only `http`/`https` become
## anchors; everything else renders as its own text with no destination, which
## is visible rather than silent. An allowlist is used because the set of
## schemes a desktop will act on is open-ended and a denylist cannot be
## completed.
proc allowedHref(href: string): bool =
  let lower = href.toLowerAscii
  for s in LinkSchemes:
    if href.len > s.len and lower.startsWith(s): return true
  false

## Code spans are lifted out before the emphasis passes run and put back after.
## Marking them up first left their contents in the string, so `*` and `_` inside
## a code span were still read as emphasis — `` `a*b*c` `` came out as
## `<tt>a<i>b</i>c</tt>`, which is the one thing a code span is supposed to
## prevent. The NUL-delimited placeholder cannot occur in the escaped text and
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

  # A-48. Links are lifted here — after the code-span pass and before the
  # emphasis passes — and the position is the whole design.
  #
  # After, because `` `[a](b)` `` must stay literal: the code span has already
  # left the string, so this scanner never sees it. Before, because a URL is
  # full of characters the emphasis passes eat — `https://host/a_b_c` is one
  # `__` pair away from turning half a sentence bold. So the href leaves the
  # string entirely and only the link TEXT stays inline, where emphasis still
  # applies to it, which is what `[**bold**](url)` should do.
  #
  # `\x01`/`\x02` rather than the code pass's `\x00` so the two placeholder
  # schemes cannot collide, on that pass's own reasoning: a control character
  # cannot occur in the escaped text.
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
      # Not a link. Emit up to and including the bracket and carry on, so a
      # stray `[` cannot swallow the rest of the line.
      linked.add protected[j .. open]
      j = open + 1
      continue

    # `![alt](url)`. **The image is rendered as its alt text linked to the
    # source, not fetched.** Displaying it would mean a network request per
    # image from inside a render path, which is B-01's leak and Step 7c's rule
    # at once; that is a decision for the USER, not a side effect of this fix.
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
      # Refused by the allowlist, or not a URL at all. The text survives and the
      # destination does not — a visible loss rather than a link that quietly
      # does something else when clicked.
      linked.add text
    j = shut + 1

  result = linked
  result = result.inlineSpan("**", "b")
  result = result.inlineSpan("__", "b")
  # Before the single `*` pass, or the first two tildes would already be gone —
  # and after the double-asterisk passes, for the same reason (G-34).
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

## Function purpose: how deeply a line is indented, in columns, and how many
## characters that took.
##
## Action purpose: **`lineMarkup` measured nothing and stripped everything.** It
## opened with `line.strip(trailing = false)`, so `  - nested` and `- top` were
## indistinguishable by the time any branch saw them and every list in every
## reply rendered flat — a three-level outline came out as three identical
## bullets. The depth has to be taken before the strip, which is the whole of
## why this exists.
##
## A tab counts as four columns because that is what the editors writing these
## replies emit; nothing here can know the reader's tab stop, and four is the
## only answer that agrees with how the text was written.
proc leadingIndent(line: string): tuple[cols, chars: int] =
  var i = 0
  var cols = 0
  while i < line.len:
    if line[i] == ' ': cols.inc
    elif line[i] == '\t': cols += 4
    else: break
    i.inc
  (cols, i)

## Two columns of source indentation is one level of nesting, which is what a
## model writing markdown emits and what CommonMark's own examples use. Capped
## because a reply is a narrow column and a runaway indent would push the text
## off the edge rather than communicate structure.
const MaxListDepth = 6

proc listIndent(cols: int): string =
  repeat("  ", min(cols div 2, MaxListDepth) + 1)

## Function purpose: is this line a horizontal rule — three or more `-`, `*` or
## `_`, and nothing else but spaces?
##
## A table separator is *not* caught by this: `isTableSeparator` requires a
## pipe, and the table pass runs before this one. A `---` under a paragraph is
## a setext heading in CommonMark rather than a rule; this renderer is
## line-based and treats it as a rule, which is the reading that degrades
## better — a visible divider rather than a heading that silently eats the line
## above it.
proc isHorizontalRule(t: string): bool =
  if t.len < 3: return false
  let c = t[0]
  if c notin {'-', '*', '_'}: return false
  var n = 0
  for ch in t:
    if ch == c: n.inc
    elif ch != ' ': return false
  n >= 3

## Function purpose: split an ordered-list marker off the front of a line —
## `1. `, `2) `, `10. `. Returns the number as written and the rest, or a
## negative number when the line is not one.
##
## **The author's own number is kept rather than renumbered.** CommonMark says a
## list renumbers from its first item, but this renderer draws one line at a
## time with no list context to renumber within, and a model that writes `1.`
## three times meant three steps. Showing what was written is the honest
## rendering and cannot invent an order the author did not.
proc orderedMarker(t: string): tuple[num: int, rest: string] =
  var i = 0
  while i < t.len and t[i] in {'0' .. '9'}: i.inc
  if i == 0 or i > 9: return (-1, "")
  if i + 1 >= t.len: return (-1, "")
  if t[i] notin {'.', ')'}: return (-1, "")
  if t[i + 1] != ' ': return (-1, "")
  let n = try: parseInt(t[0 ..< i]) except ValueError: return (-1, "")
  (n, t[i + 2 .. ^1])

proc lineMarkup(line: string): string =
  let (cols, _) = leadingIndent(line)
  let t = line.strip(trailing = false)
  let pad = listIndent(cols)
  # G-34: task lists are checked before the plain bullet, because every task
  # item is also a bullet and the bullet branch would swallow it and render the
  # raw brackets. The box is a character rather than a widget: this is one line
  # of a Pango label, and the Web UI's checkbox is not interactive either.
  if t.startsWith("- [ ] ") or t.startsWith("* [ ] ") or t.startsWith("+ [ ] "):
    pad & "☐ " & inlineMarkup(t[6 .. ^1])
  elif t.startsWith("- [x] ") or t.startsWith("* [x] ") or
       t.startsWith("+ [x] ") or
       t.startsWith("- [X] ") or t.startsWith("* [X] ") or
       t.startsWith("+ [X] "):
    pad & "☑ " & inlineMarkup(t[6 .. ^1])
  # A rule is tested before the bullet branch: `***` and `---` are both a rule
  # and a possible list marker, and the bullet branch would render `--` as the
  # text of a bullet.
  elif isHorizontalRule(t):
    # Pango has no rule, so it is drawn. A fixed run rather than a measured one:
    # this is one line of a label inside a scrolling column whose width is not
    # known here, and a run that guesses too wide forces a horizontal scrollbar
    # on every reply that contains one.
    "─".repeat(24)
  # Headings, deepest first: `###` must be tested before `##`, or `##` matches
  # its first two characters and the third renders as text.
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
    # An ordered item. Tested last among the structural branches because the
    # scan is the only one that is not a prefix comparison, and every line that
    # is not a list has to fail it.
    let (num, rest) = orderedMarker(t)
    if num >= 0: pad & $num & ". " & inlineMarkup(rest)
    else: inlineMarkup(line)

## Function purpose: split a `|`-delimited row into its cells, dropping the
## optional leading and trailing pipes so `| a | b |` and `a | b` give the same
## two cells.
proc tableCells(line: string): seq[string] =
  var t = line.strip
  if t.startsWith("|"): t = t[1 .. ^1]
  if t.endsWith("|"): t = t[0 ..< ^1]
  for cell in t.split('|'): result.add cell.strip

## Function purpose: is this the `|---|:--:|` line that turns the row above it
## into a table header? That line is the only thing distinguishing a table from
## a paragraph that happens to contain a pipe, which is why it is required.
proc isTableSeparator(line: string): bool =
  let cells = tableCells(line)
  if cells.len == 0 or not line.contains('|'): return false
  for cell in cells:
    if cell.len == 0: return false
    for ch in cell:
      if ch notin {'-', ':', ' '}: return false
    if not cell.contains('-'): return false
  true

## `:---` left, `---:` right, `:---:` centre — as an `xAlign` the widget layer
## can apply directly.
proc alignOf(cell: string): float =
  let c = cell.strip
  let left = c.startsWith(":")
  let right = c.endsWith(":")
  if left and right: 0.5
  elif right: 1.0
  else: 0.0

## Split on fenced code blocks. An unterminated fence — which is every code block
## mid-stream — is emitted as code rather than held back, so a block appears as
## it is generated instead of arriving all at once when the closing fence lands.
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

  # G-34: tables are lifted out of the text blocks here rather than inside the
  # fence loop above, so the fence handling — which is what makes a block appear
  # while it is still streaming — is untouched. A `|` inside a code block is
  # never seen by this, because code blocks are already separate by now.
  # `outp` rather than writing straight into `result`, because the closure below
  # would be capturing `result` — which Nim refuses as a memory-safety
  # violation, and rightly: it is the caller's buffer.
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
      # A table is a header row, a separator row, then rows until something
      # that is not a row. The separator is what makes it a table at all.
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
          # A short row is padded rather than dropped: a model miscounting its
          # own pipes should cost an empty cell, not the whole table.
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
    ## G-40. **`parse` is called from `view`, so it runs on every frame** — once
    ## per message on the branch, over that message's whole text. It was not the
    ## cause of the attachment freeze but it is the same defect and the same
    ## budget, and a long conversation paid it on every token of every reply.
    ##
    ## `parses` exists to be asserted, for the reason `pipeline.ParseMemo`'s
    ## does: a per-frame cost that comes back is invisible to a compile, to a
    ## self-test and to a screenshot, right up until the window stops responding.
    blocks: Table[string, seq[Block]]
    stamps: Table[string, int]
    ## M-01. Insertion order of the ids currently held, so the oldest can be
    ## dropped when the memo is over its cap. **Only a *new* id is appended** —
    ## a re-parse under an existing id (Continue extending a reply) replaces the
    ## entry without moving it, so one message cannot occupy two slots.
    order: seq[string]
    parses*: int

const BlockMemoCap* = 512
  ## M-01. How many messages' parsed blocks the memo may hold.
  ##
  ## **This memo was unbounded and was never cleared.** It is a module-level
  ## `var` in `gui.nim` keyed by message id, and neither `loadConversation` nor
  ## `selectConversation` nor `deleteMessage` touched it — so every message ever
  ## rendered kept its parsed block list for the life of the process, including
  ## the blocks of conversations closed hours ago and of messages since deleted.
  ##
  ## 512 is far more than one branch of one conversation, which is all the
  ## transcript ever draws, so the cap never engages during normal reading and
  ## the per-frame guarantee `blocksFor` exists to provide is untouched. It is a
  ## ceiling on a leak, not a working-set size.

## Function purpose: drop the oldest entries once the memo is over its cap.
##
## Action purpose: **a batch, not one entry per insert.** Removing a single
## oldest id means `order.delete(0)`, which shifts the whole sequence — an O(n)
## cost on every insert once the cap is reached, paid on a path whose entire
## reason for existing is that `view` must do no work proportional to anything
## (G-40). Dropping a quarter at a time amortises that shift to O(1) per insert.
##
## An id already removed by `invalidate` is simply absent from the tables;
## `Table.del` on a missing key is a no-op, so the queue needs no tombstones.
proc evict(memo: var BlockMemo) =
  if memo.order.len <= BlockMemoCap: return
  let drop = max(1, BlockMemoCap div 4)
  for i in 0 ..< drop:
    memo.blocks.del(memo.order[i])
    memo.stamps.del(memo.order[i])
  memo.order = memo.order[drop .. ^1]

## Function purpose: the blocks of one message, parsed at most once.
##
## **A message with no id is never memoised.** An assistant turn is a live buffer
## while it streams and only becomes a row when it finishes, so caching it would
## freeze the transcript on its first token. The stamp is the text length, which
## catches the one way a saved message still changes — Continue extends it, and
## an append always changes the length.
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

## Function purpose: forget one id, for a surface whose text changes under a key
## that does not (A-26).
##
## The length stamp above is sound for a message and unsound for a note. A
## message edit is saved as a *new row with a new id* and Continue only ever
## appends, so length catches every change a message can undergo. **A note keeps
## its id across every edit**, so correcting a transposition or swapping a word
## for one the same length leaves the stamp equal and the view renders the
## pre-edit text — indefinitely, which reads as a save that did not happen.
##
## Hashing the text instead would fix it and is forbidden: `blocksFor` is called
## from `view`, and nothing there may do work proportional to a payload (G-40,
## Step 7c). So the invalidation is explicit and O(1), and the note editor calls
## it at the two points it re-baselines.
proc invalidate*(memo: var BlockMemo, id: string) =
  memo.blocks.del(id)
  memo.stamps.del(id)

## Function purpose: drop everything (M-01). The transcript draws one branch of
## one conversation, so switching conversation makes every entry here dead —
## and nothing dropped them, which is the leak `BlockMemoCap` caps and this
## empties outright.
proc clear*(memo: var BlockMemo) =
  memo.blocks.clear()
  memo.stamps.clear()
  memo.order.setLen(0)

## Function purpose: how many entries are held. For the assertion, so a cap that
## stops working is a failing test rather than a slow leak.
proc len*(memo: BlockMemo): int = memo.blocks.len
