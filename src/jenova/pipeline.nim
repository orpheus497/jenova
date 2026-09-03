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
    trimmed*: int          ## T-3: oldest turns dropped to fit the context budget

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
## T-3. The byte budget a conversation's messages must fit into, or 0 for no
## trimming. Module state set once at start-up, the same arrangement as
## `configureEditor`, because `prepare` is handed a body and never learns which
## configuration it belongs to.
var historyBudget = 0

## Function purpose: set the history budget from the deployment's own context
## size (T-3). Called once at start-up by each entry point.
##
## Action purpose: **the conversion is an approximation and is stated as one
## rather than hidden.** `CTX_SIZE` is a token count shared across `NUM_SLOTS`
## parallel slots — the per-slot figure is what a turn actually gets, which is
## why `gui.nim` reads it from `/props` rather than from the config. Here there
## is no `/props`, so the per-slot share is derived, converted at four bytes per
## token, and halved to leave room for the reply and for the context blocks
## `injectSystem` adds after this budget was computed.
##
## An exact answer needs the model's own tokenizer, which is an HTTP round trip
## per turn on the hot path. **A rough bound that always leaves headroom beats an
## exact one nobody can afford**, and the failure it prevents — a conversation
## that grows until every request is refused — is not a subtle one.
proc configureHistoryBudget*(ctxSize, slots: int) =
  if ctxSize <= 0: return
  let perSlot = ctxSize div max(1, slots)
  historyBudget = perSlot * 4 div 2

const
  ## A-3. What an image part is **assumed** to cost the context, in the same
  ## four-bytes-per-token currency `configureHistoryBudget` works in.
  ##
  ## A picture becomes a fixed number of embedding tokens once the projector has
  ## run — a few hundred for the projectors `llama-server` ships — and **nothing
  ## about that number is proportional to the base64 that carried it.** 1,024
  ## tokens is a deliberate overestimate: too high spends a little history that
  ## did not need spending, too low is the defect this constant exists to
  ## prevent.
  ImageContextBytes* = 1024 * 4

  ## The `role`, the braces and the key names — what a message costs before any
  ## of its content does. Small, fixed, and counted so that a conversation of
  ## many tiny turns is not measured as though it were free.
  MessageEnvelopeBytes* = 16

## Function purpose: what one message costs the context, in the byte currency
## `configureHistoryBudget` sets the budget in.
##
## **This is not `($m).len`, and that is the whole point (A-3).** Measuring the
## serialised message counted an image's base64 payload — megabytes of
## transport standing in for a few hundred tokens of context. One screenshot
## therefore exceeded any budget by itself, and `trimHistory` responded the only
## way it could: it dropped every earlier turn trying to get under a figure the
## final turn alone could never meet. **The user saw the model forget the
## conversation the moment they attached a picture**, with nothing on screen to
## explain it.
##
## The four-bytes-per-token conversion above this is declared as an
## approximation and it is a fair one for text. Base64 breaks it completely, so
## the payload is not measured at all — the part is charged a flat
## `ImageContextBytes` instead.
proc messageWeight*(m: JsonNode): int =
  if m.kind != JObject: return ($m).len
  result = MessageEnvelopeBytes
  let content = m{"content"}
  if content.isNil: return
  case content.kind
  of JString:
    result += content.getStr.len
  of JArray:
    # The part shapes are `contentFor`'s own, which are the frozen Web UI's
    # (D-Z): `text`, `image_url`, `input_audio`. An unrecognised part is charged
    # its serialisation, because an unknown shape is exactly the case where
    # guessing low is how this defect happened in the first place.
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

## Function purpose: drop the oldest turns until a conversation fits a byte
## budget, and answer how many went (T-3). **The whole history was resent on
## every turn with no trim anywhere**, so a long chat eventually exceeded the
## context window and every further request failed.
##
## Two things are never dropped, and they are the reason this is a function
## rather than a slice:
##
## * **A `system` message.** It carries the persona, and the retrieval and
##   workspace blocks injected into it — dropping it changes who is answering.
## * **The final message.** It is the turn being asked about; a request that
##   drops it is a request about nothing.
##
## Oldest first, because the recent turns are the ones the next answer depends
## on. **Content is never shortened** — a truncated message reads as a working
## one while meaning something the user did not write, which is D-BQ's ruling on
## oversized attachments applied to the same hazard.
proc trimHistory*(messages: JsonNode, budgetBytes: int): int =
  if budgetBytes <= 0 or messages.kind != JArray or messages.len <= 1:
    return 0
  var total = 0
  for m in messages:
    total += messageWeight(m)
  if total <= budgetBytes: return 0

  var i = 0
  # `messages.len - 1` keeps the final turn whatever happens. `i` does not
  # advance on a delete: the next candidate shifts down into the same slot.
  while total > budgetBytes and i < messages.len - 1:
    let m = messages[i]
    if m.kind == JObject and m{"role"}.getStr == "system":
      inc i
      continue
    total -= messageWeight(m)
    messages.elems.delete(i)
    inc result

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

  # T-3. **Here, and outside the block above, deliberately.** Every request
  # passes through this line — the window posts to the same local :8080 as the
  # Web UI does, so one call covers both surfaces, which is the arrangement the
  # retrieval feed settled on (D-BI). Inside the block it would run only on a
  # turn that was not already carrying a context marker, so a long conversation
  # would stop being trimmed exactly when it most needed to be.
  #
  # After `injectSystem`, because the system message is what that grows, and the
  # budget is measured against what is actually sent.
  result.trimmed = trimHistory(messages, historyBudget)

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

