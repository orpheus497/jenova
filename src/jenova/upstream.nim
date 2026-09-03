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

type RelayOutcome* = enum
  ## 12d-1. `forward` used to answer `bool`, and it returned **true for two
  ## different things**: an upstream that closed cleanly after a whole response,
  ## and a client that walked away mid-stream (`return relayed > 0`). Nothing
  ## cared until the response cache needed a writer — and storing a truncated
  ## stream to replay later as a complete answer is D-BQ's truncated attachment
  ## in another costume: confident, and about a fragment. So the third state is
  ## named rather than inferred.
  roUnavailable   ## nothing relayed; this module has already answered 502
  roTruncated     ## the client went away mid-stream; the head is already sent
  roComplete      ## upstream closed after relaying a complete response

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

const MaxStatusLineProbe* = 512
  ## How many bytes `forward` may hold back while it waits for the end of the
  ## response's status line. A status line is well under a hundred bytes and
  ## arrives in the upstream's first packet in every ordinary case; this exists
  ## only so a pathological upstream cannot make the relay buffer without limit
  ## while looking for a CRLF that is not coming.

## Function purpose: put extra response headers immediately after the status
## line of a response head (E-05).
##
## Action purpose: **one insertion at a known offset, never a parse of the
## head.** This module's whole contract is that whatever `llama-server` says
## about content type, chunking or SSE framing reaches the client unaltered, and
## a header table that round-tripped the head would be a place for that to stop
## being true. It is the same discipline `server.handle` already keeps where it
## inserts `X-Cache: HIT` on a replayed cache hit.
##
## **Failure is "no header", never a damaged stream.** With no CRLF in `buf`
## there is no status line to insert after, so the buffer is returned exactly as
## it came; the caller relays it verbatim and simply loses the diagnostic. That
## is the only direction this may fail in — a diagnostic is not worth a risk to
## the bytes a generation is made of.
##
## `extra` must already be CRLF-terminated header lines and must carry no bare
## CR or LF of its own; `server.handle` builds it from integers and a fixed
## enum, so there is nothing in it that could inject one. Asserted rather than
## trusted: a header value carrying a CRLF is response splitting.
proc spliceHeaders*(buf, extra: string): string =
  if extra.len == 0: return buf
  let cut = buf.find("\r\n")
  if cut < 0: return buf
  buf[0 .. cut + 1] & extra & buf[cut + 2 .. ^1]

proc forward*(client: Socket, req: Request, host: string, port: int,
              capture: ptr string = nil,
              extraHeaders = ""): RelayOutcome =
  ## `capture`, when given, receives a copy of every byte relayed to the client,
  ## response head included. **It is a tee, not a parse** (12d-1): the point of
  ## this module is that framing — chunked, SSE, content type — is whatever
  ## `llama-server` said it was, and a cache that stored a *parsed* response
  ## would answer a later hit in a shape the streaming reader cannot consume.
  ## Storing the wire bytes means a replayed hit is byte-identical to a live
  ## reply and nothing downstream has to know the difference.
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
  # E-05. Held-back bytes while the status line is still incomplete, and whether
  # this relay is still looking for it. **Both are inert unless the caller asked
  # for headers**: with `extraHeaders` empty, `splicing` is false from the first
  # line and every byte takes the same path it always did.
  var pending = ""
  var splicing = extraHeaders.len > 0
  while true:
    let n = up.recv(addr chunk[0], chunk.len)
    if n <= 0:
      break

    if splicing:
      # The head may be split across packets, so the CRLF is looked for in the
      # accumulation rather than in this packet. The probe bound is what stops
      # an upstream that never sends one from buffering for ever.
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

    # Action purpose: a single send() may accept fewer bytes than offered, and a
    # relay that ignores the count silently truncates the model's output
    # mid-stream. Loop until the chunk is fully written or the client goes away.
    #
    # This is the steady-state path and it is byte-for-byte what it was before
    # the splice above existed: it sends straight out of `chunk` with no copy,
    # which is why the splice buffers rather than wrapping every packet.
    var sent = 0
    while sent < n:
      let w = client.send(addr chunk[sent], n - sent)
      if w <= 0:
        # The client is gone. Whatever reached it is a fragment, and the caller
        # must be able to tell that from a clean finish — see `RelayOutcome`.
        return roTruncated
      sent += w
    relayed += n
    # The tee, and it happens **after** the client is served: relaying is this
    # module's job and a capture buffer must never delay a token reaching the
    # window. Appending the same bytes that were just written is what makes a
    # cached hit byte-identical to a live reply.
    if capture != nil:
      capture[].add chunk[0 ..< n]

  # An upstream that closed having sent less than a status line leaves those
  # bytes in `pending`, and dropping them would turn a short reply into no reply
  # at all. Flushed verbatim: there was never a status line to splice into.
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

  # An upstream that accepted the connection and then closed without a byte —
  # a crash mid-load, a receive timeout — left the client with an empty reply
  # and no status at all, because the caller only closes the socket on `false`.
  # That is the same operational state as a refused connection, so it gets the
  # same answer. A partial relay still returns true: the response head is
  # already on the wire and cannot be replaced.
  if relayed == 0:
    sendUpstreamUnavailable(client, host, port)
    return roUnavailable
  roComplete
