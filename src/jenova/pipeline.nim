## Script function and purpose: everything that happens to a completion request
## between the client and the backend. Without this module the core is a plain
## reverse proxy; every behaviour that distinguishes this product from
## `llama-server` lives here.
##
## The order is part of the contract: intent detection strips its own marker,
## retrieval runs with a per-intent limit, its block is injected, web search runs
## only for that intent, editor context only for its own, then the persona, then
## tool stripping, and the cache key last.
##
## The key must stay last because it hashes the body *after* rewriting. Hashing
## the client's original body produces a different key for the same effective
## request and orphans every entry already stored.

import std/[base64, json, os, strutils, tables, times]
import ./http
import ./prompts
import ./rag
import ./websearch
import ./db
import ./workspace
import ./sha256
import ./nvimctl
import ./settings
import ./pdf

type
  Prepared* = object
    body*: string          ## the rewritten request body, ready for llama-server
    cacheKey*: string      ## SHA-256 of `body`; empty when caching does not apply
    intent*: Intent
    ragHits*: int
    webHits*: int
    hadTools*: bool
    editorDoc*: bool       ## an `Editor:` turn found a live document
    trimmed*: int          ## oldest turns dropped to fit the context budget

const
  ## An array rather than a table so the order is the declared one: the window
  ## shows these to the user (`gui.nim`'s empty transcript), and a Table
  ## iterates in whatever order hashing gives.
  IntentPrefixes* = [
    ("Visual Rewrite:", inVisual),
    ("Open File Chat:", inFileChat),
    ("Chatbot:", inFileChat),
    ("Web Search:", inWebSearch),
    ("Editor:", inEditor),
  ]

  ## A message already carrying a retrieval block is not retrieved for again,
  ## which is what stops a follow-up turn stacking the same block repeatedly
  ## down a conversation.
  ContextMarker = "--- REPOSITORY CONTEXT ---"

  LargePayloadChars = 2000   ## `proxy.lua:1258`

# Action purpose: a plain `string` global is refcounted memory every worker
# thread would touch, and casting the GC-safety warning away hides that rather
# than fixing it. A fixed buffer and a length are plain values, so a cross-thread
# read races on nothing.
type SharedStr = object
  buf: array[1024, char]
  len: int

var editorSocket: SharedStr

## Function purpose: unset by default, which is why the editor intent degrades
## to a plain answer on a host with no editor running rather than failing.
proc configureEditor*(socket: string) =
  let n = min(socket.len, editorSocket.buf.high)
  if n > 0: copyMem(addr editorSocket.buf[0], socket.cstring, n)
  editorSocket.len = n

# Written once at start-up and read-only afterwards, which is what makes it safe
# for the worker threads to share.
proc editorSock(): string =
  result = newString(editorSocket.len)
  if editorSocket.len > 0:
    copyMem(addr result[0], addr editorSocket.buf[0], editorSocket.len)

## Function purpose: the last user message is where the intent prefix and the
## retrieval query both come from, so it is located once rather than searched for
## at each step.
proc lastUserIndex(messages: JsonNode): int =
  result = -1
  if messages.kind != JArray: return
  for i in countdown(messages.len - 1, 0):
    let m = messages[i]
    if m.kind == JObject and m.hasKey("role") and m["role"].getStr == "user":
      return i

## Function purpose: the prefix is stripped because it is addressed to this
## program and not to the model, which would otherwise answer about the marker.
proc detectIntent*(text: string): tuple[intent: Intent, stripped: string] =
  let trimmed = text.strip(trailing = false)
  for (prefix, intent) in IntentPrefixes:
    if trimmed.startsWith(prefix):
      return (intent, trimmed[prefix.len .. ^1].strip(trailing = false))
  (inNone, text)

## Function purpose: a visual rewrite needs almost no context, a web search
## needs none because its context comes from the web, and a large file-chat
## payload needs more because the message itself is mostly file content.
proc ragLimitFor(intent: Intent, isLargePayload: bool): int =
  if isLargePayload: 5
  else:
    case intent
    of inVisual: 1
    of inWebSearch: 0
    else: 3

## Function purpose: for a large payload carrying a path marker the message is
## mostly file content, and searching on all of it retrieves noise — so the query
## is the file's basename plus the prose after the fence, which is the question
## the user actually asked.
proc ragQueryFor(message: string): tuple[query: string, large: bool] =
  if message.len <= LargePayloadChars:
    return (message, false)
  let pathIdx = message.find("Path:")
  if pathIdx < 0:
    return (message, false)

  var pathEnd = pathIdx + 5
  while pathEnd < message.len and message[pathEnd] in {' ', '\t'}: inc pathEnd
  var pathStop = pathEnd
  while pathStop < message.len and message[pathStop] notin {' ', '\t', '\n', '\r'}:
    inc pathStop
  let embeddedPath = message[pathEnd ..< pathStop]
  if embeddedPath.len == 0:
    return (message, false)

  let basename =
    if embeddedPath.contains('/'): embeddedPath.rsplit('/', 1)[^1]
    else: embeddedPath

  # The prose after the closing fence is the question, not the file above it.
  let fence = message.find("```\n\n")
  if fence >= 0:
    let after = message[(fence + 5) .. ^1].strip()
    if after.len > 10:
      return (basename & " " & after, true)
  (basename, true)

