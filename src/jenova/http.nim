## Script function and purpose: Minimal HTTP/1.1 request parsing and response
## writing over blocking sockets, replacing `lib/http.lua`. Blocking is
## deliberate: every connection is served by its own pool thread (see
## `server.nim`), so blocking here stalls one connection and nothing else.
##
## This is the opposite of `lib/proxy.lua`, where one non-blocking loop served
## every client and any stall was global.

import std/[net, strutils, tables, os]

type
  Request* = object
    meth*: string
    path*: string
    query*: string
    headers*: Table[string, string]
    body*: string

  HttpError* = object of CatchableError

const
  MaxHeadBytes = 64 * 1024
  MaxBodyBytes = 32 * 1024 * 1024

## Function purpose: read up to and including the header terminator, returning
## the head and whatever body bytes arrived in the same read. Nim's recvLine
## cannot distinguish a blank separator line from a closed connection, so the
## framing is done here rather than line by line.
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
    raise newException(HttpError, "request body too large")
  result.body = leftover
  while result.body.len < clen:
    var chunk = newString(min(4096, clen - result.body.len))
    let n = sock.recv(addr chunk[0], chunk.len)
    if n <= 0: break
    result.body.add chunk[0 ..< n]

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

## Function purpose: fetch a decoded query parameter. Returns an empty string
## when absent, which callers distinguish from a present-but-empty value by
## checking `hasParam` when the difference matters.
proc queryStr*(r: Request, key: string): string =
  for pair in r.query.split('&'):
    let e = pair.find('=')
    if e > 0 and pair[0 ..< e] == key:
      return urlDecode(pair[e + 1 .. ^1])
  ""

proc hasParam*(r: Request, key: string): bool =
  for pair in r.query.split('&'):
    let e = pair.find('=')
    if e > 0 and pair[0 ..< e] == key:
      return true
  false

proc queryParam*(r: Request, key: string, default: int): int =
  let raw = r.queryStr(key)
  if raw.len == 0: default
  else:
    try: parseInt(raw) except ValueError: default

const StatusText = {
  200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
  405: "Method Not Allowed", 500: "Internal Server Error",
}.toTable

## `extraHeaders` must already be CRLF-terminated per line. It exists for the
## cache path, which answers with `X-Cache: HIT` — `proxy.lua:1390` sets that
## header and the Web UI reads it, so it is contract rather than diagnostics.
## `headOnly` answers a HEAD request: identical headers, including the
## `Content-Length` the body would have had, with the body itself withheld.
## Computing the body and then dropping it is what keeps the two methods from
## drifting apart.
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

## Action purpose: open a Server-Sent Events stream. `Connection: close` and no
## Content-Length: the response body is open-ended and terminated by closing the
## socket. This is the path that must keep flowing while other threads are busy —
## the streaming stutter in the Lua proxy is the symptom this design targets.
proc beginSSE*(sock: Socket) =
  var head = "HTTP/1.1 200 OK\r\n"
  head.add "Content-Type: text/event-stream\r\n"
  head.add "Cache-Control: no-cache\r\n"
  head.add "Connection: close\r\n\r\n"
  sock.send(head)

proc sendEvent*(sock: Socket, data: string) =
  sock.send("data: " & data & "\r\n\r\n")

const ContentTypes = {
  ".html": "text/html; charset=utf-8", ".js": "application/javascript",
  ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
  ".png": "image/png", ".jpg": "image/jpeg", ".ico": "image/x-icon",
  ".woff2": "font/woff2", ".map": "application/json",
}.toTable

proc contentTypeFor*(path: string): string =
  ContentTypes.getOrDefault(path.splitFile.ext.toLowerAscii, "application/octet-stream")

## Function purpose: resolve a request path inside the static root, refusing
## anything that escapes it. Path traversal is checked after normalisation
## rather than by scanning for "..", which is bypassable.
proc resolveStatic*(root, reqPath: string): string =
  var rel = reqPath
  if rel.len == 0 or rel == "/": rel = "/index.html"
  if rel.startsWith("/"): rel = rel[1 .. ^1]
  let full = (root / rel).normalizedPath
  var rootNorm = root.normalizedPath
  while rootNorm.len > 1 and rootNorm.endsWith("/"):
    rootNorm = rootNorm[0 ..< ^1]
  # The boundary is required, not decoration: a bare prefix match accepts a
  # *sibling* directory whose name merely starts with the root's — `public-old`
  # for the root `public` — and serves it. This is the same rule
  # `fssync.resolveStoragePath` applies to the workspaces root.
  if not (full == rootNorm or full.startsWith(rootNorm & "/")):
    raise newException(HttpError, "path escapes static root: " & reqPath)
  full
