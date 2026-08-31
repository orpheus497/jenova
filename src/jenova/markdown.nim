## Script function and purpose: split an assistant message into renderable blocks
## and turn inline markdown into Pango markup, so the transcript reads like the
## Web UI's `MarkdownContent` rather than one flat string.

import std/strutils

type
  BlockKind* = enum bkText, bkCode
  Block* = object
    kind*: BlockKind
    text*: string
    lang*: string

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

proc inlineMarkup*(line: string): string =
  result = escape(line)
  result = result.inlineSpan("`", "tt")
  result = result.inlineSpan("**", "b")
  result = result.inlineSpan("__", "b")
  result = result.inlineSpan("*", "i")

proc lineMarkup(line: string): string =
  let t = line.strip(trailing = false)
  if t.startsWith("### "): "<b>" & inlineMarkup(t[4 .. ^1]) & "</b>"
  elif t.startsWith("## "): "<big><b>" & inlineMarkup(t[3 .. ^1]) & "</b></big>"
  elif t.startsWith("# "): "<big><b>" & inlineMarkup(t[2 .. ^1]) & "</b></big>"
  elif t.startsWith("- ") or t.startsWith("* "): "  • " & inlineMarkup(t[2 .. ^1])
  elif t.startsWith("> "): "<i>" & inlineMarkup(t[2 .. ^1]) & "</i>"
  else: inlineMarkup(line)

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
  result = blocks

  for b in result.mitems:
    if b.kind == bkText:
      var lines: seq[string] = @[]
      for l in b.text.splitLines():
        lines.add lineMarkup(l)
      b.text = lines.join("\n")
