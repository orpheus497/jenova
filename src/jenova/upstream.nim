## Script function and purpose: Streaming reverse proxy to the llama-server
## processes, replacing the forwarding half of `lib/proxy.lua`.
##
## Runs entirely on the calling worker thread with blocking I/O, which is what
## makes streaming simple here and was impossible in the Lua proxy: a completion
## can hold this function for the length of a generation without affecting any
## other connection, because no other connection shares this thread.
##
## Bytes are relayed verbatim in both directions. No buffering of the response
## body, so server-sent events reach the client as the model produces them
## rather than at the end.

import std/[net, nativesockets, posix, strutils, strformat, tables]
import ./http

const
  RelayChunk = 16 * 1024
  UpstreamConnectTimeoutMs = 5_000
  ## Generous on purpose, and still finite. A cold `llama-server` can take
  ## minutes to answer while it loads a multi-gigabyte model, so a short receive
  ## timeout would abort legitimate requests — but with no timeout at all a
  ## wedged upstream held this worker thread for the life of the process.
  ## Matches the `TIMEOUT` the profiles carry.
  UpstreamRecvTimeoutSec = 600

type UpstreamError* = object of CatchableError

## Function purpose: rebuild the client's request for the upstream, preserving
## method, target and body. Hop-by-hop headers are dropped and the connection is
## explicitly closed at the end of the response, because this proxy does not
## pool upstream connections.
proc buildRequest(req: Request, host: string, port: int): string =
  var target = req.path
  if req.query.len > 0:
    target.add "?" & req.query

  result = &"{req.meth} {target} HTTP/1.1\r\n"
  result.add &"Host: {host}:{port}\r\n"
  for k, v in req.headers:
    let lk = k.toLowerAscii
    # Hop-by-hop and framing headers are ours to set, not the client's to pass
    # through: a stale Content-Length or a keep-alive request would desynchronise
    # the relay.
    if lk in ["host", "connection", "content-length", "transfer-encoding",
              "keep-alive", "upgrade", "proxy-connection"]:
      continue
    result.add &"{k}: {v}\r\n"
  result.add "Connection: close\r\n"
  if req.body.len > 0:
    result.add &"Content-Length: {req.body.len}\r\n"
  result.add "\r\n"
  if req.body.len > 0:
    result.add req.body

## Function purpose: relay a request upstream and stream the reply straight back
## to the client. A refused connection is reported as 502 with the address that
## failed, because "the model backend is not running" is the single most common
## operational state and it should not look like a server bug.
## Function purpose: the one 502 this module answers with, named so the
## connect-failure path and the "upstream closed without sending anything" path
## cannot drift apart. Both are the same operational fact to the client.
proc sendUpstreamUnavailable(client: Socket, host: string, port: int) =
  client.sendResponse(502, "application/json",
    &"""{{"error":"upstream unavailable","upstream":"{host}:{port}",""" &
    &""""hint":"is llama-server running?"}}""")

proc forward*(client: Socket, req: Request, host: string, port: int): bool =
  var up: Socket
  try:
    up = newSocket(buffered = false)
    up.connect(host, port.Port, timeout = UpstreamConnectTimeoutMs)
  except CatchableError:
    if not up.isNil:
      try: up.close() except CatchableError: discard
    sendUpstreamUnavailable(client, host, port)
    return false

  defer:
    try: up.close() except CatchableError: discard

  # Action purpose: bound every `recv` below, the same way `server.setTimeouts`
  # bounds the client side. Without it an upstream that accepts the connection
  # and then stops speaking owns this worker thread indefinitely.
  var tv = Timeval(tv_sec: posix.Time(UpstreamRecvTimeoutSec), tv_usec: 0)
  discard setsockopt(up.getFd, SOL_SOCKET, SO_RCVTIMEO,
                     addr tv, SockLen(sizeof(tv)))

  up.send(buildRequest(req, host, port))

  # Verbatim relay. The response head is not parsed or rewritten: whatever
  # llama-server says about content type, chunking or SSE framing is what the
  # client should see.
  var chunk = newString(RelayChunk)
  var relayed = 0
  while true:
    let n = up.recv(addr chunk[0], chunk.len)
    if n <= 0:
      break
    # Action purpose: a single send() may accept fewer bytes than offered, and a
    # relay that ignores the count silently truncates the model's output
    # mid-stream. Loop until the chunk is fully written or the client goes away.
    var sent = 0
    while sent < n:
      let w = client.send(addr chunk[sent], n - sent)
      if w <= 0:
        return relayed > 0
      sent += w
    relayed += n

  # An upstream that accepted the connection and then closed without a byte —
  # a crash mid-load, a receive timeout — left the client with an empty reply
  # and no status at all, because the caller only closes the socket on `false`.
  # That is the same operational state as a refused connection, so it gets the
  # same answer. A partial relay still returns true: the response head is
  # already on the wire and cannot be replaced.
  if relayed == 0:
    sendUpstreamUnavailable(client, host, port)
    return false
  true
