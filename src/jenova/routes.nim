## Script function and purpose: Route classification and the per-class service
## table. This is the file that decides which pool of threads a connection is
## handed to, and it exists because a single shared pool has a starvation bug.
##
## With one pool, N long-lived completion streams occupy all N workers and the
## server stops answering health checks and static requests entirely — the
## streams are *supposed* to be long-lived, so this is not an edge case, it is
## normal operation. Isolating classes means saturating one cannot starve
## another: each has its own queue and its own threads.
##
## ## Sizing
##
## Jenova is a **personal, single-user product** (ruling D-T): the host, plus at
## most one LAN device — a phone or a second laptop. It is not a multi-user
## server, and larger local servers already exist for that. Every thread count
## below is derived from that, not from server intuition.
##
## Concretely: two devices means at most two live generations, so `completion`
## needs two plus one margin — a reloaded browser tab can leave a half-open
## stream holding a thread until the 30 s socket timeout reaps it, and without
## the margin that stale connection would block the real one. `static` is the
## largest pool despite being the cheapest work, because browsers open several
## parallel connections per page load and this server has no keep-alive yet
## (N-16), so one page is several short connections.
##
## Total is 14 handler threads. An earlier revision provisioned 34 on server
## assumptions; that was over-provisioned by roughly a factor of two for a
## two-device product.

import std/strutils

type
  RouteClass* = enum
    rcStatic       ## static assets from public/ — short, frequent
    rcHealth       ## liveness — must answer even when everything else is saturated
    rcApi          ## /api/* — database work, milliseconds
    rcCompletion   ## proxied to llama-server — long-lived, streaming
    rcEmbed        ## proxied to the embedding server
    rcDebug        ## diagnostics, off unless explicitly enabled

  ClassSpec* = object
    name*: string
    threads*: int

## Action purpose: health gets its own dedicated threads despite being trivial
## work. The entire point of a liveness endpoint is that it answers when the
## system is under stress; sharing a queue with anything that can saturate would
## defeat it. `_probe_health` in the shell watchdog targets this.
const ClassTable*: array[RouteClass, ClassSpec] = [
  rcStatic:     ClassSpec(name: "static",     threads: 4),  # browser parallelism, no keep-alive
  rcHealth:     ClassSpec(name: "health",     threads: 2),  # must answer under any load
  rcApi:        ClassSpec(name: "api",        threads: 3),  # DB calls, milliseconds
  rcCompletion: ClassSpec(name: "completion", threads: 3),  # 2 devices + 1 stale-stream margin
  rcEmbed:      ClassSpec(name: "embed",      threads: 1),  # background, one at a time
  rcDebug:      ClassSpec(name: "debug",      threads: 1),  # diagnostics only
]

proc totalThreads*(): int =
  for c in RouteClass:
    result += ClassTable[c].threads

## Function purpose: classify a request from its path alone, so the decision can
## be made from a peek at the request line without consuming the socket. The
## connection is then handed to the owning pool, which performs the real parse.
proc classify*(path: string): RouteClass =
  # Action purpose: `/v1/health` is a liveness check, not a completion. It was
  # caught by the `/v1/` prefix below and answered 400, because the completion
  # handler tried to parse a JSON body that a GET does not carry. It is tested
  # before that prefix for exactly that reason.
  if path == "/health" or path.startsWith("/health?") or
     path == "/v1/health" or path.startsWith("/v1/health?"):
    rcHealth
  elif path.startsWith("/debug/"):
    rcDebug
  elif path.startsWith("/api/"):
    rcApi
  # Action purpose: `/infill` is llama.cpp's fill-in-the-middle endpoint and the
  # USER's Neovim configuration depends on it. Under D-AF it is forwarded to
  # `llama-server`, which is built with `--spm-infill` (`bin/jenova-ca:235,808`),
  # so classifying it here is the whole of the requirement — `proxy.lua:1406`
  # likewise only ever forwarded it verbatim.
  elif path.startsWith("/v1/") or path.startsWith("/completion") or
       path.startsWith("/infill") or
       path.startsWith("/chat") or path.startsWith("/props") or
       path.startsWith("/slots"):
    rcCompletion
  elif path.startsWith("/embed") or path.startsWith("/embeddings"):
    rcEmbed
  else:
    rcStatic

## Function purpose: extract the request target from a peeked buffer without
## consuming it. Returns an empty string when the request line has not fully
## arrived yet, so the caller can peek again rather than guess.
proc pathFromHead*(head: string): string =
  let nl = head.find('\n')
  if nl < 0:
    return ""
  let line = head[0 ..< nl].strip
  let parts = line.split(' ')
  if parts.len < 2: "" else: parts[1]
