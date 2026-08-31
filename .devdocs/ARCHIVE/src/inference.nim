## Script function and purpose: The inference worker — one dedicated thread that
## owns the llama context and is the only thread that ever touches it.
##
## ## Why a thread and not a mutex
##
## A `llama_context` must not be driven concurrently. A mutex around generation
## would satisfy that, but it would also mean the *calling* HTTP worker is held
## for the whole generation, and under ruling D-W generations are serial — so a
## second request would occupy a completion thread doing nothing but waiting.
## Handing the connection to this thread instead frees the HTTP worker
## immediately and lets the queue, rather than the thread pool, absorb the wait.
##
## ## Socket ownership
##
## A job carries the client descriptor. **This thread owns that socket from the
## moment the job is queued** — it writes the response and closes it. The HTTP
## worker must not touch it afterwards, which is why `handle` reports that
## ownership moved.
##
## Nothing reference-counted crosses the queue: the prompt travels as a shared
## allocation this thread copies and frees. Nim's channels would copy a string
## safely, but an explicit allocation makes the ownership transfer visible rather
## than implicit.

import std/[net, nativesockets, os, strformat, json, times, monotimes]
import ./llama

type
  Job* = object
    fd*: SocketHandle
    promptPtr*: pointer
    promptLen*: int
    maxTokens*: int
    stream*: bool
    chat*: bool          ## shape the response as an OpenAI chat completion

  Stats* = object
    served*: int
    failed*: int

const
  MaxPromptBytes = 4 * 1024 * 1024
  SpecStrMax = 1024

type SpecStr = array[SpecStrMax, char]

# Plain buffers, written once before the thread starts and read-only after —
# the same discipline as db.nim and server.nim.
var
  jobs: Channel[Job]
  worker: Thread[void]
  running: bool
  sModelPath, sDevices, sTensorSplit, sKvType: SpecStr
  sModelPathLen, sDevicesLen, sTensorSplitLen, sKvTypeLen: int
  sCtx, sBatch, sUbatch, sSeqMax: uint32
  sNgl, sThreads, sThreadsBatch: int32
  stats: Stats

proc setStr(dst: var SpecStr, dstLen: var int, v: string) =
  let n = min(v.len, SpecStrMax - 1)
  if n > 0: copyMem(addr dst[0], v.cstring, n)
  dstLen = n

proc getStr(src: SpecStr, srcLen: int): string =
  result = newString(srcLen)
  if srcLen > 0: copyMem(addr result[0], addr src[0], srcLen)

proc configure*(spec: llama.LoadSpec) =
  setStr(sModelPath, sModelPathLen, spec.modelPath)
  setStr(sDevices, sDevicesLen, spec.devices)
  setStr(sTensorSplit, sTensorSplitLen, spec.tensorSplit)
  setStr(sKvType, sKvTypeLen, spec.kvCacheType)
  sCtx = spec.nCtx
  sBatch = spec.nBatch
  sUbatch = spec.nUbatch
  sSeqMax = spec.nSeqMax
  sNgl = spec.nGpuLayers
  sThreads = spec.nThreads
  sThreadsBatch = spec.nThreadsBatch

proc currentSpec(): llama.LoadSpec =
  llama.LoadSpec(
    modelPath: getStr(sModelPath, sModelPathLen),
    devices: getStr(sDevices, sDevicesLen),
    tensorSplit: getStr(sTensorSplit, sTensorSplitLen),
    kvCacheType: getStr(sKvType, sKvTypeLen),
    nCtx: sCtx, nBatch: sBatch, nUbatch: sUbatch, nSeqMax: sSeqMax,
    nGpuLayers: sNgl, nThreads: sThreads, nThreadsBatch: sThreadsBatch)

proc sendAll(s: Socket, data: string) =
  if data.len == 0: return
  var sent = 0
  while sent < data.len:
    let w = s.send(unsafeAddr data[sent], data.len - sent)
    if w <= 0: return
    sent += w

proc jsonStr(s: string): string = $(%s)

proc chunkJson(id: string, model, piece: string, chat: bool): string =
  let created = epochTime().int
  if chat:
    $(%*{"id": id, "object": "chat.completion.chunk", "created": created,
         "model": model,
         "choices": [{"index": 0, "delta": {"content": piece},
                      "finish_reason": newJNull()}]})
  else:
    $(%*{"id": id, "object": "text_completion", "created": created,
         "model": model,
         "choices": [{"index": 0, "text": piece, "finish_reason": newJNull()}]})

