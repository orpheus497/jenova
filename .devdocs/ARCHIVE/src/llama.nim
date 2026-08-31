## Script function and purpose: Direct binding to libllama, replacing the
## `llama-server` subprocess and the HTTP hop to it.
##
## ## Why this is bound through the C header and not by mirroring the ABI
##
## `lib/ffi_defs.lua` declared C structs by hand, and its two platform arms
## disagreed on field order and integer widths — reading the wrong one silently
## swapped a `struct sockaddr *` for a `char *`. Stage S-1 deleted that file's
## Linux arm precisely because hand-mirrored layouts are a silent-corruption
## machine, and the remediation plan traced three of four Phase 1 defects to that
## surface.
##
## `llama_model_params` and `llama_context_params` are large, versioned structs
## returned **by value**. Mirroring them in Nim would rebuild exactly the hazard
## the migration removed, and llama.cpp reorders these fields between releases.
##
## Instead these types are imported from `llama.h` itself: Nim compiles to C, so
## the C compiler resolves every layout, and only the fields actually assigned
## are named here. A field that moves, changes width or disappears becomes a
## **compile error** rather than a wrong pointer at runtime. This is the concrete
## payoff the refactor analysis predicted from leaving LuaJIT FFI behind.

import std/[os, strutils]

const
  llamaRoot = currentSourcePath().parentDir.parentDir.parentDir
  llamaInclude = llamaRoot / "external" / "llama.cpp" / "include"
  # llama.h includes ggml.h, which lives in a sibling tree rather than beside it.
  ggmlInclude = llamaRoot / "external" / "llama.cpp" / "ggml" / "include"
  llamaLibDir = llamaRoot / "external" / "ext_bin" / "bin"

{.passC: "-I" & llamaInclude & " -I" & ggmlInclude.}
## Action purpose: `--disable-new-dtags` forces DT_RPATH instead of DT_RUNPATH.
## The distinction is load-bearing here: RUNPATH is consulted only for the
## executable's own direct dependencies, so `libllama.so` would fail to find
## `libggml.so` beside it. RPATH is inherited through the dependency chain and
## resolves it. Symptom without this: "Shared object libggml.so.0 not found,
## required by libllama.so.0" at startup, despite the library sitting in the
## directory the rpath names.
## `libggml` is linked explicitly, not left to `libllama` to pull in. `libllama.so`
## carries its own DT_RUNPATH pointing at a build directory that no longer
## exists, and an object with DT_RUNPATH does **not** fall back to the parent's
## DT_RPATH when resolving its dependencies. Naming ggml here makes it a direct
## dependency of this executable, so our own rpath resolves it and it is already
## loaded by the time libllama asks.
## The backend libraries (`ggml-cpu`, `ggml-vulkan`) are named for the same
## reason: each is a DT_NEEDED of libllama with the same broken RUNPATH, so each
## has to become a direct dependency of this binary to be found.
{.passL: "-L" & llamaLibDir &
         " -lllama -lggml -lggml-base -lggml-cpu -lggml-vulkan " &
         "-Wl,--disable-new-dtags -Wl,-rpath," & llamaLibDir.}

type
  LlamaModel* = distinct pointer
  LlamaContext* = distinct pointer
  LlamaVocab* = distinct pointer
  LlamaSampler* = distinct pointer
  LlamaToken* = int32

  ## Only the fields this module assigns are declared. The C compiler supplies
  ## size and offsets from the real header, so the rest of each struct is
  ## present and correct without being described here.
  BackendDev* = pointer   ## ggml_backend_dev_t, opaque

  ModelParams* {.importc: "struct llama_model_params", header: "llama.h",
                 bycopy.} = object
    devices* {.importc: "devices".}: ptr BackendDev
    n_gpu_layers* {.importc: "n_gpu_layers".}: int32
    main_gpu* {.importc: "main_gpu".}: int32
    tensor_split* {.importc: "tensor_split".}: ptr float32

  ContextParams* {.importc: "struct llama_context_params", header: "llama.h",
                   bycopy.} = object
    n_ctx* {.importc: "n_ctx".}: uint32
    n_batch* {.importc: "n_batch".}: uint32
    n_ubatch* {.importc: "n_ubatch".}: uint32
    n_seq_max* {.importc: "n_seq_max".}: uint32
    n_threads* {.importc: "n_threads".}: int32
    n_threads_batch* {.importc: "n_threads_batch".}: int32
    type_k* {.importc: "type_k".}: cint
    type_v* {.importc: "type_v".}: cint

  SamplerChainParams* {.importc: "struct llama_sampler_chain_params",
                        header: "llama.h", bycopy.} = object

  Batch* {.importc: "struct llama_batch", header: "llama.h", bycopy.} = object
    n_tokens* {.importc: "n_tokens".}: int32

  ChatMessage* {.importc: "llama_chat_message", header: "llama.h",
                 bycopy.} = object
    role* {.importc: "role".}: cstring
    content* {.importc: "content".}: cstring

