## Script function and purpose: web search for the `Web Search:` intent.
## DuckDuckGo HTML first because it gives general results, then the Instant
## Answer API because it gives better factual ones. HTTPS is delegated to
## `fetch(1)` rather than `std/httpclient`, which would link OpenSSL into a
## project that otherwise needs no TLS stack. Runs on a worker thread and is
## bounded at ~13s, only ever on an explicit user intent.

import std/[strutils, json, osproc, os, uri, strformat, streams]

const
  HtmlTimeout = 8
  ApiTimeout = 5
  MaxResults = 5

## Function purpose: an empty string is a supported answer, not a failure — the
## caller says something different for "no client" than for "no results".
proc httpsClient*(): string =
  for candidate in ["fetch", "curl"]:
    if findExe(candidate).len > 0:
      return candidate
  ""

## Function purpose: hides the two clients' incompatible flag spellings, so the
## search paths below never branch on which one is installed.
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

## Function purpose: handles the markup of one endpoint and is not a general
## HTML parser; the entity list is what DuckDuckGo actually emits.
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

## Function purpose: a hand-written scan because a regex dependency is not worth
## one call site.
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

## Function purpose: the preferred path — titles and snippets are paired by
## position, so a result missing either half is dropped rather than mismatched.
## Function purpose: one result is a title and a snippet at the same position,
## so the two are validated together and a bad half discards the whole pair.
##
## Filtering the two lists separately and pairing them afterwards is what this
## replaces: a result whose snippet was too short vanished from `snippets` alone,
## and every later snippet then moved up one title. The first weak result silently
## mislabelled all the rest.
proc pairResults*(titles, snippets: seq[string]): seq[string] =
  for i in 0 ..< min(titles.len, snippets.len):
    if result.len >= MaxResults: break
    # A snippet of ten characters or fewer is DuckDuckGo's empty cell, not text.
    if titles[i].len == 0 or snippets[i].len <= 10: continue
    result.add &"[{result.len + 1}] {titles[i]}\n    {snippets[i]}"

## Function purpose: the preferred path — titles and snippets are paired by
## position, so a result missing either half is dropped rather than mismatched.
proc ddgHtmlSearch(query: string): seq[string] =
  let url = "https://html.duckduckgo.com/html/?q=" & encodeUrl(query)
  let html = fetchUrl(url, HtmlTimeout)
  if html.len < 100: return @[]

  var titles, snippets: seq[string]
  for raw in extractAll(html, "class=\"result__a\"", "</a>"):
    titles.add stripHtml(raw)
  for raw in extractAll(html, "class=\"result__snippet\"", "</a>"):
    snippets.add stripHtml(raw)
  pairResults(titles, snippets)

## Function purpose: the fallback, used when the HTML endpoint yields nothing.
proc ddgInstantAnswer(query: string): seq[string] =
  let url = "https://api.duckduckgo.com/?q=" & encodeUrl(query) &
            "&format=json&no_html=1&skip_disambig=1"
  let raw = fetchUrl(url, ApiTimeout)
  if raw.len < 10: return @[]

  var data: JsonNode
  try: data = parseJson(raw)
  except CatchableError: return @[]
  if data.kind != JObject: return @[]

  # Action purpose: `AbstractText` is the API's name for a direct answer, such
  # as a Wikipedia summary, and outranks the related topics below it.
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
      # Action purpose: related topics carry no title field, so one is cut from
      # the text at the separator DuckDuckGo uses, or by length when absent.
      var title = text
      let dash = text.find(" -")
      if dash > 0: title = text[0 ..< dash]
      elif text.len > 80: title = text[0 ..< 80]
      result.add &"[{result.len + 1}] {title}\n    " &
                 text[0 ..< min(300, text.len)]

## Function purpose: an empty result is not an error, and the caller keeps it
## distinct from having no HTTPS client at all.
proc search*(query: string): seq[string] =
  if httpsClient().len == 0: return @[]
  result = ddgHtmlSearch(query)
  if result.len > 0: return
  result = ddgInstantAnswer(query)

## Function purpose: the two failure messages are deliberately different. "The
## search found nothing" and "this host cannot search" lead the model to
## different, and differently honest, answers.
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
