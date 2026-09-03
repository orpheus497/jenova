## Script function and purpose: HTTP/1.1 request parsing and response writing,
## no more of the protocol than this server speaks. Blocking I/O is deliberate:
## every connection has its own pool thread, so a stall here costs one
## connection and never the server.

import std/[net, strutils, tables, os]

type
  Request* = object
    meth*: string
    path*: string
    query*: string
    headers*: Table[string, string]
    body*: string

  HttpError* = object of CatchableError

  ## Kept distinct from every other parse failure so the worker can answer 413.
  ## Folded into `HttpError` it becomes a bare 500, which tells the user nothing
  ## they can act on.
  BodyTooLargeError* = object of HttpError

const
  MaxHeadBytes = 64 * 1024

  ## Exported because `pipeline.MaxAttachmentBytes` derives from it rather than
  ## standing beside it as a second number. An attachment is measured before
  ## base64 and a body after it, so two independent caps disagree by the encoding
  ## overhead and a file passes one only to be refused by the other. This is the
  ## authoritative one because this is the buffer that has to hold the bytes.
  MaxBodyBytes* = 32 * 1024 * 1024

  ## How much of an over-sized body is drained before the refusal is raised.
  ## Generous so an ordinary sender finishes, bounded so a `Content-Length` that
  ## lies cannot hold a worker thread for ever.
  MaxDrainBytes = 96 * 1024 * 1024

## Function purpose: framing is done on the raw buffer because `recvLine` cannot
## distinguish the blank separator line from a closed connection. Body bytes
## that arrived in the same read are returned rather than dropped.
proc readHead(sock: Socket): (string, string) =
  var data = ""
  var chunk = newString(4096)
  while true:
    let n = sock.recv(addr chunk[0], chunk.len)
    if n <= 0:
      break
    data.add chunk[0 ..< n]
    let idx = data.find("\r\n\r\n")
    if idx >= 0:
      return (data[0 ..< idx], data[idx + 4 .. ^1])
    if data.len > MaxHeadBytes:
      raise newException(HttpError, "request head too large")
  if data.len == 0:
    raise newException(HttpError, "connection closed before request")
  raise newException(HttpError, "malformed request: no header terminator")

## Function purpose: reads only what this server acts on — method, target,
## headers, body. An unparseable request raises rather than yielding a partly
## filled `Request` that a caller might act on.
proc parseRequest*(sock: Socket): Request =
  let (head, leftover) = readHead(sock)
  let lines = head.split("\r\n")
  if lines.len == 0 or lines[0].len == 0:
    raise newException(HttpError, "empty request line")

  let parts = lines[0].split(' ')
  if parts.len < 2:
    raise newException(HttpError, "malformed request line: " & lines[0])
  result.meth = parts[0]

  let target = parts[1]
  let q = target.find('?')
  if q >= 0:
    result.path = target[0 ..< q]
    result.query = target[q + 1 .. ^1]
  else:
    result.path = target

  for i in 1 ..< lines.len:
    let line = lines[i]
    let c = line.find(':')
    if c > 0:
      result.headers[line[0 ..< c].strip.toLowerAscii] = line[c + 1 .. ^1].strip

  let clen = try: parseInt(result.headers.getOrDefault("content-length", "0"))
             except ValueError: 0
  if clen > MaxBodyBytes:
    # Action purpose: the body is drained before the refusal is raised, and the
    # 413 is worthless without it. `Content-Length` arrives with the head, so
    # this is decided while the sender is still writing, and closing on a peer
    # mid-write hands it a reset instead of the response — the client then
    # reports a connection failure and the reason never reaches the user.
    #
    # Discarded as it arrives rather than accumulated: the cap exists to keep
    # this body out of memory, and buffering it to drain it would defeat that.
    var drained = leftover.len
    var sink = newString(4096)
    while drained < clen and drained < MaxDrainBytes:
      let want = min(sink.len, min(clen, MaxDrainBytes) - drained)
      let n = sock.recv(addr sink[0], want)
      if n <= 0: break
      drained += n

    # Action purpose: both numbers are in the message because this is a failure
    # the user can act on, and the margin decides whether they drop an
    # attachment or start a new conversation.
    const Mib = 1024 * 1024
    raise newException(BodyTooLargeError,
      "request body is " & $((clen + Mib - 1) div Mib) &
      " MB and the limit is " & $(MaxBodyBytes div Mib) & " MB")
  result.body = leftover
  while result.body.len < clen:
    var chunk = newString(min(4096, clen - result.body.len))
    let n = sock.recv(addr chunk[0], chunk.len)
    if n <= 0: break
    result.body.add chunk[0 ..< n]

