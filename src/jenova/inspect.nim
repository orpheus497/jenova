## Script function and purpose: the pipeline and retrieval diagnostics as they
## travel on response headers — the encoding the server writes, the parse every
## client reads, and the wording each is shown in. Below the widget layer so a
## self-test can assert the whole channel with no window and no generation.

import std/[strutils]

const
  ## The header the relay already carried. Named here so the window reads one
  ## table rather than testing for this one by hand beside the rest.
  CacheHeader* = "x-cache"

  IntentHeader* = "x-jenova-intent"
  RagHitsHeader* = "x-jenova-rag-hits"
  WebHitsHeader* = "x-jenova-web-hits"
  TrimmedHeader* = "x-jenova-trimmed"
  TrimmedBytesHeader* = "x-jenova-trimmed-bytes"
  EditorDocHeader* = "x-jenova-editor-doc"
  SysBytesHeader* = "x-jenova-sys-bytes"
  MsgCountHeader* = "x-jenova-msg-count"
  BodyBytesHeader* = "x-jenova-body-bytes"
  InjectedHeader* = "x-jenova-injected"
  HitHeader* = "x-jenova-hit"

  MaxHits* = 5
    ## What `pipeline.ragLimitFor` may ask retrieval for, so it is also the most
    ## hit headers one response can carry. A ceiling on the parse side too: a
    ## reply claiming more of them is answering a request this program did not
    ## make, and a client that grew a list from it would be sizing a panel on
    ## something upstream chose.

  MaxHitPathChars* = 512
    ## A path longer than this is truncated rather than sent. Paths come from
    ## the index and are bounded in practice; the bound is here so that a
    ## pathological one cannot inflate a response head.

## What a rewrite added to the outbound system message. A fixed set rather than
## free text, because these names go into a header and a value that can carry a
## CRLF is response splitting.
type InjectedBlock* = enum
  ibPersona = "persona"
  ibRag = "rag"
  ibWeb = "web"
  ibEditor = "editor"

type
  RetrievalHit* = object
    path*: string
    score*: float        ## the mixed rank the pipeline ordered on
    bm25*: float         ## keyword half, already normalised out of FTS5's sign
    semantic*: float     ## vector half
    startLine*: int      ## where in the file the best-scoring chunk starts

  Diagnostics* = object
    ## What one turn's response head said the pipeline did to it. Every field is
    ## the pipeline's own measurement; nothing here is inferred by the reader.
    present*: bool       ## did any diagnostic header arrive at all
    cacheHit*: bool
    intent*: string
    ragHits*: int
    webHits*: int
    editorDoc*: bool
    trimmed*: int        ## oldest turns dropped to fit the context budget
    trimmedBytes*: int
    sysBytes*: int       ## the assembled system message, after the rewrite
    msgCount*: int       ## messages in the body the backend was given
    bodyBytes*: int
    injected*: set[InjectedBlock]
    hits*: seq[RetrievalHit]