{.push importc, header: "ggml-backend.h", cdecl.}
proc ggml_backend_dev_count*(): csize_t
proc ggml_backend_dev_get*(index: csize_t): BackendDev
proc ggml_backend_dev_name*(dev: BackendDev): cstring
proc ggml_backend_dev_description*(dev: BackendDev): cstring
{.pop.}

{.push importc, header: "llama.h", cdecl.}
proc llama_backend_init*()
proc llama_backend_free*()
proc llama_model_default_params*(): ModelParams
proc llama_context_default_params*(): ContextParams
proc llama_sampler_chain_default_params*(): SamplerChainParams
proc llama_model_load_from_file*(path: cstring, params: ModelParams): LlamaModel
proc llama_model_free*(m: LlamaModel)
proc llama_init_from_model*(m: LlamaModel, params: ContextParams): LlamaContext
proc llama_free*(ctx: LlamaContext)
proc llama_model_get_vocab*(m: LlamaModel): LlamaVocab
proc llama_vocab_n_tokens*(v: LlamaVocab): int32
proc llama_n_ctx*(ctx: LlamaContext): uint32
proc llama_tokenize*(v: LlamaVocab, text: cstring, text_len: int32,
                     tokens: ptr LlamaToken, n_tokens_max: int32,
                     add_special: bool, parse_special: bool): int32
proc llama_token_to_piece*(v: LlamaVocab, token: LlamaToken, buf: cstring,
                           length: int32, lstrip: int32, special: bool): int32
proc llama_batch_get_one*(tokens: ptr LlamaToken, n_tokens: int32): Batch
proc llama_decode*(ctx: LlamaContext, batch: Batch): int32
proc llama_vocab_is_eog*(v: LlamaVocab, token: LlamaToken): bool
proc llama_sampler_chain_init*(p: SamplerChainParams): LlamaSampler
proc llama_sampler_chain_add*(chain: LlamaSampler, s: LlamaSampler)
proc llama_sampler_init_greedy*(): LlamaSampler
proc llama_sampler_init_dist*(seed: uint32): LlamaSampler
proc llama_sampler_init_temp*(t: float32): LlamaSampler
proc llama_sampler_sample*(s: LlamaSampler, ctx: LlamaContext, idx: int32): LlamaToken
proc llama_sampler_accept*(s: LlamaSampler, token: LlamaToken)
proc llama_sampler_free*(s: LlamaSampler)
proc llama_model_chat_template*(m: LlamaModel, name: cstring): cstring
proc llama_chat_apply_template*(tmpl: cstring, chat: ptr ChatMessage,
                                n_msg: csize_t, add_ass: bool,
                                buf: cstring, length: int32): int32
{.pop.}

type LlamaError* = object of CatchableError

proc isNil*(m: LlamaModel): bool {.borrow.}
proc isNil*(c: LlamaContext): bool {.borrow.}

type
  ModelHandle* = object
    model*: LlamaModel
    ctx*: LlamaContext
    vocab*: LlamaVocab
    sampler*: LlamaSampler
    nCtx*: uint32

var backendReady = false

## Function purpose: initialise the ggml backends once per process. llama.cpp
## registers its compute backends here, so calling it per model would be wrong
## and calling it not at all yields a CPU-only or failing load.
proc ensureBackend*() =
  if not backendReady:
    llama_backend_init()
    backendReady = true

type
  LoadSpec* = object
    ## Every value `etc/jenova.conf` exposes for the backend. Nothing here has a
    ## silent default that overrides the profile: if the profile says three
    ## Vulkan devices and a q8_0 KV cache, that is what gets used.
    modelPath*: string
    devices*: string        ## DEVICES, e.g. "Vulkan0,Vulkan1,Vulkan2"
    tensorSplit*: string    ## TENSOR_SPLIT, comma-separated proportions
    nCtx*: uint32           ## CTX_SIZE
    nBatch*: uint32         ## BATCH_SIZE
    nUbatch*: uint32        ## UBATCH_SIZE
    nSeqMax*: uint32        ## NUM_SLOTS
    nGpuLayers*: int32      ## NGL_AGENT ("all" -> -1)
    nThreads*: int32        ## THREADS
    nThreadsBatch*: int32   ## THREADS_BATCH
    kvCacheType*: string    ## KV_CACHE_TYPE
    temperature*: float32
    seed*: uint32

