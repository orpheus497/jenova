## Script function and purpose: the completion pipeline — **the "Intelligence" in
## Intelligence Proxy**, replacing `lib/proxy.lua:1225-1400`.
##
## Recorded as **N-30**, the largest gap in the rewrite: before this module the
## Nim core read `stream`, `max_tokens` and `messages`/`prompt` and forwarded
## them, which made it a plain reverse proxy in front of `llama-server`. Every
## behaviour that distinguishes Jenova from `llama-server` lives here.
##
## The steps below run in this order, and **the order is part of the contract**:
##
## 1. **Intent detection** — a prefix on the last user message, stripped after
##    matching so the model never sees the marker. `IntentPrefixes` is the list.
## 2. **RAG retrieval** — a per-intent result limit, plus a rewritten query for
##    large file-chat payloads.
## 3. **RAG injection** — a `--- REPOSITORY CONTEXT ---` block.
## 4. **Web search** — only for the websearch intent.
## 5. **Editor context** — only for `Editor:`, read live from Neovim through
##    `nvimctl`. **Never attached to a turn that did not ask for it:** it is the
##    largest block injected here, and silently including it would make every
##    unrelated question carry whatever file happened to be open (G-18, D-AT).
## 6. **Persona injection** — three modes that are not interchangeable.
## 7. **Tool stripping** — for the two intents that gain nothing from tools.
## 8. **Cache key** — SHA-256 of the **rewritten** body.
##
## **The cache key must stay last.** The key is the hash of the body *after* rewriting,
## so an entry stored by `proxy.lua` and one stored here only agree if both hash
## the same final text. Hashing the client's original body would silently
## produce a different key and orphan every existing cache entry.

import std/[base64, json, os, strutils, tables, times]
import ./prompts
import ./rag
import ./websearch
import ./db
import ./workspace
import ./sha256
import ./nvimctl
import ./settings

type
  Prepared* = object
    body*: string          ## the rewritten request body, ready for llama-server
    cacheKey*: string      ## SHA-256 of `body`; empty when caching does not apply
    intent*: Intent
    ragHits*: int
    webHits*: int
    hadTools*: bool
    editorDoc*: bool       ## an `Editor:` turn found a live document

const
  IntentPrefixes = {
    "Visual Rewrite:": inVisual,
    "Open File Chat:": inFileChat,
    "Chatbot:": inFileChat,
    "Web Search:": inWebSearch,
    "Editor:": inEditor,
  }.toTable

  ## `proxy.lua:1255` — a message already carrying repository context is not
  ## re-retrieved for, which is what stops a follow-up turn stacking the same
  ## block repeatedly down a conversation.
  ContextMarker = "--- REPOSITORY CONTEXT ---"

  LargePayloadChars = 2000   ## `proxy.lua:1258`

# Action purpose: a plain `string` global is reference-counted memory that every
# worker thread would touch, and the `{.cast(gcsafe).}` that silenced the
# compiler here only hid that. This is `server.nim`'s SharedStr: a fixed buffer
# and a length, both plain values, so a cross-thread read races on nothing.
type SharedStr = object
  buf: array[1024, char]
  len: int

var editorSocket: SharedStr

## Function purpose: tell the pipeline where Neovim is listening, the way
## `rag.configureEmbed` supplies the embedding server's address. Unset by
## default, which is why `Editor:` degrades to a plain answer on a host with no
## editor running rather than failing the turn.
proc configureEditor*(socket: string) =
  let n = min(socket.len, editorSocket.buf.high)
  if n > 0: copyMem(addr editorSocket.buf[0], socket.cstring, n)
  editorSocket.len = n

# Written once at startup, read-only afterwards; the server's worker threads only
# read it.
proc editorSock(): string =
  result = newString(editorSocket.len)
  if editorSocket.len > 0:
    copyMem(addr result[0], addr editorSocket.buf[0], editorSocket.len)

## Function purpose: find the last user message, which is the one the intent
## prefix and the RAG query come from. Returns -1 when there is none.
proc lastUserIndex(messages: JsonNode): int =
  result = -1
  if messages.kind != JArray: return
  for i in countdown(messages.len - 1, 0):
    let m = messages[i]
    if m.kind == JObject and m.hasKey("role") and m["role"].getStr == "user":
      return i