## Function purpose: three modes that are genuinely different, and collapsing
## them changes behaviour.
##
## With tools present the client's own system prompt is authoritative and never
## overridden; a mandate is inserted only when there is no system message, and
## contexts are appended to it. Conversationally the persona comes first, then
## the contexts, then any existing system message beneath. With no intent the
## persona is prepended and retrieval appended, without the intent personas.
proc injectSystem(messages: JsonNode, intent: Intent, hasTools: bool,
                  ragContext, webContext, editorContext: string) =
  if messages.kind != JArray: return
  let hasSystem = messages.len > 0 and messages[0].kind == JObject and
                  messages[0].hasKey("role") and
                  messages[0]["role"].getStr == "system"

  if hasTools:
    if not hasSystem:
      let mandate = "CORE MANDATE: You are Jenova, an autonomous agent. " &
                    prompts.FreeChat
      messages.elems.insert(%*{"role": "system", "content": mandate}, 0)
    # The role being present does not prove a `content` key is: a client may
    # send the text elsewhere, and direct indexing would fail the whole turn.
    var content = messages[0]{"content"}.getStr
    if webContext.len > 0: content.add "\n" & webContext
    if editorContext.len > 0: content.add "\n" & editorContext
    if ragContext.len > 0: content.add "\n" & ragContext
    messages[0]["content"] = %content
    return

  if intent != inNone:
    var systemPrompt = prompts.personaFor(intent)
    if webContext.len > 0: systemPrompt.add "\n" & webContext
    if editorContext.len > 0: systemPrompt.add "\n" & editorContext
    if ragContext.len > 0: systemPrompt.add "\n" & ragContext
    if hasSystem:
      messages[0]["content"] = %(systemPrompt & "\n\n" &
                                 messages[0]{"content"}.getStr)
    else:
      messages.elems.insert(%*{"role": "system", "content": systemPrompt}, 0)
    return

  # No intent: persona prepended, retrieval appended.
  if hasSystem:
    var content = prompts.FreeChat & "\n\n" & messages[0]{"content"}.getStr
    if ragContext.len > 0: content.add "\n" & ragContext
    messages[0]["content"] = %content
  else:
    var content = prompts.FreeChat
    if ragContext.len > 0: content.add "\n" & ragContext
    messages.elems.insert(%*{"role": "system", "content": content}, 0)

## Function purpose: hashes the final text, so it must run last. The algorithm
## is part of the contract rather than an implementation choice — changing it
## orphans every entry already stored rather than failing.
proc cacheKeyFor(body: string): string =
  sha256.sha256(body)

## The byte budget a conversation's messages must fit into, or zero for no
## trimming. Module state set once at start-up, because the pipeline is handed a
## body and never learns which configuration it belongs to.
var historyBudget = 0

## Function purpose: sets the budget from the deployment's own context size, once
## at start-up by each entry point.
##
## Action purpose: the conversion is an approximation and is stated as one. The
## configured context is a token count shared across parallel slots, so the
## per-slot share is derived, converted at four bytes per token, and halved to
## leave room for the reply and for the context blocks injected after this is
## computed.
##
## An exact answer needs the model's own tokenizer, which is an HTTP round trip
## per turn on the hot path. A rough bound that always leaves headroom beats an
## exact one nobody can afford, and the failure it prevents — a conversation that
## grows until every request is refused — is not subtle.
proc configureHistoryBudget*(ctxSize, slots: int) =
  if ctxSize <= 0: return
  let perSlot = ctxSize div max(1, slots)
  historyBudget = perSlot * 4 div 2

const
  ## What an image part is assumed to cost, in the same four-bytes-per-token
  ## currency the budget is set in. A picture becomes a fixed number of embedding
  ## tokens once the projector has run, and nothing about that number is
  ## proportional to the base64 that carried it. A deliberate overestimate: too
  ## high spends a little history that did not need spending, too low is the
  ## defect this exists to prevent.
  ImageContextBytes* = 1024 * 4

  ## The role, the braces and the key names — what a message costs before any of
  ## its content does. Counted so a conversation of many tiny turns is not
  ## measured as though it were free.
  MessageEnvelopeBytes* = 16

## Function purpose: deliberately not the serialised length of the message.
## Measuring that counts an image's base64 payload — megabytes of transport
## standing in for a few hundred tokens of context — so one screenshot exceeds
## any budget by itself and the trim below drops every earlier turn trying to
## reach a figure the final turn alone can never meet.
##
## Action purpose: the four-bytes-per-token conversion is fair for text and
## broken completely by base64, so an image payload is not measured at all and
## the part is charged a flat estimate instead.
proc messageWeight*(m: JsonNode): int =
  if m.kind != JObject: return ($m).len
  result = MessageEnvelopeBytes
  let content = m{"content"}
  if content.isNil: return
  case content.kind
  of JString:
    result += content.getStr.len
  of JArray:
    # An unrecognised part is charged its full serialisation, because an unknown
    # shape is exactly where guessing low is how a budget gets blown.
    for part in content:
      if part.kind != JObject:
        result += ($part).len
        continue
      case part{"type"}.getStr("")
      of "text":
        result += MessageEnvelopeBytes + part{"text"}.getStr.len
      of "image_url", "input_audio":
        result += ImageContextBytes
      else:
        result += ($part).len
  else:
    result += ($content).len