## Action purpose: map KV cache type names to ggml_type. **This is why the first
## run could not allocate a KV cache at CTX_SIZE=32768.** The profile asks for
## `q8_0`; leaving the default gives f16, which is twice the memory for the same
## context. An unknown name raises rather than silently falling back, because
## quietly doubling KV memory is exactly the failure this caused.
proc kvType(name: string): cint =
  case name.strip.toLowerAscii
  of "f32": 0
  of "f16", "": 1
  of "q4_0": 2
  of "q4_1": 3
  of "q5_0": 6
  of "q5_1": 7
  of "q8_0": 8
  else:
    raise newException(LlamaError, "unknown KV cache type: '" & name &
      "' (expected f32, f16, q4_0, q4_1, q5_0, q5_1 or q8_0)")

## Function purpose: resolve the configured device names to ggml devices.
##
## Omitting this is what sent the whole model to Vulkan0 alone and exhausted a
## 4 GB GPU: with `devices` left NULL llama.cpp uses its own default selection
## rather than the profile's `DEVICES` list, so a multi-GPU split configuration
## silently became single-GPU. `llama-server` passes this list, which is why it
## worked where the first version of this binding did not.
proc resolveDevices(spec: string): seq[BackendDev] =
  if spec.strip.len == 0: return @[]
  var available: seq[(string, BackendDev)]
  for i in 0 ..< ggml_backend_dev_count().int:
    let d = ggml_backend_dev_get(i.csize_t)
    available.add ($ggml_backend_dev_name(d), d)

  for wanted in spec.split(','):
    let w = wanted.strip
    if w.len == 0: continue
    var found = false
    for (name, dev) in available:
      if name == w:
        result.add dev
        found = true
        break
    if not found:
      var names: seq[string]
      for (n, _) in available: names.add n
      raise newException(LlamaError, "configured device '" & w &
        "' not present. Available: " & names.join(", "))

proc deviceNames*(): seq[string] =
  ensureBackend()
  for i in 0 ..< ggml_backend_dev_count().int:
    let d = ggml_backend_dev_get(i.csize_t)
    result.add $ggml_backend_dev_name(d) & " (" &
               $ggml_backend_dev_description(d) & ")"

## Function purpose: load a model and build its context and sampler from the
## resolved configuration. Everything the generation loop needs is created here,
## so the loop owns no initialisation and can run entirely on one thread.
proc load*(spec: LoadSpec): ModelHandle =
  if not fileExists(spec.modelPath):
    raise newException(LlamaError, "model file not found: " & spec.modelPath)
  ensureBackend()

  var mp = llama_model_default_params()
  mp.n_gpu_layers = spec.nGpuLayers

  # Kept alive for the duration of the load call: llama.cpp reads through these
  # pointers during llama_model_load_from_file and does not take ownership.
  var devs = resolveDevices(spec.devices)
  var devArray: seq[BackendDev]
  if devs.len > 0:
    devArray = devs
    devArray.add nil          # the list is NULL-terminated
    mp.devices = addr devArray[0]

  var splits: seq[float32]
  if spec.tensorSplit.strip.len > 0:
    for part in spec.tensorSplit.split(','):
      if part.strip.len > 0:
        splits.add parseFloat(part.strip).float32
    if splits.len > 0:
      mp.tensor_split = addr splits[0]

  result.model = llama_model_load_from_file(spec.modelPath.cstring, mp)
  if result.model.isNil:
    raise newException(LlamaError, "failed to load model: " & spec.modelPath)

  var cp = llama_context_default_params()
  cp.n_ctx = spec.nCtx
  cp.n_batch = if spec.nBatch > 0: spec.nBatch else: spec.nCtx
  if spec.nUbatch > 0: cp.n_ubatch = spec.nUbatch
  if spec.nSeqMax > 0: cp.n_seq_max = spec.nSeqMax
  cp.n_threads = spec.nThreads
  cp.n_threads_batch = spec.nThreadsBatch
  cp.type_k = kvType(spec.kvCacheType)
  cp.type_v = cp.type_k
  result.ctx = llama_init_from_model(result.model, cp)
  if result.ctx.isNil:
    llama_model_free(result.model)
    raise newException(LlamaError, "failed to create context")

  result.vocab = llama_model_get_vocab(result.model)
  result.nCtx = llama_n_ctx(result.ctx)

  result.sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
  if spec.temperature <= 0.0'f32:
    llama_sampler_chain_add(result.sampler, llama_sampler_init_greedy())
  else:
    llama_sampler_chain_add(result.sampler,
                            llama_sampler_init_temp(spec.temperature))
    llama_sampler_chain_add(result.sampler, llama_sampler_init_dist(spec.seed))