const
  MaxCacheEntries* = 256
    ## 12d-4, and it is **new product behaviour the USER approved explicitly**
    ## (D-CJ) rather than part of the defect fix. Before 12d the writer had no
    ## caller, so `llm_cache` was empty by construction and its total absence of
    ## any `DELETE` anywhere in `src/` cost nothing. Wiring the writer turns it
    ## into a table that grows without bound inside the USER's own database, and
    ## the rows are whole model replies rather than short values.
  MaxCacheEntryBytes* = 1024 * 1024
    ## One reply. Past this the entry is simply not cached: a cache exists to
    ## save a round trip, not to become the largest table in the database.

## Function purpose: is this body one the streaming reader can actually replay?
##
## **This is D-CD's warning as a testable predicate.** `pipeline.prepare` posts
## `"stream": true` and `gui.streamOnce` acts only on lines beginning `data:`,
## stopping at `[DONE]`. So a cache hit answered as a plain JSON object carries
## no `data:` lines at all: the reader renders nothing and saves a blank
## assistant turn. Storing only what can be replayed is what stops a cache hit
## being worse than a cache miss.
##
## It is **not** enforced inside `cacheStore`, deliberately (D-CK): the cap is
## shared policy and belongs on the storage primitive, while "must be replayable
## as a stream" is an invariant of the completion path alone. The only other
## writer, `POST /api/db/cache`, stores plain values — `tests/test_api_db.sh`
## round-trips a bare string through it — and a shape rule buried in the shared
## proc would turn that suite red for a policy decision in the wrong layer.
proc isReplayableStream*(body: string): bool =
  body.contains("\ndata:") or body.startsWith("data:")

proc cacheStore*(key, response: string) =
  if key.len == 0 or response.len == 0: return
  if response.len > MaxCacheEntryBytes: return
  try:
    db.exec("INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) " &
            "VALUES (?, ?, strftime('%s','now'))", key, response)
    # Action purpose: evict oldest-first, which is what finally gives the
    # `timestamp` column a reader — it has been written by both writers since
    # the schema was created and read by nothing but the GET route. The delete
    # is by rowid out of a subselect rather than by a bare LIMIT, because
    # SQLite is not built with `SQLITE_ENABLE_UPDATE_DELETE_LIMIT` by default
    # and `DELETE … ORDER BY … LIMIT` would raise a syntax error at runtime,
    # inside a `try` that discards it — a silent no-op eviction.
    #
    # `rowid` is the tiebreak and it is load-bearing, not decoration:
    # `timestamp` is `strftime('%s','now')`, i.e. **one-second resolution**, and
    # a burst of turns inside one second would otherwise evict in an arbitrary
    # order — dropping a reply that had just been stored while keeping an older
    # one. SQLite gives this table an implicit rowid (it is not `WITHOUT
    # ROWID`), and `INSERT OR REPLACE` assigns a fresh one, so a refreshed entry
    # correctly counts as the newest. That is the same one-second-resolution
    # trap `fssync.epochPrefix` carries, met in a second place.
    db.exec("DELETE FROM llm_cache WHERE cache_key IN (" &
            "  SELECT cache_key FROM llm_cache" &
            "  ORDER BY timestamp DESC, rowid DESC" &
            "  LIMIT -1 OFFSET ?)", $MaxCacheEntries)
  except CatchableError:
    discard