## Function purpose: without a trim the whole history is resent every turn, so a
## long conversation eventually exceeds the context window and every further
## request fails.
##
## Action purpose: two things are never dropped, which is why this is a function
## and not a slice. A system message carries the persona and the blocks injected
## into it, so dropping it changes who is answering; the final message is the
## turn being asked about, and a request without it is about nothing.
##
## Oldest first, because the recent turns are what the next answer depends on.
## Content is never shortened — a truncated message reads as a working one while
## meaning something the user did not write.
proc trimHistory*(messages: JsonNode, budgetBytes: int): int =
  if budgetBytes <= 0 or messages.kind != JArray or messages.len <= 1:
    return 0
  var total = 0
  for m in messages:
    total += messageWeight(m)
  if total <= budgetBytes: return 0

  var i = 0
  # The bound keeps the final turn whatever happens, and the index does not
  # advance on a delete: the next candidate shifts down into the same slot.
  while total > budgetBytes and i < messages.len - 1:
    let m = messages[i]
    if m.kind == JObject and m{"role"}.getStr == "system":
      inc i
      continue
    total -= messageWeight(m)
    messages.elems.delete(i)
    inc result

## Function purpose: the whole pipeline over one request body, answering the
## rewritten body and its cache key. A body that is not a chat request passes
## through untouched — the raw-prompt endpoints have no messages to inject into,
## and that check is here rather than at each caller.
proc prepare*(rawBody: string, projectRoot = ""): Prepared =
  result.body = rawBody

  var req: JsonNode
  try: req = parseJson(rawBody)
  except CatchableError: return
  if req.kind != JObject or not req.hasKey("messages"): return

  let messages = req["messages"]
  let idx = lastUserIndex(messages)
  if idx < 0: return

  var lastUser = messages[idx]{"content"}.getStr
  let (intent, stripped) = detectIntent(lastUser)
  result.intent = intent
  if stripped != lastUser:
    lastUser = stripped
    messages[idx]["content"] = %lastUser

  result.hadTools = req.hasKey("tools") and req["tools"].kind == JArray and
                    req["tools"].len > 0

  # Tool stripping comes first, because whether tools are present is what
  # decides which persona mode runs below.
  if intent == inVisual or intent == inWebSearch:
    if req.hasKey("tools"): req.delete("tools")
    req["tool_choice"] = %"none"
    result.hadTools = false

  var ragContext = ""
  var webContext = ""
  var editorContext = ""

  # A message already carrying a context block is a follow-up turn, and adding
  # another stacks duplicates down the conversation.
  if lastUser.len > 0 and not lastUser.contains(ContextMarker):
    let (query, large) = ragQueryFor(lastUser)
    let limit = ragLimitFor(intent, large)
    if limit > 0:
      let hits = rag.query(query, topK = limit, withSnippets = true,
                           pathFilter = projectRoot)
      result.ragHits = hits.len
      ragContext = rag.formatContext(hits)

    if intent == inWebSearch:
      let results = websearch.search(lastUser)
      result.webHits = results.len
      webContext = websearch.formatContext(results)

    # Action purpose: never attached to a turn that did not ask for it. It is
    # the largest block this can inject and it is read from a live editor, so
    # including it silently makes every unrelated question carry whatever file
    # happened to be open.
    if intent == inEditor:
      let sock = editorSock()
      if sock.len > 0:
        let doc = nvimctl.activeDocument(sock)
        result.editorDoc = doc.found
        editorContext = doc.asPromptContext()

    injectSystem(messages, intent, result.hadTools, ragContext, webContext,
                 editorContext)

  # Action purpose: outside the block above, so every request passes through it.
  # Inside, it would run only on a turn not already carrying a context marker —
  # so a long conversation would stop being trimmed exactly when it most needs
  # to be.
  #
  # After the system message is assembled, because that is what grows it and the
  # budget is measured against what is actually sent.
  result.trimmed = trimHistory(messages, historyBudget)

  result.body = $req
  result.cacheKey = cacheKeyFor(result.body)

## Function purpose: answers the stored body or empty. The caller owns the
## response, so the hit header is added there rather than here.
proc cacheLookup*(key: string): string =
  if key.len == 0: return ""
  try:
    let rows = db.query("SELECT response FROM llm_cache WHERE cache_key=?", key)
    if rows.len > 0 and rows[0].len > 0: rows[0][0] else: ""
  except CatchableError:
    ""

const
  MaxCacheEntries* = 256
    ## The rows here are whole model replies rather than short values, and
    ## nothing else in the schema deletes from this table — so without a cap it
    ## grows without bound inside the user's own database.
  MaxCacheEntryBytes* = 1024 * 1024
    ## One reply. Past this an entry is simply not cached: a cache exists to
    ## save a round trip, not to become the largest table present.

