## Script function and purpose: streaming reverse proxy to the llama-server
## processes. Runs on the calling worker thread with blocking I/O, so a
## completion may hold this function for a whole generation without touching any
## other connection. Bytes are relayed verbatim and the response body is never
## buffered, which is what lets events reach the client as they are produced.

import std/[net, nativesockets, posix, strutils, strformat, tables]
import ./http

const
  RelayChunk = 16 * 1024
  UpstreamConnectTimeoutMs = 5_000
  ## Generous on purpose and still finite. A cold `llama-server` can take
  ## minutes while it loads a multi-gigabyte model, so a short timeout aborts
  ## legitimate requests; with none at all a wedged upstream owns this worker
  ## thread for the life of the process.
  UpstreamRecvTimeoutSec = 600

type UpstreamError* = object of CatchableError

type RelayOutcome* = enum
  ## Three states rather than a bool, because "some bytes reached the client"
  ## covers both a complete response and a client that walked away mid-stream.
  ## The response cache has to tell them apart: storing a truncated stream to
  ## replay later as a whole answer is confidently wrong about a fragment.
  roUnavailable   ## nothing relayed; this module has already answered 502
  roTruncated     ## the client went away mid-stream; the head is already sent
  roComplete      ## upstream closed after relaying a complete response

## Function purpose: rebuilt rather than forwarded verbatim because the framing
## headers are this proxy's to set; the connection is closed at the end of the
## response because upstream connections are not pooled.
proc buildRequest(req: Request, host: string, port: int): string =
  var target = req.path
  if req.query.len > 0:
    target.add "?" & req.query

  result = &"{req.meth} {target} HTTP/1.1\r\n"
  result.add &"Host: {host}:{port}\r\n"
  for k, v in req.headers:
    let lk = k.toLowerAscii
    # Action purpose: a stale `Content-Length` or an inherited keep-alive would
    # desynchronise the relay, so these are dropped and re-set below.
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

## Function purpose: the one 502 this module answers with, named so the
## connect-failure path and the "upstream closed saying nothing" path cannot
## drift apart — both are the same operational fact to the client. It carries
## the address, because a backend that is not running is the commonest state
## here and should not read as a server bug.
proc sendUpstreamUnavailable(client: Socket, host: string, port: int) =
  client.sendResponse(502, "application/json",
    &"""{{"error":"upstream unavailable","upstream":"{host}:{port}",""" &
    &""""hint":"is llama-server running?"}}""")

const MaxStatusLineProbe* = 512
  ## How many bytes the relay may hold back while waiting for the end of a
  ## status line. Ordinarily that arrives whole in the first packet; this exists
  ## only so an upstream that never sends a CRLF cannot make the relay buffer
  ## without limit.

## Function purpose: one insertion at a known offset, never a parse of the head.
## The contract of this module is that whatever the upstream says about content
## type, chunking or SSE framing reaches the client unaltered, and a header
## table that round-tripped the head is where that would stop being true.
##
## Action purpose: with no CRLF there is no status line to insert after, so the
## buffer is returned exactly as it came and the caller loses only the
## diagnostic. That is the sole direction this may fail in.
##
## `extra` must be CRLF-terminated header lines carrying no bare CR or LF: a
## header value containing one is response splitting.
proc spliceHeaders*(buf, extra: string): string =
  if extra.len == 0: return buf
  let cut = buf.find("\r\n")
  if cut < 0: return buf
  buf[0 .. cut + 1] & extra & buf[cut + 2 .. ^1]