## Function purpose: decodes only the two escapes a query string uses, and
## leaves a malformed `%` sequence as literal text rather than raising — a bad
## parameter should not fail the request that carries it.
proc urlDecode*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    case s[i]
    of '+': result.add ' '; i.inc
    of '%':
      if i + 2 < s.len:
        try:
          result.add chr(parseHexInt(s[i+1 .. i+2]))
          i += 3
        except ValueError:
          result.add s[i]; i.inc
      else:
        result.add s[i]; i.inc
    else:
      result.add s[i]; i.inc

## Function purpose: absent and present-but-empty both answer empty; a caller
## that needs to tell them apart asks `hasParam`.
proc queryStr*(r: Request, key: string): string =
  for pair in r.query.split('&'):
    let e = pair.find('=')
    if e > 0 and pair[0 ..< e] == key:
      return urlDecode(pair[e + 1 .. ^1])
  ""

## Function purpose: presence without value, for the flag-style parameters
## where `?debug` and `?debug=` mean the same thing.
##
## Action purpose: the valueless form is the whole point of this proc and was
## the one form it missed. `find('=')` answers -1 for a bare `?debug`, and a
## test of `e > 0` reads that as absent — so the flag documented above as
## equivalent to `?debug=` was the only spelling that did not work. A pair with
## no `=` is the key itself; one with an `=` is the text before it.
proc hasParam*(r: Request, key: string): bool =
  for pair in r.query.split('&'):
    let e = pair.find('=')
    let name = if e >= 0: pair[0 ..< e] else: pair
    if name == key:
      return true
  false

## Function purpose: an unparseable number falls back to `default` rather than
## raising, because these are display and paging hints, not commands.
proc queryParam*(r: Request, key: string, default: int): int =
  let raw = r.queryStr(key)
  if raw.len == 0: default
  else:
    try: parseInt(raw) except ValueError: default

const StatusText = {
  200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
  405: "Method Not Allowed", 413: "Content Too Large",
  500: "Internal Server Error",
}.toTable

## Function purpose: `extraHeaders` must arrive CRLF-terminated per line; it
## carries `X-Cache: HIT`, which clients read, so it is contract rather than
## diagnostics. `headOnly` answers HEAD by computing the body and withholding
## it, which is what stops HEAD and GET drifting apart.
proc sendResponse*(sock: Socket, status: int, contentType, body: string,
                   extraHeaders = "", headOnly = false) =
  let reason = StatusText.getOrDefault(status, "Unknown")
  var head = "HTTP/1.1 " & $status & " " & reason & "\r\n"
  head.add "Content-Type: " & contentType & "\r\n"
  head.add "Content-Length: " & $body.len & "\r\n"
  if extraHeaders.len > 0:
    head.add extraHeaders
  head.add "Connection: close\r\n\r\n"
  sock.send(head)
  if body.len > 0 and not headOnly:
    sock.send(body)

## Function purpose: no `Content-Length` and `Connection: close`, because the
## body is open-ended and the socket closing is what terminates it.
proc beginSSE*(sock: Socket) =
  var head = "HTTP/1.1 200 OK\r\n"
  head.add "Content-Type: text/event-stream\r\n"
  head.add "Cache-Control: no-cache\r\n"
  head.add "Connection: close\r\n\r\n"
  sock.send(head)

## Function purpose: the blank line after the payload is the record separator,
## not padding — without it a client buffers the event indefinitely.
proc sendEvent*(sock: Socket, data: string) =
  sock.send("data: " & data & "\r\n\r\n")

const ContentTypes = {
  ".html": "text/html; charset=utf-8", ".js": "application/javascript",
  ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
  ".png": "image/png", ".jpg": "image/jpeg", ".ico": "image/x-icon",
  ".woff2": "font/woff2", ".map": "application/json",
}.toTable

## Function purpose: an unknown extension answers `application/octet-stream` so
## a browser downloads it rather than guessing at and executing it.
proc contentTypeFor*(path: string): string =
  ContentTypes.getOrDefault(path.splitFile.ext.toLowerAscii, "application/octet-stream")

## Function purpose: traversal is checked after normalisation rather than by
## scanning for `..`, which is bypassable by encoding.
proc resolveStatic*(root, reqPath: string): string =
  var rel = reqPath
  if rel.len == 0 or rel == "/": rel = "/index.html"
  if rel.startsWith("/"): rel = rel[1 .. ^1]
  let full = (root / rel).normalizedPath
  var rootNorm = root.normalizedPath
  while rootNorm.len > 1 and rootNorm.endsWith("/"):
    rootNorm = rootNorm[0 ..< ^1]
  # Action purpose: the trailing separator is required. A bare prefix match
  # accepts a sibling directory whose name merely starts with the root's —
  # `public-old` for a root of `public` — and serves out of it.
  if not (full == rootNorm or full.startsWith(rootNorm & "/")):
    raise newException(HttpError, "path escapes static root: " & reqPath)
  full