## Function purpose: detect and strip an intent prefix. The prefix is removed
## from the message because it is addressed to Jenova, not to the model — the
## original does the same at `proxy.lua:1247`.
proc detectIntent(text: string): tuple[intent: Intent, stripped: string] =
  let trimmed = text.strip(trailing = false)
  for prefix, intent in IntentPrefixes:
    if trimmed.startsWith(prefix):
      return (intent, trimmed[prefix.len .. ^1].strip(trailing = false))
  (inNone, text)

## Function purpose: how many RAG hits an intent wants. A visual rewrite needs
## almost no context, a web search needs none because its context comes from the
## web, and a large file-chat payload needs more because the message itself is
## mostly file content. `proxy.lua:1256,1264`.
proc ragLimitFor(intent: Intent, isLargePayload: bool): int =
  if isLargePayload: 5
  else:
    case intent
    of inVisual: 1
    of inWebSearch: 0
    else: 3

## Function purpose: build the retrieval query. For a large payload carrying a
## `Path:` marker, the message is mostly file content and searching on all of it
## retrieves noise — so the original searches on the file's basename plus
## whatever prose follows the code fence, which is the user's actual question.
## Reproduces `proxy.lua:1258-1268`.
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

  # The prose after the closing fence is the question the user actually asked.
  let fence = message.find("```\n\n")
  if fence >= 0:
    let after = message[(fence + 5) .. ^1].strip()
    if after.len > 10:
      return (basename & " " & after, true)
  (basename, true)

## Function purpose: assemble the system prompt and inject it, reproducing the
## three modes at `proxy.lua:1300-1345`. They are genuinely different and
## collapsing them would change behaviour:
##
## * **Agent mode** (the request carries tools) — the client's own system prompt
##   is authoritative and is never overridden. A CORE MANDATE is inserted only
##   when no system message exists, and contexts are appended to it.
## * **Conversational mode** — persona first, then contexts, then any existing
##   system message beneath. This is the Web UI's path.
## * **No intent** — persona prepended and RAG appended, without the intent
##   personas.
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
    # `hasSystem` proves the role, not that a `content` key exists — a client may
    # send `{"role":"system"}` with the text elsewhere. Direct indexing raised
    # KeyError and failed the whole turn; the optional accessor yields "".
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

  # No intent: persona prepended, RAG appended.
  if hasSystem:
    var content = prompts.FreeChat & "\n\n" & messages[0]{"content"}.getStr
    if ragContext.len > 0: content.add "\n" & ragContext
    messages[0]["content"] = %content
  else:
    var content = prompts.FreeChat
    if ragContext.len > 0: content.add "\n" & ragContext
    messages.elems.insert(%*{"role": "system", "content": content}, 0)

## Function purpose: the SHA-256 the cache is keyed on. `proxy.lua:1386` hashes
## the rewritten body, so this must run last and on the final text — and it must
## be **SHA-256**, not merely "a hash": a different algorithm silently orphans
## every cache entry the running system has already written. `sha256.nim` is
## asserted against the published FIPS 180-4 vectors for that reason.
proc cacheKeyFor(body: string): string =
  sha256.sha256(body)

## Function purpose: run the whole pipeline over a completion request body.
## Returns the rewritten body and the cache key. A body that is not a chat
## request passes through untouched — `/completion` and `/infill` carry a raw
## prompt with no messages to inject into.
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

  # Tool stripping comes before the persona decision, because whether tools are
  # present decides which persona mode runs. proxy.lua:1301-1306.
  if intent == inVisual or intent == inWebSearch:
    if req.hasKey("tools"): req.delete("tools")
    req["tool_choice"] = %"none"
    result.hadTools = false

  var ragContext = ""
  var webContext = ""
  var editorContext = ""

  # A message that already carries a context block is a follow-up turn; adding
  # another would stack duplicates down the conversation.
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

    # Only for `Editor:` — the document is never attached to a turn that did not
    # ask for it. It is the largest block the pipeline can inject and it is read
    # from a live editor, so silently including it would make every unrelated
    # question carry whatever file happened to be open (G-18, D-AT).
    if intent == inEditor:
      let sock = editorSock()
      if sock.len > 0:
        let doc = nvimctl.activeDocument(sock)
        result.editorDoc = doc.found
        editorContext = doc.asPromptContext()

    injectSystem(messages, intent, result.hadTools, ragContext, webContext,
                 editorContext)

  result.body = $req
  result.cacheKey = cacheKeyFor(result.body)

