## Script function and purpose: the readable text of a PDF, so an attached
## document reaches the model as text. Below the widget layer and importing only
## `std` and `zlib`, so the self-test asserts it with no window.
##
## A text extractor and not a renderer: content streams and the text-showing
## operators only, with no reconstruction of layout, columns or reading order.
## Two inputs yield nothing on purpose — a scanned page carries no text objects,
## and an Identity-H font encodes glyph indices rather than characters. Both are
## refused whole rather than attached as noise the model would answer about.

import std/strutils
import ./zlib

## Function purpose: where a PDF puts most of its text. `i` enters just past the
## opening paren and leaves just past the closing one.
##
## Action purpose: parens nest and can be escaped, so a scan to the first `)`
## truncates any string containing one. The octal form is the other case that
## matters, because accented characters are written that way.
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

## Function purpose: the other string form. `i` enters just past `<`; an odd
## trailing digit is dropped rather than half-decoded.
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

## Function purpose: the text one decoded content stream shows, in the order its
## operators show it.
##
## Action purpose: strings are collected as read and flushed by the operator that
## displays them. Collecting first is what makes `TJ` work: `[(Hel) -250 (lo)]`
## is one word split by kerning, and flushing per string puts a space inside it.
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
      # `<<` opens a dictionary; only a lone `<` begins a hex string.
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

## Function purpose: separates real text from glyph indices of a font this
## reader cannot map. Attaching the latter gives the model a page of noise to
## answer questions about, which is worse than refusing the document.
proc looksReadable*(s: string): bool =
  if s.len == 0: return false
  var printable = 0
  for ch in s:
    if ch in {' ' .. '~'} or ch in {'\n', '\r', '\t'}: inc printable
  printable * 10 >= s.len * 8

## Function purpose: every content stream, decompressed where it is FlateDecode
## and verbatim where it is not. The undecodable count is returned rather than
## logged, because the caller is the one that has to refuse the document.
##
## Action purpose: the dictionary immediately before a `stream` keyword says
## whether it is compressed, so it is read backwards from the keyword instead of
## by resolving object references. That is what lets this reader skip building an
## xref table, which is the genuinely hard half of a PDF parser.
proc streamsOf*(data: string): tuple[streams: seq[string], undecodable: int] =
  var i = 0
  while true:
    let s = data.find("stream", i)
    if s < 0: break
    # `endstream` contains `stream`, so stepping over it is what stops the scan
    # finding the same block twice.
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
        # Action purpose: a stream that will not inflate is content this reader
        # cannot see, so it is counted rather than dropped — `textFrom` refuses
        # the document instead of returning the part it happened to manage.
        if r.ok: result.streams.add r.data
        else: inc result.undecodable
      else:
        result.streams.add raw
    i = e + 9

## Function purpose: empty is the answer for a scanned document, an encrypted
## one, and a font this reader cannot decode. The caller refuses on all three
## rather than attaching a blank.
proc textFrom*(data: string): string =
  if not data.startsWith("%PDF"): return ""
  let (streams, undecodable) = streamsOf(data)
  # Action purpose: all-or-nothing. A document only partly decompressible is
  # refused whole rather than attached as the fraction that inflated — a
  # fragment reads as a working document while saying something the user never
  # wrote, and the model then answers confidently about it.
  if undecodable > 0: return ""

  var text = ""
  for content in streams:
    let t = textOf(content)
    # Action purpose: a stream with no text is not a failure. `streamsOf`
    # returns every stream, and embedded fonts, image data and pure graphics
    # legitimately yield nothing; refusing on them rejects almost every real PDF.
    if t.len == 0: continue
    # Action purpose: text came out and is not readable, which means an encoding
    # this reader cannot handle. That is content lost, so the document is refused
    # rather than contributing the readable remainder around it.
    if not looksReadable(t): return ""
    text.add t
    if text[^1] != '\n': text.add '\n'
  text.strip