## Function purpose: requests here are streamed and the reader acts only on
## event lines, so a body stored as a plain JSON object carries none — the reader
## renders nothing and saves a blank turn. Storing only what can be replayed is
## what stops a hit being worse than a miss.
##
## Action purpose: not enforced inside the store, deliberately. The cap is shared
## policy and belongs on the storage primitive, while replayability is an
## invariant of the completion path alone — the other writer legitimately stores
## plain values.
proc isReplayableStream*(body: string): bool =
  body.contains("\ndata:") or body.startsWith("data:")

## Function purpose: the one place an entry is written, so the cap and the
## eviction below cannot be bypassed by a second writer.
proc cacheStore*(key, response: string) =
  if key.len == 0 or response.len == 0: return
  if response.len > MaxCacheEntryBytes: return
  try:
    db.exec("INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) " &
            "VALUES (?, ?, strftime('%s','now'))", key, response)
    # Action purpose: the delete goes by key out of an ordered subselect rather
    # than a bare `LIMIT`, because SQLite is not built with delete-limit support
    # by default and the direct form raises a syntax error at runtime — inside a
    # `try` that would discard it, making the eviction a silent no-op.
    #
    # The rowid tiebreak is load-bearing, not decoration. The timestamp has
    # one-second resolution, so a burst of turns inside one second would
    # otherwise evict in an arbitrary order and drop a reply that had just been
    # stored. Insert-or-replace assigns a fresh rowid, so a refreshed entry
    # correctly counts as the newest.
    db.exec("DELETE FROM llm_cache WHERE cache_key IN (" &
            "  SELECT cache_key FROM llm_cache" &
            "  ORDER BY timestamp DESC, rowid DESC" &
            "  LIMIT -1 OFFSET ?)", $MaxCacheEntries)
  except CatchableError:
    # Action purpose: silent by design rather than by oversight. This runs after
    # the reply has already reached the client, so there is no request left to
    # fail and nothing a user could act on. A cache that has stopped storing is
    # a diagnosis problem and not a correctness one — every miss is answered by
    # the model exactly as it would be with no cache at all.
    discard

## Function purpose: exported for the assertion, which is the only way to tell a
## cache that has stopped storing from one that is merely getting no hits.
proc cacheCount*(): int =
  try:
    let rows = db.query("SELECT COUNT(*) FROM llm_cache")
    if rows.len > 0 and rows[0].len > 0: parseInt(rows[0][0]) else: 0
  except CatchableError:
    0

## Function purpose: the request body the window posts for one chat turn, built
## below the widget layer so a self-test can read it. A body that is subtly wrong
## does not fail to compile and does not fail a suite — it fails at the server,
## at runtime, in front of the user.
##
## Two of the keys ask for data the backend will not send unless asked and change
## nothing the model generates: per-token timings, so the counts on screen are
## live rather than arriving with the last chunk, and the reasoning format, which
## splits a reasoning model's thinking out of the answer instead of leaving it
## inline.
##
## Action purpose: continuing needs both of its fields. Setting the continue flag
## alone is refused outright — the generation prompt has to be turned off as
## well, or the template closes the assistant turn and the model starts a fresh
## answer instead of extending the one it was given.
##
## The settings merge happens last and is why this takes them at all. The
## sampling parameters are only ever JSON fields on this body, so merging here
## makes the whole feature assertable with no window and no generation.
proc chatBody*(messages: JsonNode, continuing = false,
               opts = settings.initSettings(), wsContext = ""): string =
  # Action purpose: the workspace's notes and files go into the system message
  # here rather than in `prepare`, because that is handed a body and never
  # learns which conversation it belongs to.
  if wsContext.len > 0 and messages.kind == JArray:
    let block1 = "\n\n" & workspace.ContextHeading & "\n" & wsContext
    if messages.len > 0 and messages[0].kind == JObject and
       messages[0]{"role"}.getStr == "system":
      messages[0]["content"] = %(messages[0]{"content"}.getStr & block1)
    else:
      messages.elems.insert(%*{"role": "system", "content": block1.strip}, 0)
  var req = %*{"messages": messages, "stream": true,
               "timings_per_token": true,
               "reasoning_format": settings.reasoningFormat(opts)}
  if continuing:
    # The visible answer is what is resumed, never the reasoning.
    req["continue_final_message"] = %"content"
    req["add_generation_prompt"] = %false
  # After the fixed fields, so a custom parameter can override any of them
  # deliberately, and before serialisation so nothing downstream re-parses.
  settings.applyTo(req, opts)
  $req

## A generation can fail in ways that need different responses from the user, so
## one grey line saying the server answered 500 is not a diagnosis. Kept here
## rather than in the window because a classifier is pure and needs no window to
## be asserted.
type
  ChatErrorKind* = enum
    cekContextOverflow  ## the prompt does not fit; the numbers are known
    cekTimeout          ## the server accepted it and stopped answering
    cekBackendDown      ## nothing is listening, or it is still loading
    cekBadRequest       ## the request was refused as malformed
    cekServerError      ## the server broke
    cekNetwork          ## the connection failed or was lost

  ChatError* = object
    kind*: ChatErrorKind
    message*: string      ## what to show the USER, in plain English
    detail*: string       ## the server's own words, when it gave any
    promptTokens*: int    ## overflow only; 0 when unknown
    ctxSize*: int         ## overflow only; 0 when unknown
    retryable*: bool      ## is offering a Retry honest here?

