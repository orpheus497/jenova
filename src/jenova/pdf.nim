## Script function and purpose: pull the readable text out of a PDF so an
## attached document reaches the model as text (G-30, Step 7b). Below the widget
## layer and importing only `std` and `zlib`, so `attach-selftest` asserts it
## with no window and no attachment.
##
## **It is a text extractor, not a renderer.** It reads content streams and the
## four text-showing operators. Layout, columns, tables and reading order are not
## reconstructed, and a page that is a scanned image carries no text objects at
## all — `textFrom` returns empty for it, and the caller refuses the attachment
## rather than sending an empty document that reads as a working one.
##
## **The known limit, stated rather than discovered:** a font using Identity-H
## encodes glyph indices rather than characters, so its strings come back as
## bytes that are not text. `looksReadable` is what catches that — the result is
## rejected instead of attaching mojibake the model would answer questions about.

import std/strutils
import ./zlib

## Function purpose: read a `(…)` literal string body, which is where a PDF puts
## most of its text. `i` enters just past the opening paren and leaves just past
## the closing one.
##
## Action purpose: parens nest and are escaped, so a naive scan to the first `)`
## truncates any string containing one. The octal form `\ddd` is the other case
## that matters — accented characters are written that way.
proc readLiteral*(s: string, i: var int): string =
  var depth = 1
  while i < s.len:
    let c = s[i]
    if c == '\\':
      inc i
      if i >= s.len: break
      case s[i]
      of 'n': result.add '\n'; inc i
      of 'r': result.add '\r'; inc i
      of 't': result.add '\t'; inc i
      of 'b': result.add '\b'; inc i
      of 'f': result.add '\f'; inc i
      of '(': result.add '('; inc i
      of ')': result.add ')'; inc i
      of '\\': result.add '\\'; inc i
      of '0' .. '7':
        var oct = 0
        var n = 0
        while n < 3 and i < s.len and s[i] in {'0' .. '7'}:
          oct = oct * 8 + (ord(s[i]) - ord('0'))
          inc i
          inc n
        result.add chr(oct and 0xFF)
      of '\n': inc i
      of '\r':
        inc i
        if i < s.len and s[i] == '\n': inc i
      else:
        result.add s[i]
        inc i
    elif c == '(':
      inc depth
      result.add c
      inc i
    elif c == ')':
      dec depth
      inc i
      if depth == 0: return
      result.add c
    else:
      result.add c
      inc i

## Function purpose: read a `<…>` hex string. `i` enters just past `<`.
proc readHex*(s: string, i: var int): string =
  var digits = ""
  while i < s.len and s[i] != '>':
    if s[i] in HexDigits: digits.add s[i]
    inc i
  if i < s.len: inc i
  var k = 0
  while k + 1 < digits.len:
    try:
      result.add chr(parseHexInt(digits[k .. k + 1]))
    except ValueError:
      discard
    k += 2

## Function purpose: the text a single decoded content stream shows, in the order
## its operators show it.
##
## Action purpose: strings are collected as they are read and flushed by the
## operator that displays them — `Tj` and `TJ` show, `'` and `"` show on a new
## line, and the positioning operators end a line. Collecting first is what makes
## `TJ` work at all: `[(Hel) -250 (lo)] TJ` is one word split by kerning, and
## flushing per string would put a space inside it.
proc textOf*(content: string): string =
  var i = 0
  var pending: seq[string] = @[]
  while i < content.len:
    let c = content[i]
    case c
    of '(':
      inc i
      pending.add readLiteral(content, i)
    of '<':
      # `<<` opens a dictionary; only a single `<` is a hex string.
      if i + 1 < content.len and content[i + 1] == '<':
        i += 2
      else:
        inc i
        pending.add readHex(content, i)
    of 'T':
      if i + 1 >= content.len:
        inc i
      else:
        case content[i + 1]
        of 'j', 'J':
          for s in pending: result.add s
          pending.setLen 0
          i += 2
        of '*', 'd', 'D':
          if result.len > 0 and result[^1] != '\n': result.add '\n'
          pending.setLen 0
          i += 2
        else: inc i
    of '\'', '"':
      if result.len > 0 and result[^1] != '\n': result.add '\n'
      for s in pending: result.add s
      pending.setLen 0
      inc i
    of 'E':
      if i + 1 < content.len and content[i + 1] == 'T':
        if result.len > 0 and result[^1] != '\n': result.add '\n'
        pending.setLen 0
        i += 2
      else: inc i
    else: inc i

## Function purpose: is this extraction actually text, or glyph indices from a
## font this reader cannot map? Attaching the second would give the model a page
## of noise to answer questions about, which is worse than refusing.
proc looksReadable*(s: string): bool =
  if s.len == 0: return false
  var printable = 0
  for ch in s:
    if ch in {' ' .. '~'} or ch in {'\n', '\r', '\t'}: inc printable
  printable * 10 >= s.len * 8

## Function purpose: every content stream in the file, decompressed where it is
## FlateDecode and taken verbatim where it is not.
##
## Action purpose: the dictionary immediately before a `stream` keyword is what
## says whether it is compressed, so it is read backwards from the keyword rather
## than by resolving object references — this reader never has to build an xref
## table, which is the half of a PDF parser that is genuinely hard.
proc streamsOf*(data: string): seq[string] =
  var i = 0
  while true:
    let s = data.find("stream", i)
    if s < 0: break
    # `endstream` contains `stream`; stepping over it here is what stops the
    # scan finding the same block twice.
    if s >= 3 and data[s - 3 .. s - 1] == "end":
      i = s + 6
      continue
    var body = s + 6
    if body < data.len and data[body] == '\r': inc body
    if body < data.len and data[body] == '\n': inc body
    let e = data.find("endstream", body)
    if e < 0: break
    let raw = if e > body: data[body ..< e] else: ""
    let dictStart = data.rfind("<<", 0, s)
    let dict = if dictStart >= 0: data[dictStart ..< s] else: ""
    if raw.len > 0:
      if dict.contains("FlateDecode"):
        let r = zlib.inflate(raw)
        if r.ok: result.add r.data
      else:
        result.add raw
    i = e + 9

## Function purpose: the text of a PDF, or empty when it has none that can be
## read. Empty is the answer for a scanned document, for an encrypted one, and
## for a font this reader cannot decode — the caller refuses on all three rather
## than attaching a blank.
proc textFrom*(data: string): string =
  if not data.startsWith("%PDF"): return ""
  var text = ""
  for content in streamsOf(data):
    let t = textOf(content)
    if t.len > 0 and looksReadable(t):
      text.add t
      if text[^1] != '\n': text.add '\n'
  text.strip