proc free*(h: var ModelHandle) =
  if not h.ctx.isNil:
    llama_sampler_free(h.sampler)
    llama_free(h.ctx)
    h.ctx = LlamaContext(nil)
  if not h.model.isNil:
    llama_model_free(h.model)
    h.model = LlamaModel(nil)

## Function purpose: format a chat exchange with **the model's own template**,
## fetched from the GGUF rather than assembled here. Every model family marks
## turns differently, and a hand-rolled format produces output that looks almost
## right while degrading quality in ways that are hard to attribute. If the model
## carries no template, that is reported rather than papered over with a guess.
proc applyChatTemplate*(h: ModelHandle, roles, contents: seq[string],
                        addAssistant = true): string =
  if roles.len != contents.len or roles.len == 0:
    raise newException(LlamaError, "chat template needs matching roles and contents")
  let tmpl = llama_model_chat_template(h.model, nil)
  if tmpl.isNil:
    raise newException(LlamaError,
      "model has no built-in chat template; /v1/chat/completions cannot be " &
      "formatted for it — use /completion with a raw prompt")

  var msgs = newSeq[ChatMessage](roles.len)
  # The cstrings must outlive the call, so the Nim strings stay in scope here.
  for i in 0 ..< roles.len:
    msgs[i] = ChatMessage(role: roles[i].cstring, content: contents[i].cstring)

  var size = 0
  for c in contents: size += c.len
  size = max(size * 2 + 1024, 4096)
  var buf = newString(size)
  var n = llama_chat_apply_template(tmpl, addr msgs[0], msgs.len.csize_t,
                                    addAssistant, buf.cstring, buf.len.int32)
  if n > buf.len.int32:
    buf = newString(n)
    n = llama_chat_apply_template(tmpl, addr msgs[0], msgs.len.csize_t,
                                  addAssistant, buf.cstring, buf.len.int32)
  if n < 0:
    raise newException(LlamaError, "chat template application failed")
  buf.setLen(n)
  buf

proc tokenize*(h: ModelHandle, text: string, addSpecial = true): seq[LlamaToken] =
  # A negative return is the required buffer size; llama.cpp reports it that way
  # rather than failing, so the first call sizes and the second fills.
  var need = llama_tokenize(h.vocab, text.cstring, text.len.int32, nil, 0,
                            addSpecial, true)
  if need < 0: need = -need
  if need == 0: return @[]
  result = newSeq[LlamaToken](need)
  let got = llama_tokenize(h.vocab, text.cstring, text.len.int32,
                           addr result[0], need, addSpecial, true)
  if got < 0:
    raise newException(LlamaError, "tokenize failed")
  result.setLen(got)

proc piece*(h: ModelHandle, tok: LlamaToken): string =
  var buf = newString(64)
  var n = llama_token_to_piece(h.vocab, tok, buf.cstring, buf.len.int32, 0, true)
  if n < 0:
    buf = newString(-n)
    n = llama_token_to_piece(h.vocab, tok, buf.cstring, buf.len.int32, 0, true)
    if n < 0: raise newException(LlamaError, "token_to_piece failed")
  buf.setLen(n)
  buf

## Function purpose: generate tokens, handing each piece to `onToken` as it is
## produced rather than accumulating and returning at the end. Streaming is the
## whole point — the caller relays pieces straight to its client, which is what
## makes a generation observable while it runs.
##
## Returning false from `onToken` stops generation, so a disconnected client
## cancels the work instead of leaving it running to completion.
proc generate*(h: var ModelHandle, prompt: string, maxTokens: int,
               onToken: proc(piece: string): bool {.closure, gcsafe.}): int
              {.gcsafe.} =
  var toks = h.tokenize(prompt)
  if toks.len == 0:
    raise newException(LlamaError, "prompt tokenized to nothing")
  if toks.len.uint32 >= h.nCtx:
    raise newException(LlamaError, "prompt of " & $toks.len &
                       " tokens exceeds context of " & $h.nCtx)

  var batch = llama_batch_get_one(addr toks[0], toks.len.int32)
  if llama_decode(h.ctx, batch) != 0:
    raise newException(LlamaError, "decode failed on prompt")

  var produced = 0
  var cur: LlamaToken
  while produced < maxTokens:
    cur = llama_sampler_sample(h.sampler, h.ctx, -1)
    if llama_vocab_is_eog(h.vocab, cur):
      break
    llama_sampler_accept(h.sampler, cur)
    if not onToken(h.piece(cur)):
      break
    produced.inc
    batch = llama_batch_get_one(addr cur, 1)
    if llama_decode(h.ctx, batch) != 0:
      raise newException(LlamaError, "decode failed during generation")
  produced