## Function purpose: the two numbers are the whole value of an overflow error.
## "Too long" is not actionable; the request size against the limit tells the
## user whether to start a new conversation or raise the context.
proc parenNumbers(s: string): seq[int] =
  var i = 0
  while i < s.len:
    if s[i] == '(':
      var j = i + 1
      var digits = ""
      while j < s.len and s[j] in {'0' .. '9', ',', '_'}:
        if s[j] in {'0' .. '9'}: digits.add s[j]
        j.inc
      if digits.len > 0:
        try: result.add parseInt(digits) except ValueError: discard
      i = j
    else: i.inc

## Function purpose: turns a status and whatever body came with it into
## something worth putting on screen; the exception message covers the case
## where there was no response at all.
proc classifyError*(status: int, body = "", exceptionMsg = ""): ChatError =
  # A transport failure has no status to read.
  if status == 0:
    let m = exceptionMsg.toLowerAscii
    if m.contains("timeout") or m.contains("timed out"):
      return ChatError(kind: cekTimeout, retryable: true,
        message: "the server stopped responding part-way through",
        detail: exceptionMsg)
    if m.contains("connection refused") or m.contains("cannot connect") or
       m.contains("no route"):
      return ChatError(kind: cekBackendDown, retryable: true,
        message: "the backend is not running — start it from the tray",
        detail: exceptionMsg)
    return ChatError(kind: cekNetwork, retryable: true,
      message: "the connection to the backend failed", detail: exceptionMsg)

  var serverMsg = ""
  var errType = ""
  if body.len > 0:
    try:
      let node = parseJson(body)
      let e = node{"error"}
      if e != nil and e.kind == JObject:
        serverMsg = e{"message"}.getStr("")
        errType = e{"type"}.getStr("")
    except CatchableError:
      discard

  if errType == "exceed_context_size_error" or
     (serverMsg.len > 0 and serverMsg.contains("context size")):
    let nums = parenNumbers(serverMsg)
    result = ChatError(kind: cekContextOverflow, detail: serverMsg,
                       retryable: false)
    if nums.len >= 2:
      result.promptTokens = nums[0]
      result.ctxSize = nums[1]
      result.message = "this conversation is too long — " & $nums[0] &
        " tokens against a context of " & $nums[1] &
        ". Start a new chat, or raise the context size."
    else:
      result.message = "this conversation is longer than the model's context. " &
        "Start a new chat, or raise the context size."
    return

  case status
  of 502, 503:
    # Action purpose: one status means nothing is behind the proxy and the other
    # means the backend is still loading. Both are "not ready" and both are worth
    # retrying, unlike every other error here.
    ChatError(kind: cekBackendDown, retryable: true, detail: serverMsg,
      message: "the backend is not answering yet — it may still be loading")
  of 400, 422:
    ChatError(kind: cekBadRequest, retryable: false, detail: serverMsg,
      message: (if serverMsg.len > 0: "the server refused the request: " &
                serverMsg else: "the server refused the request"))
  of 401, 403:
    ChatError(kind: cekBadRequest, retryable: false, detail: serverMsg,
      message: "the server refused this request as unauthorised")
  of 404:
    ChatError(kind: cekBadRequest, retryable: false, detail: serverMsg,
      message: "the completion endpoint was not found on the backend")
  of 413:
    # Not retryable, for the same reason an overflow is not: the identical body
    # would be sent again and refused identically, so a retry button here would
    # be a lie. The remedy is the user's, so it is named rather than implied.
    ChatError(kind: cekBadRequest, retryable: false, detail: serverMsg,
      message: (if serverMsg.len > 0:
                  "the request is too large to send: " & serverMsg &
                  ". Remove an attachment, or send a smaller one."
                else: "the request is too large to send. Remove an " &
                      "attachment, or send a smaller one."))
  else:
    ChatError(kind: cekServerError, retryable: true, detail: serverMsg,
      message: (if serverMsg.len > 0:
                  "the server failed: " & serverMsg
                else: "the server answered " & $status))

## The stored attachment shape is the frozen client's rather than a new one, and
## this turns it into the content parts the backend reads — including the order,
## because a request that differs from the one another client sends against the
## same conversation is not parity. Below the widget layer so a self-test can see
## the result.

## Function purpose: one header for a text attachment, used by both the request
## path and the copy path so what is pasted matches what the model was shown.
proc attachmentText*(label, name, content: string): string =
  ## The header a text attachment is introduced under, which the copy path
  ## reuses so what is pasted matches what the model was shown.
  "\n\n--- " & label & ": " & name & " ---\n" & content