proc finalJson(id, model, text: string, chat: bool, nTok: int): string =
  let created = epochTime().int
  if chat:
    $(%*{"id": id, "object": "chat.completion", "created": created,
         "model": model,
         "choices": [{"index": 0,
                      "message": {"role": "assistant", "content": text},
                      "finish_reason": "stop"}],
         "usage": {"completion_tokens": nTok}})
  else:
    $(%*{"id": id, "object": "text_completion", "created": created,
         "model": model,
         "choices": [{"index": 0, "text": text, "finish_reason": "stop"}],
         "usage": {"completion_tokens": nTok}})

proc httpError(s: Socket, status: int, msg: string) =
  let body = $(%*{"error": msg})
  s.sendAll(&"HTTP/1.1 {status} Error\r\nContent-Type: application/json\r\n" &
            &"Content-Length: {body.len}\r\nConnection: close\r\n\r\n{body}")

## Action purpose: the model is loaded on this thread, not the caller's, so the
## context is created and used by the same thread for its whole life. Loading is
## lazy because it takes seconds and holds GPU memory — a server that is started
## but never asked to generate should not reserve a GPU.
proc runWorker() {.thread.} =
  var handle: llama.ModelHandle
  var loaded = false
  var loadError = ""
  let modelName = getStr(sModelPath, sModelPathLen).extractFilename

  while true:
    let job = jobs.recv()
    if job.fd == osInvalidSocket:
      break

    var payload = newString(job.promptLen)
    if job.promptLen > 0:
      copyMem(addr payload[0], job.promptPtr, job.promptLen)
    if job.promptPtr != nil:
      deallocShared(job.promptPtr)

    let client = newSocket(job.fd, Domain.AF_INET, SockType.SOCK_STREAM,
                           Protocol.IPPROTO_TCP, buffered = false)

    if not loaded and loadError.len == 0:
      try:
        handle = llama.load(currentSpec())
        loaded = true
      except CatchableError:
        loadError = getCurrentExceptionMsg()

    if not loaded:
      httpError(client, 503, "model unavailable: " & loadError)
      stats.failed.inc
      try: client.close() except CatchableError: discard
      continue

    # Action purpose: chat templating happens here, not in the HTTP handler,
    # because it needs the loaded model and only this thread may touch it. A
    # chat job therefore carries the raw messages array and is formatted with
    # the model's own template at the last moment.
    var prompt = payload
    if job.chat:
      try:
        let msgs = parseJson(payload)
        var roles, contents: seq[string]
        for m in msgs:
          roles.add m{"role"}.getStr("user")
          contents.add m{"content"}.getStr("")
        prompt = handle.applyChatTemplate(roles, contents)
      except CatchableError:
        httpError(client, 400, "chat formatting failed: " & getCurrentExceptionMsg())
        stats.failed.inc
        try: client.close() except CatchableError: discard
        continue

    let id = "cmpl-" & $getMonoTime().ticks
    var produced = 0
    var collected = ""

    try:
      if job.stream:
        client.sendAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
                       "Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
        produced = handle.generate(prompt, job.maxTokens, proc(piece: string): bool =
          client.sendAll("data: " & chunkJson(id, modelName, piece, job.chat) &
                         "\r\n\r\n")
          true)
        client.sendAll("data: [DONE]\r\n\r\n")
      else:
        produced = handle.generate(prompt, job.maxTokens, proc(piece: string): bool =
          collected.add piece
          true)
        let body = finalJson(id, modelName, collected, job.chat, produced)
        client.sendAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
                       &"Content-Length: {body.len}\r\nConnection: close\r\n\r\n{body}")
      stats.served.inc
    except CatchableError:
      # A streaming response has already committed its status line, so the only
      # honest signal left is to stop and close.
      if not job.stream:
        try: httpError(client, 500, getCurrentExceptionMsg())
        except CatchableError: discard
      stats.failed.inc

    try: client.close() except CatchableError: discard

  if loaded:
    handle.free()

proc start*() =
  if running: return
  jobs.open()
  running = true
  createThread(worker, runWorker)

proc stop*() =
  if not running: return
  jobs.send(Job(fd: osInvalidSocket))
  joinThread(worker)
  running = false

## Function purpose: hand a connection to the inference thread. Returns false if
## the worker is not running, in which case the caller still owns the socket.
proc submit*(fd: SocketHandle, prompt: string, maxTokens: int,
             stream, chat: bool): bool =
  if not running: return false
  if prompt.len > MaxPromptBytes: return false
  var p: pointer = nil
  if prompt.len > 0:
    p = allocShared(prompt.len)
    copyMem(p, prompt.cstring, prompt.len)
  jobs.send(Job(fd: fd, promptPtr: p, promptLen: prompt.len,
                maxTokens: maxTokens, stream: stream, chat: chat))
  true

proc snapshot*(): Stats = stats
