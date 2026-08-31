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

import std/[json, strutils, tables]
import ./prompts
import ./rag
import ./websearch
import ./db
import ./sha256
import ./nvimctl

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

var editorSocket = ""

## Function purpose: tell the pipeline where Neovim is listening, the way
## `rag.configureEmbed` supplies the embedding server's address. Unset by
## default, which is why `Editor:` degrades to a plain answer on a host with no
## editor running rather than failing the turn.
proc configureEditor*(socket: string) =
  editorSocket = socket

# Written once at startup, read-only afterwards; the server's worker threads only
# read it.
proc editorSock(): string {.gcsafe.} =
  {.cast(gcsafe).}: editorSocket

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
    var content = messages[0]["content"].getStr
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
                                 messages[0]["content"].getStr)
    else:
      messages.elems.insert(%*{"role": "system", "content": systemPrompt}, 0)
    return

  # No intent: persona prepended, RAG appended.
  if hasSystem:
    var content = prompts.FreeChat & "\n\n" & messages[0]["content"].getStr
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