## Function purpose: a turn with no attachments keeps a plain string. The array
## form is used only when it is needed, because switching every message to parts
## changes every request this program sends for no reason.
proc contentFor*(text: string, extra: JsonNode): JsonNode =
  if extra.isNil or extra.kind != JArray or extra.len == 0:
    return %text

  var parts = newJArray()
  if text.len > 0:
    parts.add %*{"type": "text", "text": text}

  proc ofType(t: string): seq[JsonNode] =
    for e in extra:
      if e.kind == JObject and e{"type"}.getStr("") == t: result.add e

  # Images first, then text, then audio, then PDFs — the order the other client
  # sends, and part of what makes the two requests comparable.
  for img in ofType("IMAGE"):
    parts.add %*{"type": "image_url",
                 "image_url": {"url": img{"base64Url"}.getStr("")}}

  for f in ofType("TEXT"):
    parts.add %*{"type": "text",
                 "text": attachmentText("File", f{"name"}.getStr(""),
                                        f{"content"}.getStr(""))}

  # An older client stored pasted text under a different key, and an imported
  # conversation still carries them — dropping them silently loses content the
  # user attached.
  for f in ofType("context"):
    parts.add %*{"type": "text",
                 "text": attachmentText("File", f{"name"}.getStr(""),
                                        f{"content"}.getStr(""))}

  for a in ofType("AUDIO"):
    let mime = a{"mimeType"}.getStr("")
    parts.add %*{"type": "input_audio",
                 "input_audio": {"data": a{"base64Data"}.getStr(""),
                                 "format": (if mime.contains("wav"): "wav"
                                            else: "mp3")}}

  for p in ofType("PDF"):
    # A PDF reaches the model as page images when it was rasterised and as
    # extracted text otherwise. Nothing here writes the first form, but an
    # imported conversation carries it and this is what sends it back.
    if p{"processedAsImages"}.getBool(false) and p{"images"} != nil and
       p{"images"}.kind == JArray:
      for img in p{"images"}:
        parts.add %*{"type": "image_url", "image_url": {"url": img.getStr("")}}
    else:
      parts.add %*{"type": "text",
                   "text": attachmentText("PDF file", p{"name"}.getStr(""),
                                          p{"content"}.getStr(""))}
  parts

## The attachment classifier, below the widget layer because it governs what the
## model is asked to look at and has to be assertable. It is also called from
## inside the window's own timer, where a proc taking the window's state type
## does not yet exist.
type
  Attachment* = object
    ## The stored attachment type as a string, because that is what goes into
    ## the row and is read back by both clients.
    kind*: string
    name*: string
    ## An image carries a `data:` URL; text carries the file's own text.
    payload*: string
    bytes*: int
    ## The identity of this attachment and never a digest of its content. The
    ## window caches a decoded thumbnail per attachment and derives the key on
    ## every frame, so a key that costs a pass over the payload puts a
    ## multi-megabyte hash inside every redraw. Set once, where the attachment
    ## is created.
    key*: string