## Function purpose: look up a prepared request in the response cache. Returns
## the stored response body, or an empty string. `proxy.lua:1388` adds an
## `X-Cache: HIT` header on the way out; the caller owns the response so it adds
## the header there.
proc cacheLookup*(key: string): string =
  if key.len == 0: return ""
  try:
    let rows = db.query("SELECT response FROM llm_cache WHERE cache_key=?", key)
    if rows.len > 0 and rows[0].len > 0: rows[0][0] else: ""
  except CatchableError:
    ""

proc cacheStore*(key, response: string) =
  if key.len == 0 or response.len == 0: return
  try:
    db.exec("INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) " &
            "VALUES (?, ?, strftime('%s','now'))", key, response)
  except CatchableError:
    discard

## Function purpose: the request body the desktop window posts for one chat turn.
##
## **It lives here rather than in `gui.nim` for the reason the branching tree walk
## lives in `api.nim`: nothing below the window could see it.** A request body
## that is subtly wrong does not fail to compile and does not fail a suite — it
## fails at the server, at runtime, in front of the USER. Continue shipped twice
## broken because the body was built inside the GUI where no self-test could
## reach it. `pipeline-selftest` now asserts this directly.
##
## Three of the four keys are requests for data `llama-server` will not send
## unless asked, and none of them changes what the model generates:
##
## * `timings_per_token` — attach `timings` to **every** chunk rather than only
##   the last, so the token counts and rate on screen are live (G-33).
## * `reasoning_format` — `"auto"` splits a reasoning model's thinking into
##   `reasoning_content` instead of leaving it inline in the answer (G-39). The
##   Developer setting turns it to `"none"`.
##
## **`continuing` needs both of its fields.** `continue_final_message` on its own
## is refused with *"Cannot set both add_generation_prompt and
## continue_final_message to true"* (HTTP 400) — the generation prompt has to be
## turned off explicitly as well, or the template closes the assistant turn and
## the model starts a fresh answer instead of extending the one it is given.
## Verified against a running server, not read out of the schema (**D-BH**).
##
## Action purpose: **the settings merge happens last and it is the reason this
## proc takes them at all** (G-31). The sampling and penalty parameters are only
## ever a JSON field on this body — `llama-server` accepts every one of them per
## request (**D-AF**) and `prepare` passes unknown top-level keys through
## untouched — so putting the merge here makes the whole feature assertable
## without a window and without a generation.
proc chatBody*(messages: JsonNode, continuing = false,
               opts = settings.initSettings(), wsContext = ""): string =
  # G-43: the workspace's notes and files, injected the way the Web UI's own
  # client injects them — into the system message, under the heading it uses.
  # It goes in here and not in `prepare` because `prepare` is handed a body and
  # never learns which conversation it belongs to, and because the Web UI does
  # this client-side too: its `chat.service.ts` builds the block before the
  # request leaves. Doing it here keeps it assertable with no window.
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
    # `"content"` and not `true`: what is being resumed is the visible answer,
    # never the reasoning.
    req["continue_final_message"] = %"content"
    req["add_generation_prompt"] = %false
  # After the fixed fields, so `custom` can override any of them deliberately,
  # and before serialisation so nothing downstream has to re-parse.
  settings.applyTo(req, opts)
  $req

## G-35. A generation can fail in ways that need different answers from the
## USER, and the desktop application put all of them into one grey line — "the
## server answered 500" was the whole diagnosis. These are the distinctions the
## Web UI's `DialogChatError` draws, and they live here rather than in `gui.nim`
## because a classifier is pure and a window is not needed to assert it.
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

