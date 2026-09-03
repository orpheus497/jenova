## Script function and purpose: web search for the `Web Search:` intent,
## replacing `lib/proxy.lua:259-415`. DuckDuckGo HTML first, falling back to the
## Instant Answer API — HTML gives general results, the API gives good factual
## answers, and that order is the original's.
##
## **Why this still shells out to `fetch`.** `proxy.lua` used `fetch` or `curl`
## because LuaJIT had no TLS. Nim's `httpclient` needs OpenSSL linked in, which
## would be a new dependency on a project that has spent seven stages removing
## them — and FreeBSD's base `fetch(1)` already does HTTPS with no dependency at
## all. The subprocess is deliberate. It runs on a worker thread under D-S, so
## unlike the Lua original it blocks nothing but its own request.
##
## Called only on an explicit user intent, and bounded: 8s for HTML, 5s for the
## API, so ~13s worst case for a user-initiated action on a single-user system.

import std/[strutils, json, osproc, os, uri, strformat, streams]

const
  HtmlTimeout = 8
  ApiTimeout = 5
  MaxResults = 5

## Function purpose: pick the HTTPS client once. `fetch` is FreeBSD base and is
## preferred; `curl` is the fallback for a host that has it. Returning an empty
## string is a supported state — the caller emits a distinct message for "no
## client" versus "no results", because they tell the model different things.
proc httpsClient*(): string =
  for candidate in ["fetch", "curl"]:
    if findExe(candidate).len > 0:
      return candidate
  ""

proc fetchUrl(url: string, timeout: int): string =
  let client = httpsClient()
  if client.len == 0: return ""
  let args =
    case client
    of "fetch": @["-T", $timeout, "-qo", "-", url]
    of "curl": @["-sL", "--max-time", $timeout, url]
    else: return ""
  try:
    let p = startProcess(client, args = args, options = {poUsePath})
    defer: p.close()
    let output = p.outputStream.readAll()
    if p.waitForExit() != 0: return ""
    output
  except OSError, IOError:
    ""

## Function purpose: strip tags and decode the entities DuckDuckGo's HTML
## actually contains, matching `proxy.lua:strip_html`. Not a general HTML
## parser and not meant to be — it handles the specific markup of one endpoint.
proc stripHtml*(s: string): string =
  var text = newStringOfCap(s.len)
  var inTag = false
  for ch in s:
    if ch == '<': inTag = true
    elif ch == '>': inTag = false
    elif not inTag: text.add ch
  text = text.multiReplace(("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                           ("&quot;", "\""), ("&#x27;", "'"), ("&#039;", "'"),
                           ("&nbsp;", " "), ("\\n", " "), ("\r", " "),
                           ("\n", " "))
  text.strip()

## Function purpose: pull the text between a marker and a closing tag, repeatedly.
## Replaces the Lua pattern captures; written as a scan because Nim has no
## equivalent one-liner and a regex dependency is not worth one call site.
proc extractAll(html, marker, closing: string): seq[string] =
  var pos = 0
  while true:
    let m = html.find(marker, pos)
    if m < 0: break
    let gt = html.find('>', m)
    if gt < 0: break
    let close = html.find(closing, gt)
    if close < 0: break
    result.add html[gt + 1 ..< close]
    pos = close + closing.len

proc ddgHtmlSearch(query: string): seq[string] =
  let url = "https://html.duckduckgo.com/html/?q=" & encodeUrl(query)
  let html = fetchUrl(url, HtmlTimeout)
  if html.len < 100: return @[]

  var titles, snippets: seq[string]
  for raw in extractAll(html, "class=\"result__a\"", "</a>"):
    let clean = stripHtml(raw)
    if clean.len > 0: titles.add clean
  for raw in extractAll(html, "class=\"result__snippet\"", "</a>"):
    let clean = stripHtml(raw)
    if clean.len > 10: snippets.add clean

  let count = min(min(titles.len, snippets.len), MaxResults)
  for i in 0 ..< count:
    result.add &"[{i + 1}] {titles[i]}\n    {snippets[i]}"

proc ddgInstantAnswer(query: string): seq[string] =
  let url = "https://api.duckduckgo.com/?q=" & encodeUrl(query) &
            "&format=json&no_html=1&skip_disambig=1"
  let raw = fetchUrl(url, ApiTimeout)
  if raw.len < 10: return @[]

  var data: JsonNode
  try: data = parseJson(raw)
  except CatchableError: return @[]
  if data.kind != JObject: return @[]

  # AbstractText is a direct answer — a Wikipedia summary or similar.
  if data.hasKey("AbstractText"):
    let abstract = data["AbstractText"].getStr
    if abstract.len > 20:
      let source = if data.hasKey("AbstractSource"): data["AbstractSource"].getStr
                   else: "Summary"
      result.add &"[1] {source}\n    " & abstract[0 ..< min(500, abstract.len)]

  if data.hasKey("RelatedTopics") and data["RelatedTopics"].kind == JArray:
    for topic in data["RelatedTopics"]:
      if result.len >= MaxResults: break
      if topic.kind != JObject or not topic.hasKey("Text"): continue
      let text = topic["Text"].getStr
      if text.len <= 10: continue
      # The original takes everything before the first " - " as a title, and
      # falls back to the first 80 characters.
      var title = text
      let dash = text.find(" -")
      if dash > 0: title = text[0 ..< dash]
      elif text.len > 80: title = text[0 ..< 80]
      result.add &"[{result.len + 1}] {title}\n    " &
                 text[0 ..< min(300, text.len)]

## Function purpose: run a search, HTML first then the Instant Answer API.
## An empty result is not an error — the caller distinguishes it from "no HTTPS
## client available", and tells the model something different in each case.
proc search*(query: string): seq[string] =
  if httpsClient().len == 0: return @[]
  result = ddgHtmlSearch(query)
  if result.len > 0: return
  result = ddgInstantAnswer(query)

## Function purpose: the `--- WEB SEARCH RESULTS ---` block, including the two
## distinct failure messages from `proxy.lua:1282-1291`. The distinction is
## load-bearing: "the search found nothing" and "this host cannot search" lead
## the model to different, and differently honest, answers.
proc formatContext*(results: seq[string]): string =
  if results.len > 0:
    return "\n--- WEB SEARCH RESULTS ---\n" & results.join("\n")
  if httpsClient().len > 0:
    "\n--- WEB SEARCH RESULTS ---\nWeb search returned no results. " &
    "The search engine did not return matching results for this query. " &
    "Answer the user's question using your own knowledge and clearly state " &
    "that web search did not find any relevant results for this query."
  else:
    "\n--- WEB SEARCH RESULTS ---\nWeb search returned no results. " &
    "No HTTPS client available (install curl or use FreeBSD). Cannot perform " &
    "web searches. Answer the user's question using your own knowledge and " &
    "clearly state that web search was unavailable."