const
  ## The image types the multimodal projector accepts. Anything else readable
  ## as text is attached as text, and anything else at all is refused with a
  ## reason rather than sent as bytes the model cannot look at.
  ImageExts* = [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"]

  ## Everything in a request body that is not the attachment: the envelope, the
  ## persona, the injected blocks and whatever history survived the trim.
  ## Kilobytes in practice, and a deliberate overestimate — being wrong this way
  ## costs a little capacity, and the other way costs an unexplained refusal.
  RequestEnvelopeReserve* = 1024 * 1024

  ## An attachment over this is refused and never truncated. A shortened
  ## document changes what the model was asked about while still looking like it
  ## worked, and the reply comes back confident and about a fragment. Measured on
  ## the file as read, before base64 expansion, and applied to every kind.
  ##
  ## Derived from the request body cap rather than chosen beside it. Two
  ## independent numbers are measured on different sides of base64 — the file
  ## here, the encoded length there — so they cross at the expansion ratio and a
  ## file passes this check only to be refused as a request. Dividing by that
  ## same ratio is what makes "accepted here" mean "sendable there".
  ##
  ## The guarantee is per attachment and not per request: several that each pass
  ## can still exceed the body cap together, which the typed 413 covers.
  MaxAttachmentBytes* = (http.MaxBodyBytes - RequestEnvelopeReserve) * 3 div 4

## Function purpose: decided by reading the file rather than by its extension,
## so a log, a config and a file with no extension are all attachable where a
## list of known suffixes would refuse them.
##
## Action purpose: a NUL byte is the test, because that is what actually breaks
## the request — JSON cannot carry one, every binary format has them within the
## first few kilobytes, and no text encoding does.
proc looksTextual*(data: string): bool =
  let sample = if data.len > 8192: data[0 ..< 8192] else: data
  for ch in sample:
    if ch == '\0': return false
  true

## Function purpose: the data URL's media type, which the projector reads to
## decide how to decode the image — a wrong one is a silent decode failure.
proc mimeForImage*(ext: string): string =
  case ext.toLowerAscii
  of ".png": "image/png"
  of ".webp": "image/webp"
  of ".gif": "image/gif"
  of ".bmp": "image/bmp"
  else: "image/jpeg"

## Function purpose: a drag-and-drop delivers a URI rather than a path, and
## undoing the percent-encoding is required rather than cosmetic — a dropped file
## whose name contains a space would otherwise fail to open, and that is most
## screenshots.
proc uriToPath*(uri: string): string =
  var s = uri.strip
  if s.startsWith("file://"): s = s[7 .. ^1]
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    i.inc

## Function purpose: shared by the file picker and the drop target, so the two
## cannot disagree about what is attachable.
##
## Action purpose: refusing an image because the backend has not yet said whether
## it can see one is the same defect as accepting one it cannot read, so an
## unanswered capability check allows the attachment.
proc readAttachment*(path: string, visionKnown, visionOk: bool):
    tuple[ok: bool, att: Attachment, err: string] =
  let name = path.extractFilename

  # Action purpose: the size is checked before the file is read. Reading first
  # and refusing afterwards still pulls the whole file into memory, which is the
  # cost the cap exists to prevent — a very large file hangs the window on the
  # read no matter what the check then decides.
  var size = 0'i64
  try:
    size = getFileSize(path)
  except CatchableError as e:
    return (false, Attachment(),
            "could not read " & name & ": " & e.msg)
  if size > MaxAttachmentBytes:
    # Action purpose: rounded up. Truncating division reports a file barely over
    # the cap as being exactly at it, which reads as a bug in the check rather
    # than a file that is too big.
    const Mib = 1024 * 1024
    return (false, Attachment(), name & " is " &
      $((size + Mib - 1) div Mib) & " MB and the limit is " &
      $(MaxAttachmentBytes div Mib) & " MB. " &
      "Attach a smaller file — Jenova does not shorten it for you, because a " &
      "truncated document would be answered as though it were the whole thing.")

  var data = ""
  try:
    data = readFile(path)
  except CatchableError as e:
    return (false, Attachment(),
            "could not read " & name & ": " & e.msg)
  let ext = path.splitFile.ext.toLowerAscii

  # Identity, not content: the source path, size and mtime distinguish two
  # staged files without a pass over either one's bytes, and two attachments of
  # the same file are genuinely the same picture and may share a cached
  # thumbnail.
  #
  # Action purpose: the whole path and not the basename. Keyed on the basename,
  # `~/a/diagram.png` and `~/b/diagram.png` collided whenever they matched on
  # size and mtime — which is exactly what a copied file, a checkout of the same
  # repository, or two exports written in the same second all produce — and the
  # thumbnail cache then showed the first picture for the second attachment.
  # Absolute, so the same file reached by a relative path and by its full one is
  # still one identity.
  let ident = try: path.absolutePath.normalizedPath except OSError: path
  var stamp = ""
  try: stamp = $getLastModificationTime(path).toUnix
  except CatchableError: discard
  let key = ident & ":" & $size & ":" & stamp

  if ext in ImageExts:
    if visionKnown and not visionOk:
      return (false, Attachment(), name &
        " is an image, and the loaded model cannot see images. " &
        "Load a vision model to attach it.")
    return (true, Attachment(kind: "IMAGE", name: name,
      payload: "data:" & mimeForImage(ext) & ";base64," & base64.encode(data),
      bytes: data.len, key: key), "")

  # A PDF is attached as its extracted text, and is tried before the text test
  # because a PDF is binary and that test would refuse it.
  #
  # Action purpose: no text means refuse, never attach an empty document. A
  # scanned page carries images and no text objects, and an empty attachment
  # looks exactly like a working one while the model answers about nothing.
  if ext == ".pdf":
    let text = pdf.textFrom(data)
    if text.len == 0:
      return (false, Attachment(), name &
        " has no text Jenova can read — it is most likely a scan, an encrypted " &
        "file, or a font this reader cannot decode. Attach the text itself.")
    return (true, Attachment(kind: "PDF", name: name, payload: text,
                             bytes: text.len, key: key), "")

  if not looksTextual(data):
    return (false, Attachment(),
            name & " is not text and is not an image Jenova can attach.")

  result = (true, Attachment(kind: "TEXT", name: name, payload: data,
                             bytes: data.len, key: key), "")

## Function purpose: the reduction from the stored node to what the transcript
## can draw, and lossy on purpose — a PDF becomes its extracted text and audio is
## dropped, because neither is something the window renders. The request path
## keeps the original node and sends both, which is why the memo holds each.
proc attachmentsOfNode*(node: JsonNode): seq[Attachment] =
  if node.isNil or node.kind != JArray: return
  # The indexed loop form is not available on a JSON array: it resolves to the
  # object iterator, which asserts the node is an object and aborts the process.
  var i = -1
  for e in node:
    inc i
    if e.kind != JObject: continue
    # The identity of a stored attachment is its position in the row it came
    # from: stable, unique, and free to compute.
    let key = $i & ":" & e{"name"}.getStr("")
    case e{"type"}.getStr("")
    of "IMAGE":
      result.add Attachment(kind: "IMAGE", name: e{"name"}.getStr(""),
                            payload: e{"base64Url"}.getStr(""), key: key)
    of "TEXT", "context", "PDF":
      let body = e{"content"}.getStr("")
      result.add Attachment(kind: "TEXT", name: e{"name"}.getStr(""),
                            payload: body, bytes: body.len, key: key)
    else: discard

## Function purpose: the same reduction straight from the stored text, for
## callers with no message id to memoise against.
proc parseAttachments*(extra: string): seq[Attachment] =
  if extra.len == 0: return
  var node: JsonNode
  try: node = parseJson(extra) except CatchableError: return
  attachmentsOfNode(node)

## Function purpose: what Copy puts on the clipboard for one turn, under the
## setting that governs it. Off is the plain message text; on appends each text
## attachment under the same header the model was shown it with, so what is
## pasted and what the model read are the same thing.
##
## Action purpose: images are skipped in both states. A base64 data URL is not
## something a clipboard paste can use, and it is the largest string in the turn.
proc copyTextFor*(text: string, atts: seq[Attachment], plain: bool): string =
  result = text
  if not plain: return
  for a in atts:
    if a.kind == "IMAGE": continue
    if a.payload.len == 0: continue
    result.add attachmentText("File", a.name, a.payload)

type
  ParseMemo* = object
    ## The render path runs on every frame and must never do work proportional
    ## to a payload, so one parse is held here and the frame does a lookup.
    ##
    ## Both forms are kept from the same parse deliberately. The transcript needs
    ## the reduced list, which is lossy; the outbound request needs the original
    ## node, because it sends the PDF page images and audio parts an imported
    ## conversation carries. Deriving the request from the lossy form silently
    ## drops them from what the model is sent.
    ##
    ## `parses` is not decoration: it is the only thing that can assert this. A
    ## per-frame cost reintroduced later is invisible to every other check — it
    ## compiles, passes and renders correctly, and is discovered when the window
    ## stops responding.
    nodes: Table[string, JsonNode]
    atts: Table[string, seq[Attachment]]
    stamps: Table[string, int]
    ## Insertion order, so the oldest can be dropped when the memo is over its
    ## cap. Only a new id is appended; a re-parse under an existing id replaces
    ## its entry without moving it.
    order: seq[string]
    parses*: int

const ParseMemoCap* = 128
  ## The expensive memo of the two: one entry retains the whole stored array,
  ## every image's full data URL included, and a second copy of the same bytes
  ## in the reduced form beside it.
  ##
  ## The cap is lower than the markdown memo's because an entry here is
  ## unboundedly larger — parsed markdown is proportional to the message text,
  ## this is proportional to whatever was attached to it. Still far more than one
  ## branch of one conversation, so the per-frame guarantee is untouched.

## Function purpose: evicts in batches rather than one per insert, because a
## per-insert removal from the front shifts the whole sequence — an O(n) cost on
## a path that must do no work proportional to anything.
proc evict(memo: var ParseMemo) =
  if memo.order.len <= ParseMemoCap: return
  let drop = max(1, ParseMemoCap div 4)
  for i in 0 ..< drop:
    memo.nodes.del(memo.order[i])
    memo.atts.del(memo.order[i])
    memo.stamps.del(memo.order[i])
  memo.order = memo.order[drop .. ^1]

## Function purpose: parses once and answers both forms — the original node for
## the request path and the reduced list for the transcript.
##
## A message with no id is never memoised: an assistant turn is a live buffer
## while it streams and only becomes a row when it completes, so caching it would
## pin the first token on screen. The stamp is the payload's length, which
## catches the one way a saved row still changes.
proc entryFor*(memo: var ParseMemo, id, extra: string):
    tuple[node: JsonNode, atts: seq[Attachment]] =
  if id.len > 0 and memo.stamps.getOrDefault(id, -1) == extra.len and
     memo.atts.hasKey(id):
    return (memo.nodes.getOrDefault(id, nil), memo.atts[id])

  inc memo.parses
  var node: JsonNode = nil
  if extra.len > 0:
    try: node = parseJson(extra) except CatchableError: node = nil
  let atts = attachmentsOfNode(node)
  if id.len > 0:
    if not memo.atts.hasKey(id):
      memo.order.add id
      memo.evict()
    memo.nodes[id] = node
    memo.atts[id] = atts
    memo.stamps[id] = extra.len
  (node, atts)

## Function purpose: the transcript's half of the memoised parse, so a caller
## that only draws does not have to know the original node exists.
proc attachmentsFor*(memo: var ParseMemo, id, extra: string): seq[Attachment] =
  memo.entryFor(id, extra).atts

## Function purpose: the stored array as the request path needs it — the
## original node, unreduced, so nothing the model should see is dropped.
proc extraNodeFor*(memo: var ParseMemo, id, extra: string): JsonNode =
  memo.entryFor(id, extra).node

## Function purpose: for a surface whose payload changes under an id that does
## not, where the length stamp cannot see the difference.
proc forget*(memo: var ParseMemo, id: string) =
  memo.nodes.del(id)
  memo.atts.del(id)
  memo.stamps.del(id)
  # Action purpose: the queue entry goes with them, because `entryFor` appends
  # an id only when `atts` does not already hold it. Left behind, the next parse
  # of the same row appends a second entry for it, and a note forgotten and
  # redrawn repeatedly fills `order` with copies of one id — `evict` then walks
  # stale entries and deletes live map entries while the maps sit well under the
  # cap. O(n) and affordable: this is called where a payload is re-baselined,
  # never from a frame.
  let at = memo.order.find(id)
  if at >= 0: memo.order.delete(at)

## Function purpose: switching conversation makes every entry here dead at once,
## which is cheaper to empty than to let the cap evict one insert at a time.
proc clear*(memo: var ParseMemo) =
  memo.nodes.clear()
  memo.atts.clear()
  memo.stamps.clear()
  memo.order.setLen(0)

## Function purpose: exported for the assertion, so a cap that stops working
## fails a test rather than growing quietly.
proc len*(memo: ParseMemo): int = memo.atts.len