## Action purpose: pull the two numbers out of llama.cpp's own overflow message,
## `"request (N tokens) exceeds the available context size (M tokens)"`. They
## are the whole value of that error — "too long" is not actionable, "9,412 of
## 8,192" tells the USER to start a new chat or raise the context.
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

## Function purpose: turn an HTTP status and whatever body came with it into
## something worth putting on screen. `exceptionMsg` carries the transport
## failure when there was no response at all.
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
    # Action purpose: 502 is what Jenova's own proxy answers when nothing is
    # behind it, and 503 is llama-server still loading. Both mean "not ready",
    # and both are worth retrying — unlike every other error here.
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
  else:
    ChatError(kind: cekServerError, retryable: true, detail: serverMsg,
      message: (if serverMsg.len > 0:
                  "the server failed: " & serverMsg
                else: "the server answered " & $status))

## G-30, attachments. **The shape is the frozen Web UI's, not a new one**
## (D-Z): a message's `extra` column holds a JSON array of typed attachments —
## `IMAGE`, `TEXT`, `PDF`, `AUDIO`, and the legacy `context` the old web UI
## wrote — and this turns them into the OpenAI content parts `llama-server`
## reads. Reproduced from `jca_web/src/lib/services/chat.service.ts:820-935`,
## **including the order**, because a request that differs from the one the Web
## UI sends against the same conversation is not parity.
##
## It lives here rather than in `gui.nim` for the reason `chatBody` does: the
## request body is the thing that was got wrong twice, and this way a self-test
## can see it.

proc attachmentText*(label, name, content: string): string =
  ## `formatAttachmentText` in `jca_web/src/lib/utils/formatters.ts:147`.
  "\n\n--- " & label & ": " & name & " ---\n" & content

## Function purpose: the `content` field for one outbound turn. A turn with no
## attachments keeps a **plain string**, exactly as before — the array form is
## only used when it is needed, because switching every message to parts would
## change every request this program has ever sent for no reason.
proc contentFor*(text: string, extra: JsonNode): JsonNode =
  if extra.isNil or extra.kind != JArray or extra.len == 0:
    return %text

  var parts = newJArray()
  if text.len > 0:
    parts.add %*{"type": "text", "text": text}

  proc ofType(t: string): seq[JsonNode] =
    for e in extra:
      if e.kind == JObject and e{"type"}.getStr("") == t: result.add e

  # Images first, then text, then audio, then PDFs — the Web UI's order.
  for img in ofType("IMAGE"):
    parts.add %*{"type": "image_url",
                 "image_url": {"url": img{"base64Url"}.getStr("")}}

  for f in ofType("TEXT"):
    parts.add %*{"type": "text",
                 "text": attachmentText("File", f{"name"}.getStr(""),
                                        f{"content"}.getStr(""))}

  # The old web UI stored pasted text as `context`; a conversation imported from
  # it still carries them, and dropping them would silently lose content the
  # user attached (D-Z).
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
    # A PDF reaches the model as page images when it was rasterised, and as
    # extracted text otherwise. Jenova writes neither yet — but a conversation
    # imported from the Web UI carries both, and this is what sends them back.
    if p{"processedAsImages"}.getBool(false) and p{"images"} != nil and
       p{"images"}.kind == JArray:
      for img in p{"images"}:
        parts.add %*{"type": "image_url", "image_url": {"url": img.getStr("")}}
    else:
      parts.add %*{"type": "text",
                   "text": attachmentText("PDF file", p{"name"}.getStr(""),
                                          p{"content"}.getStr(""))}
  parts