## Function purpose: relays a request upstream and streams the reply straight
## back, returning which of the three outcomes happened.
##
## Action purpose: `capture` is a tee, not a parse. A cache that stored a
## *parsed* response would answer a later hit in a shape the streaming reader
## cannot consume; storing the wire bytes makes a replayed hit byte-identical to
## a live reply, and nothing downstream has to know the difference.
proc forward*(client: Socket, req: Request, host: string, port: int,
              capture: ptr string = nil,
              extraHeaders = ""): RelayOutcome =
  var up: Socket
  try:
    up = newSocket(buffered = false)
    up.connect(host, port.Port, timeout = UpstreamConnectTimeoutMs)
  except CatchableError:
    if not up.isNil:
      try: up.close() except CatchableError: discard
    sendUpstreamUnavailable(client, host, port)
    return roUnavailable

  defer:
    try: up.close() except CatchableError: discard

  # Action purpose: bounds every `recv` below. Without it an upstream that
  # accepts the connection and then stops speaking owns this thread for good.
  var tv = Timeval(tv_sec: posix.Time(UpstreamRecvTimeoutSec), tv_usec: 0)
  discard setsockopt(up.getFd, SOL_SOCKET, SO_RCVTIMEO,
                     addr tv, SockLen(sizeof(tv)))

  up.send(buildRequest(req, host, port))

  var chunk = newString(RelayChunk)
  var relayed = 0
  # Action purpose: bytes held back while the status line is still incomplete.
  # Both are inert unless the caller asked for headers — with `extraHeaders`
  # empty, `splicing` is false from the outset and no byte is ever buffered.
  var pending = ""
  var splicing = extraHeaders.len > 0
  while true:
    # Action purpose: `n < 0` and `n == 0` are different endings and were
    # treated as one. This socket is unbuffered and not TLS, so `net.recv`
    # hands back the raw syscall result rather than raising — the receive
    # timeout set above therefore arrived as -1/`EAGAIN`, `n <= 0` read it as a
    # clean close, and a stream cut off mid-generation was reported
    # `roComplete`. That answer is what the response cache stores: a fragment
    # filed to be replayed later as a whole reply. Zero still means the upstream
    # closed properly; anything negative means it did not.
    #
    # The `try` is belt and braces rather than the mechanism — a buffered or TLS
    # socket does raise here, and a timeout escaping after the head is on the
    # wire would be a 500 written into the middle of a response body.
    var n = 0
    var recvFailed = false
    try:
      n = up.recv(addr chunk[0], chunk.len)
    except CatchableError:
      recvFailed = true
    if recvFailed or n < 0:
      # Action purpose: `relayed == 0` alone decides, and `pending` is discarded
      # rather than consulted. With the emptiness of `pending` in the condition,
      # an upstream that sent a fragment of a status line and then timed out took
      # the `roTruncated` branch — and nothing had been written to the client at
      # all, so it got a closed connection with zero bytes and no status. Falling
      # through with `pending` intact is no better: the tail would send that
      # fragment as though it were a response and then report `roComplete` over
      # it. Neither is a reply. Less than a status line is not something a client
      # can be given, so it is dropped and the 502 at the end of the function
      # answers, which is the same operational fact as an upstream that never
      # spoke. Once anything HAS reached the client the head is already on the
      # wire and only `roTruncated` is honest.
      if relayed == 0:
        pending = ""
        break
      return roTruncated
    if n == 0:
      break

    if splicing:
      # Action purpose: the head may split across packets, so the CRLF is
      # sought in the accumulation rather than in this packet alone.
      pending.add chunk[0 ..< n]
      let complete = pending.contains("\r\n")
      if not complete and pending.len < MaxStatusLineProbe:
        continue
      var head = if complete: spliceHeaders(pending, extraHeaders) else: pending
      splicing = false
      pending = ""
      var hs = 0
      while hs < head.len:
        let w = client.send(addr head[hs], head.len - hs)
        if w <= 0:
          return roTruncated
        hs += w
      relayed += head.len
      if capture != nil:
        capture[].add head
      continue

    # Action purpose: a single `send` may accept fewer bytes than offered, and
    # ignoring the count silently truncates the model's output mid-stream. This
    # is the steady-state path and sends straight out of `chunk` with no copy,
    # which is why the splice above buffers rather than wrapping every packet.
    var sent = 0
    while sent < n:
      let w = client.send(addr chunk[sent], n - sent)
      if w <= 0:
        # The client is gone, so whatever reached it is a fragment; the caller
        # must be able to tell that from a clean finish.
        return roTruncated
      sent += w
    relayed += n
    # Action purpose: the tee runs after the client is served, so a capture
    # buffer can never delay a token reaching the window.
    if capture != nil:
      capture[].add chunk[0 ..< n]

  # Action purpose: an upstream that closed having sent less than a status line
  # leaves those bytes here, and dropping them turns a short reply into none.
  if pending.len > 0:
    var ps = 0
    while ps < pending.len:
      let w = client.send(addr pending[ps], pending.len - ps)
      if w <= 0:
        return roTruncated
      ps += w
    relayed += pending.len
    if capture != nil:
      capture[].add pending

  # Action purpose: an upstream that accepted the connection and then closed
  # without a byte — a crash mid-load, a receive timeout — is the same
  # operational state as a refused one, so it gets the same answer. A partial
  # relay cannot: its response head is already on the wire.
  if relayed == 0:
    sendUpstreamUnavailable(client, host, port)
    return roUnavailable
  roComplete
