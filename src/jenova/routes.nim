## Script function and purpose: which pool of threads a connection is handed to.
## A single shared pool starves: completion streams are long-lived by design, so
## enough of them occupy every worker and health checks and assets stop being
## answered — normal operation, not an edge case. Each class gets its own queue
## and threads so saturating one cannot starve another.
##
## The counts below are sized for a personal product — the host plus at most one
## LAN device — not for a multi-user server, and are commented individually.

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

## Action purpose: health has its own threads despite being trivial work. The
## point of a liveness endpoint is that it answers while everything else is
## saturated, which sharing a queue with saturable work would defeat.
const ClassTable*: array[RouteClass, ClassSpec] = [
  rcStatic:     ClassSpec(name: "static",     threads: 4),  # no keep-alive yet, so one page load is several connections
  rcHealth:     ClassSpec(name: "health",     threads: 2),  # must answer under any load
  rcApi:        ClassSpec(name: "api",        threads: 3),  # DB calls, milliseconds
  rcCompletion: ClassSpec(name: "completion", threads: 3),  # 2 devices, +1 so a half-open stream cannot block the real one
  rcEmbed:      ClassSpec(name: "embed",      threads: 1),  # background, one at a time
  rcDebug:      ClassSpec(name: "debug",      threads: 1),  # diagnostics only
]

## Function purpose: the number the server preallocates and reports; summed
## here so adding a class cannot leave a count stale somewhere else.
proc totalThreads*(): int =
  for c in RouteClass:
    result += ClassTable[c].threads

## Function purpose: decides from the path alone, so a peek at the request line
## suffices and the socket stays unconsumed for the pool that will own it.
proc classify*(path: string): RouteClass =
  # Action purpose: tested before the `/v1/` prefix below, which would otherwise
  # claim `/v1/health` for the completion class and answer 400 — that handler
  # parses a JSON body a GET does not carry.
  if path == "/health" or path.startsWith("/health?") or
     path == "/v1/health" or path.startsWith("/v1/health?"):
    rcHealth
  elif path.startsWith("/debug/"):
    rcDebug
  elif path.startsWith("/api/"):
    rcApi
  # Action purpose: `/infill` is llama.cpp's fill-in-the-middle endpoint, which
  # the editor integration depends on. It is forwarded verbatim, so classifying
  # it into this pool is the whole of the requirement.
  elif path.startsWith("/v1/") or path.startsWith("/completion") or
       path.startsWith("/infill") or
       path.startsWith("/chat") or path.startsWith("/props") or
       path.startsWith("/slots"):
    rcCompletion
  elif path.startsWith("/embed") or path.startsWith("/embeddings"):
    rcEmbed
  else:
    rcStatic

## Function purpose: an empty answer means the request line has not fully
## arrived, so the caller peeks again rather than guessing at a partial one.
proc pathFromHead*(head: string): string =
  let nl = head.find('\n')
  if nl < 0:
    return ""
  let line = head[0 ..< nl].strip
  let parts = line.split(' ')
  if parts.len < 2: "" else: parts[1]