## G-30, the attachment classifier. **Here rather than in `gui.nim`** for the
## standing reason: a decision that can be made below the widget layer is made
## there and asserted, and this one governs what the model is asked to look at.
## It also has to be callable from inside the window's own timer, where a proc
## taking the GUI's state type does not yet exist.
type
  Attachment* = object
    ## `kind` is the Web UI's `AttachmentType` string — `IMAGE` or `TEXT` —
    ## because that is what goes into the `messages.extra` row (D-BP).
    kind*: string
    name*: string
    ## An `IMAGE` carries a `data:` URL; a `TEXT` carries the file's text.
    payload*: string
    bytes*: int
    ## G-40. **The identity of this attachment, and never a digest of its
    ## content.** The window caches a decoded thumbnail per attachment, and the
    ## cache key has to be derivable on every frame — so it must not be
    ## something that costs a pass over the payload to compute. Hashing the
    ## payload to build the key is exactly what froze the GUI: the decode was
    ## cached and the key was not, so a multi-megabyte SHA-256 ran on every
    ## redraw. Set once, at the point the attachment is created.
    key*: string

const
  ## The image types `llama-server`'s multimodal projector accepts. Anything
  ## else readable as text is attached as text; anything else at all is refused
  ## with a reason, rather than sent as bytes the model cannot look at.
  ImageExts* = [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"]

  ## D-BQ. **An attachment over this is refused, never truncated.** A shortened
  ## document changes what the model was asked about while still looking like it
  ## worked, which is the same defect as sending an unset parameter as a zero
  ## (D-BK) — the reply comes back confident and is about a fragment. Measured on
  ## the file as read, before base64 expansion, and applied to every kind.
  MaxAttachmentBytes* = 25 * 1024 * 1024

## Function purpose: is this file text? Decided by **reading it**, not by its
## extension — a `.log`, a `.conf` and a file with no extension at all are all
## attachable, and a list of known suffixes would refuse them.
##
## Action purpose: a NUL byte is the test, because that is what actually breaks
## the request — JSON cannot carry one, and every binary format has them within
## the first few KiB while no text encoding does.
proc looksTextual*(data: string): bool =
  let sample = if data.len > 8192: data[0 ..< 8192] else: data
  for ch in sample:
    if ch == '\0': return false
  true

proc mimeForImage*(ext: string): string =
  case ext.toLowerAscii
  of ".png": "image/png"
  of ".webp": "image/webp"
  of ".gif": "image/gif"
  of ".bmp": "image/bmp"
  else: "image/jpeg"

## Function purpose: `file:///home/x/a%20b.png` is a URI, not a path — this is
## what a drag-and-drop delivers. Undoing the percent-encoding is required, not
## cosmetic: a dropped file whose name contains a space would otherwise fail to
## open, and that is most screenshots.
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

## Function purpose: read one file and decide what it can be attached as (G-30).
## Shared by the file picker and the drop target, so the two cannot disagree.
##
## `visionKnown` is whether `/props` has answered yet. **Refusing an image on an
## unknown is the same defect as accepting one the model cannot read**, so an
## unanswered `/props` allows the attachment.
proc readAttachment*(path: string, visionKnown, visionOk: bool):
    tuple[ok: bool, att: Attachment, err: string] =
  let name = path.extractFilename

  # D-BQ, G-40. **The size is checked before the file is read, not after.**
  # Reading first and refusing afterwards would still pull the whole file into
  # memory, which is the cost the cap exists to prevent — a 2 GB file would hang
  # the window on `readFile` no matter what the check then decided.
  var size = 0'i64
  try:
    size = getFileSize(path)
  except CatchableError as e:
    return (false, Attachment(),
            "could not read " & name & ": " & e.msg)
  if size > MaxAttachmentBytes:
    # Action purpose: the file's size is rounded **up**. Truncating division
    # reported a 25.001 MB file as "is 25 MB and the limit is 25 MB", which
    # tells the reader nothing and reads like a bug in the check rather than a
    # file that is too big. Anything over the cap now always prints as more.
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

  # G-40: identity, not content. Name, size and mtime distinguish two staged
  # files without a pass over either one's bytes. Two attachments of the *same*
  # file are genuinely the same picture and may share a cached thumbnail.
  var stamp = ""
  try: stamp = $getLastModificationTime(path).toUnix
  except CatchableError: discard
  let key = name & ":" & $size & ":" & stamp

  if ext in ImageExts:
    if visionKnown and not visionOk:
      return (false, Attachment(), name &
        " is an image, and the loaded model cannot see images. " &
        "Load a vision model to attach it.")
    return (true, Attachment(kind: "IMAGE", name: name,
      payload: "data:" & mimeForImage(ext) & ";base64," & base64.encode(data),
      bytes: data.len, key: key), "")

  if not looksTextual(data):
    return (false, Attachment(),
            name & " is not text and is not an image Jenova can attach.")

  result = (true, Attachment(kind: "TEXT", name: name, payload: data,
                             bytes: data.len, key: key), "")

## Function purpose: read a stored `messages.extra` back into attachments.
## **Moved out of `gui.nim` for G-40**, where it was called from inside `view`
## and so re-parsed every payload on every frame; below the widget layer it is
## both cheap to call once and assertable, which the widget version was not.
##
## The stored shape is the frozen Web UI's (D-BP), so this is where its field
## names become the two kinds this program renders.
## The reduction from the stored node to what the transcript can draw. **Lossy on
## purpose:** a `PDF` becomes its extracted text and an `AUDIO` is dropped,
## because neither is something this window renders — the *request* path keeps
## the original node and sends both (D-BP), which is why `ParseMemo` holds each.
proc attachmentsOfNode*(node: JsonNode): seq[Attachment] =
  if node.isNil or node.kind != JArray: return
  # `for i, e in node` is not available here: on a `JArray` that resolves to
  # `pairs`, which asserts the node is an object and aborts the process.
  var i = -1
  for e in node:
    inc i
    if e.kind != JObject: continue
    # G-40: the identity of a *stored* attachment is its position in the row it
    # came from. Stable, unique, and — the point — free to compute.
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

## Function purpose: the same reduction straight from the stored text, for the
## callers that have no message id to memoise against.
proc parseAttachments*(extra: string): seq[Attachment] =
  if extra.len == 0: return
  var node: JsonNode
  try: node = parseJson(extra) except CatchableError: return
  attachmentsOfNode(node)

type
  ParseMemo* = object
    ## G-40. **`view` runs on every frame and must never do work proportional to
    ## a payload.** This holds one parse of a message's `extra` so that the
    ## frame does a table lookup instead.
    ##
    ## **Both forms are kept from the same parse, and that is deliberate.** The
    ## transcript needs `seq[Attachment]`, which is lossy — it collapses `PDF`
    ## to text and drops `AUDIO`, because those are things this window cannot
    ## draw. The outbound request needs the **original node**, because
    ## `contentFor` sends PDF page images and audio parts that an imported Web
    ## UI conversation carries (D-BP). Deriving the request from the lossy form
    ## would silently drop them from what the model is sent.
    ##
    ## `parses` is not diagnostic decoration and is not to be removed: it is the
    ## only thing in this program that can *assert* the fix. A per-frame cost
    ## reintroduced later is invisible to every other check — it compiles, it
    ## passes, it renders correctly, and it is only discovered when the window
    ## stops responding. `attach-selftest` asserts a hundred lookups parse once.
    nodes: Table[string, JsonNode]
    atts: Table[string, seq[Attachment]]
    stamps: Table[string, int]
    parses*: int

## Function purpose: parse one message's `extra` at most once, returning both the
## original node for the request path and the renderable list for the transcript.
##
## `id` is the message row id. **A message with no id is never memoised** — an
## assistant turn is a live buffer while it streams and only becomes a row when
## it completes, so caching it would pin the first token on screen. The stamp is
## the payload's length, which catches the one way a saved row still changes:
## Continue extends it, and an append always changes the length.
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
    memo.nodes[id] = node
    memo.atts[id] = atts
    memo.stamps[id] = extra.len
  (node, atts)

proc attachmentsFor*(memo: var ParseMemo, id, extra: string): seq[Attachment] =
  memo.entryFor(id, extra).atts

## The `extra` as the request path needs it — the original node, unreduced.
proc extraNodeFor*(memo: var ParseMemo, id, extra: string): JsonNode =
  memo.entryFor(id, extra).node

proc forget*(memo: var ParseMemo, id: string) =
  memo.nodes.del(id)
  memo.atts.del(id)
  memo.stamps.del(id)