## Function purpose: how many entries the cache is holding. Exported for the
## assertion and nothing else, the same way `db.cachedStatements` is.
proc cacheCount*(): int =
  try:
    let rows = db.query("SELECT COUNT(*) FROM llm_cache")
    if rows.len > 0 and rows[0].len > 0: parseInt(rows[0][0]) else: 0
  except CatchableError:
    0

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
  of 413:
    # A-4. **Not retryable, for the same reason an overflow is not:** the
    # identical body would be sent again and refused identically, so a Retry
    # button here would be a lie. The remedy is the USER's — send fewer or
    # smaller attachments — so it is named rather than implied.
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

  ## The bytes of a request body that are not the attachment: the JSON envelope,
  ## the persona, the retrieval and workspace blocks, and whatever history
  ## survived the trim. Kilobytes in practice; a megabyte is a deliberate
  ## overestimate, because being wrong in this direction costs a little capacity
  ## and being wrong in the other direction is A-4 again.
  RequestEnvelopeReserve* = 1024 * 1024

  ## D-BQ. **An attachment over this is refused, never truncated.** A shortened
  ## document changes what the model was asked about while still looking like it
  ## worked, which is the same defect as sending an unset parameter as a zero
  ## (D-BK) — the reply comes back confident and is about a fragment. Measured on
  ## the file as read, before base64 expansion, and applied to every kind.
  ##
  ## **Derived from `http.MaxBodyBytes` rather than chosen beside it (A-4).** It
  ## was a flat 25 MiB against a 32 MiB body cap, and the two were measured on
  ## different sides of base64 — the file on disk here, the encoded
  ## `Content-Length` there. Base64 expands by 4/3, so the two crossed at 24 MiB
  ## and a 24.5 MiB image passed this check and was then refused as a request,
  ## with nothing on screen to say why. Dividing the body cap by that same 4/3
  ## is what makes "accepted here" mean "sendable there".
  ##
  ## **The guarantee is per attachment, not per request.** Several attachments
  ## that each pass can still exceed the body cap together; that path is now the
  ## typed 413 `server.classWorker` answers, not an untyped 500.
  MaxAttachmentBytes* = (http.MaxBodyBytes - RequestEnvelopeReserve) * 3 div 4

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

  # Step 7b, closed 2026-09-02: a PDF is attached as its extracted text. It is
  # tried before `looksTextual` because a PDF is binary and that test refuses it.
  #
  # Action purpose: **no text means refuse, never attach an empty document.** A
  # scanned page carries images and no text objects, and an empty attachment
  # would look exactly like a working one while the model answered about nothing
  # — the same defect as a truncated file (D-BQ) and an unset value sent as zero
  # (D-BK).
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

## Function purpose: what Copy should put on the clipboard for one turn, given
## the `copyTextAttachmentsAsPlainText` setting (W-01).
##
## Action purpose: **the setting was drawn, validated, saved and read by
## nothing.** `settings.nim` marked it `awaiting: "attachments — PLANS.md Step
## 7b (G-30)"`, and attachments shipped in full; the blocker it named had not
## existed for some time, so a user turning it on got no behaviour change and no
## indication why.
##
## The Web UI's "off" state is a format that can be pasted back *as*
## attachments. This window has no such format — there is nothing to paste back
## into — so off is the plain message text, which is what Copy has always put on
## the clipboard, and on appends each text attachment under the same header
## `contentFor` gives the model. That keeps the two readings of the message
## identical: what you paste is what the model was shown.
##
## Images are skipped in both states: a base64 data URL is not something a
## clipboard paste can use, and it is the largest string in the turn.
##
## Below the widget layer so it can be asserted without a window, for the reason
## `chatBody` and `contentFor` are.
proc copyTextFor*(text: string, atts: seq[Attachment], plain: bool): string =
  result = text
  if not plain: return
  for a in atts:
    if a.kind == "IMAGE": continue
    if a.payload.len == 0: continue
    result.add attachmentText("File", a.name, a.payload)

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
    ## M-01. Insertion order of the ids held, so the oldest can be dropped when
    ## the memo is over its cap. Only a *new* id is appended; a re-parse under
    ## an existing id replaces its entry without moving it.
    order: seq[string]
    parses*: int

const ParseMemoCap* = 128
  ## M-01. How many messages' parsed `extra` the memo may hold.
  ##
  ## **This memo was unbounded, was never cleared, and is the expensive one.**
  ## `nodes` retains the whole `extra` array — *including every image's full
  ## base64 data URL* — and `atts` retains a **second** copy of the same bytes
  ## in `Attachment.payload`. It is a module-level `var` in `gui.nim` keyed by
  ## message id, and neither `loadConversation` nor `selectConversation` nor
  ## `deleteMessage` touched it, so a session that read ten conversations with a
  ## few megabytes of images each held all of it until the process exited —
  ## twice over, plus a decoded `Pixbuf` in the window's thumbnail cache and a
  ## file under `var/cache`.
  ##
  ## The cap is lower than `markdown.BlockMemoCap` because an entry here is
  ## unboundedly larger: parsed markdown is proportional to the message text,
  ## while this is proportional to whatever was attached to it. 128 is still far
  ## more than one branch of one conversation, so the per-frame guarantee
  ## `entryFor` exists to provide is untouched.

## Function purpose: drop the oldest entries once the memo is over its cap. A
## batch rather than one per insert, for the reason `markdown.evict` gives: a
## per-insert `delete(0)` is an O(n) shift on a path that must do no work
## proportional to anything.
proc evict(memo: var ParseMemo) =
  if memo.order.len <= ParseMemoCap: return
  let drop = max(1, ParseMemoCap div 4)
  for i in 0 ..< drop:
    memo.nodes.del(memo.order[i])
    memo.atts.del(memo.order[i])
    memo.stamps.del(memo.order[i])
  memo.order = memo.order[drop .. ^1]

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
    if not memo.atts.hasKey(id):
      memo.order.add id
      memo.evict()
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

## Function purpose: drop everything (M-01). Switching conversation makes every
## entry here dead — the transcript draws one branch — and nothing dropped them.
proc clear*(memo: var ParseMemo) =
  memo.nodes.clear()
  memo.atts.clear()
  memo.stamps.clear()
  memo.order.setLen(0)

## Function purpose: how many entries are held. For the assertion, so a cap that
## stops working fails a test rather than leaking quietly.
proc len*(memo: ParseMemo): int = memo.atts.len