const
  ## Kept literal in a header value. Everything else is escaped, which is what
  ## lets a filesystem path travel on a response head at all: the two bytes that
  ## would make this response splitting are a CR and an LF, and neither is in
  ## here.
  Unreserved = {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'}

  HitSep* = ';'
    ## Separates a hit's five fields. It is escaped inside a path for the same
    ## reason the escape character itself is: a path may legitimately contain
    ## one, and a reader splitting on it would silently invent a sixth field.

## Function purpose: makes an arbitrary path safe to put in a header value, so
## the safety argument for these headers stays "no value can carry a CRLF"
## rather than becoming "no path is expected to".
proc encodeValue*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c in Unreserved: result.add c
    else: result.add '%' & toHex(ord(c), 2)

## Function purpose: the inverse, and deliberately total — a malformed escape is
## kept as the literal text it was rather than raising, because this parses a
## response head and a diagnostic must never be able to fail a generation.
proc decodeValue*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError:
        discard
    result.add s[i]
    inc i

## Function purpose: one hit as a header value. The three scores travel
## alongside the mixed one because a hit that ranked on keywords alone and one
## that ranked on meaning alone are different answers to the same question, and
## the mixed number cannot tell them apart.
##
## Action purpose: the snippet is deliberately absent. It is model-facing prose
## read out of the user's own files, and a header is the one place it would be
## logged by every proxy between here and a client.
proc encodeHit*(h: RetrievalHit): string =
  var p = h.path
  if p.len > MaxHitPathChars: p = p[0 ..< MaxHitPathChars]
  formatFloat(h.score, ffDecimal, 4) & HitSep &
    formatFloat(h.bm25, ffDecimal, 4) & HitSep &
    formatFloat(h.semantic, ffDecimal, 4) & HitSep &
    $h.startLine & HitSep & encodeValue(p)

## Function purpose: reads one back, answering whether it was well formed at
## all — a half-parsed hit shown as a path with no score is worse than no hit.
proc parseHit*(v: string): tuple[ok: bool, hit: RetrievalHit] =
  let parts = v.strip.split(HitSep)
  if parts.len != 5: return (false, RetrievalHit())
  var h = RetrievalHit()
  try:
    h.score = parseFloat(parts[0])
    h.bm25 = parseFloat(parts[1])
    h.semantic = parseFloat(parts[2])
    h.startLine = parseInt(parts[3])
  except ValueError:
    return (false, RetrievalHit())
  h.path = decodeValue(parts[4])
  if h.path.len == 0: return (false, RetrievalHit())
  (true, h)

## Function purpose: the set as a header value, in declaration order so two
## identical rewrites produce identical bytes and a cached reply's head still
## matches the one that produced it.
proc encodeInjected*(s: set[InjectedBlock]): string =
  var parts: seq[string]
  for b in InjectedBlock:
    if b in s: parts.add $b
  parts.join(",")

## Function purpose: an unknown name is dropped rather than rejected, so a
## client built against an older set of blocks still reads the ones it knows.
proc parseInjected*(v: string): set[InjectedBlock] =
  for name in v.split(','):
    let n = name.strip
    for b in InjectedBlock:
      if $b == n: result.incl b

## Function purpose: folds one raw header line into the diagnostics, answering
## whether it was one of ours. The window reads a response head line by line and
## this is what keeps that loop free of the header table.
##
## Action purpose: an unparseable number leaves the field alone rather than
## zeroing it. Zero is a meaningful answer here — "nothing was trimmed" — and a
## malformed header must not be able to claim it.
proc applyHeader*(d: var Diagnostics, line: string): bool =
  let colon = line.find(':')
  if colon <= 0: return false
  let name = line[0 ..< colon].strip.toLowerAscii
  let value = line[colon + 1 .. ^1].strip

  # A template rather than a nested proc: `d` is a `var` parameter and a closure
  # capturing one is refused outright, which is the compiler being right.
  template num(into: untyped) =
    try:
      into = parseInt(value)
      d.present = true
    except ValueError: discard

  case name
  of CacheHeader:
    if value.toLowerAscii.contains("hit"):
      d.cacheHit = true
      d.present = true
    return true
  of IntentHeader:
    if value.len > 0:
      d.intent = value
      d.present = true
  of RagHitsHeader: num(d.ragHits)
  of WebHitsHeader: num(d.webHits)
  of TrimmedHeader: num(d.trimmed)
  of TrimmedBytesHeader: num(d.trimmedBytes)
  of SysBytesHeader: num(d.sysBytes)
  of MsgCountHeader: num(d.msgCount)
  of BodyBytesHeader: num(d.bodyBytes)
  of EditorDocHeader:
    d.editorDoc = value == "1"
    d.present = true
  of InjectedHeader:
    d.injected = parseInjected(value)
    d.present = true
  of HitHeader:
    # The ceiling is enforced on the reading side as well as the writing one:
    # the count of these headers is chosen upstream, and a client that sized a
    # list from it would be letting a response decide how much it allocates.
    if d.hits.len < MaxHits:
      let (ok, h) = parseHit(value)
      if ok:
        d.hits.add h
        d.present = true
  else:
    return false
  true

## Function purpose: the whole head at once, for a caller that has it as one
## string rather than a line at a time.
proc parse*(raw: string): Diagnostics =
  for line in raw.splitLines():
    if line.strip.len > 0:
      discard result.applyHeader(line)

## Function purpose: a byte count in the unit a reader can hold in their head.
## These are prompt sizes, so the difference that matters is kilobytes.
proc humanBytes*(n: int): string =
  if n < 1024: $n & " B"
  elif n < 1024 * 1024: formatFloat(n.float / 1024.0, ffDecimal, 1) & " kB"
  else: formatFloat(n.float / (1024.0 * 1024.0), ffDecimal, 1) & " MB"

## Function purpose: names an intent in the words a user reads rather than in
## the one word the classifier's enum serialises to. The cases are those wire
## values, not the enum's identifiers, and an unrecognised one is passed through
## — the classifier owns that list, and this must not become a second place it
## has to be edited.
proc intentLabel*(v: string): string =
  case v
  of "": ""
  of "visual": "visual rewrite"
  of "filechat": "file chat"
  of "websearch": "web search"
  of "editor": "editor document"
  else: v

## Function purpose: what the block names mean, so the inspector says what was
## added to the prompt rather than printing the wire tokens.
proc injectedLabel*(b: InjectedBlock): string =
  case b
  of ibPersona: "persona"
  of ibRag: "repository context"
  of ibWeb: "web results"
  of ibEditor: "editor document"

## Function purpose: the chips shown while a turn is generating and after it —
## what the pipeline did, in the order it did it. Empty when the head carried no
## diagnostics, which is what keeps the row off screen on a plain relay.
proc processingDetails*(d: Diagnostics): seq[string] =
  if not d.present: return @[]
  if d.cacheHit: result.add "cache hit"
  let intent = intentLabel(d.intent)
  if intent.len > 0: result.add "intent: " & intent
  if d.ragHits > 0:
    result.add $d.ragHits & (if d.ragHits == 1: " chunk retrieved"
                             else: " chunks retrieved")
  if d.webHits > 0:
    result.add $d.webHits & (if d.webHits == 1: " web result"
                             else: " web results")
  if d.editorDoc: result.add "editor document attached"
  if d.msgCount > 0: result.add $d.msgCount & " messages sent"
  if d.sysBytes > 0: result.add "system " & humanBytes(d.sysBytes)
  if d.trimmed > 0:
    result.add $d.trimmed & (if d.trimmed == 1: " turn trimmed"
                             else: " turns trimmed")

## Function purpose: the one diagnostic that is a warning rather than a
## statistic. Trimming drops the oldest turns of a conversation to fit the
## context budget, and it is the only thing here that silently changes what the
## model was asked; empty means there is nothing to warn about.
proc trimWarning*(d: Diagnostics): string =
  if d.trimmed <= 0: return ""
  (if d.trimmed == 1: "The oldest turn was dropped"
   else: "The " & $d.trimmed & " oldest turns were dropped") &
    (if d.trimmedBytes > 0: " (" & humanBytes(d.trimmedBytes) & ")" else: "") &
    " to fit the context window. They are still in this conversation and were " &
    "not sent with this turn."

## Function purpose: the pipeline inspector's rows. Two sides are labelled
## separately and honestly: what this window posted, and what the backend was
## given after the server rewrote it — so the difference between them is the
## rewriting rather than a number nobody can source.
##
## Action purpose: the rewritten prompt itself is not here and does not travel.
## A response head is the wrong size for it, and the relay stores the captured
## stream verbatim for replay — so a body field carrying it would be filed in
## the cache and replayed to whoever asked the same question next.
proc pipelineRows*(d: Diagnostics, sentMessages, sentBytes: int):
    seq[tuple[label, value: string]] =
  if sentMessages > 0:
    result.add ("Posted by this window",
                $sentMessages & " messages, " & humanBytes(sentBytes))
  if not d.present: return
  if d.msgCount > 0 or d.bodyBytes > 0:
    result.add ("Sent to the model",
                $d.msgCount & " messages, " & humanBytes(d.bodyBytes))
  if d.sysBytes > 0:
    result.add ("System message", humanBytes(d.sysBytes))
  let intent = intentLabel(d.intent)
  result.add ("Intent", if intent.len > 0: intent else: "none")
  if d.injected.len > 0:
    var names: seq[string]
    for b in InjectedBlock:
      if b in d.injected: names.add injectedLabel(b)
    result.add ("Injected", names.join(", "))
  else:
    result.add ("Injected", "nothing")
  result.add ("Retrieval", (if d.ragHits > 0: $d.ragHits & " chunks"
                            else: "no hits"))
  if d.webHits > 0: result.add ("Web search", $d.webHits & " results")
  if d.editorDoc: result.add ("Editor", "the open document was attached")
  result.add ("Trimmed", (if d.trimmed > 0:
                            $d.trimmed & " turns, " & humanBytes(d.trimmedBytes)
                          else: "nothing"))
  if d.cacheHit:
    result.add ("Cache", "answered from the response cache")

## Function purpose: one retrieval hit as a heading, so the panel and any other
## reader name a chunk the same way.
proc hitTitle*(h: RetrievalHit): string =
  h.path & (if h.startLine > 1: ":" & $h.startLine else: "")

## Function purpose: the three scores spelled out, because the mixed rank alone
## cannot say whether a chunk was found by its words or by its meaning — which
## is the question anyone opening a retrieval inspector is asking.
proc hitScores*(h: RetrievalHit): string =
  "score " & formatFloat(h.score, ffDecimal, 3) &
    "    keyword " & formatFloat(h.bm25, ffDecimal, 3) &
    "    semantic " & formatFloat(h.semantic, ffDecimal, 3)
