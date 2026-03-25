## The Core Question: 14B Model Loading Strategy (CPU + NVIDIA + Iris Xe)

### What You Want

• 14B model: Use CPU + NVIDIA GTX 1650 Ti + Intel Iris Xe (dual Vulkan GPU)
• 7B model: Use CPU + NVIDIA + Iris Xe (dual Vulkan GPU)
• Figure out the best way to load the 14B model across this hardware

### Source-Level Evidence (from  llama.cpp/src/llama.cpp:327-328 )

  if (mparams->n_gpu_layers != default_mparams.n_gpu_layers) {
      throw llama_params_fit_exception("n_gpu_layers already set by user to "
          + std::to_string(mparams->n_gpu_layers) + ", abort");
  }

The default is  -1  ("auto"). Any explicit  -ngl  value (including  all / -2 , or  33 ) triggers the abort. This is
confirmed by:

•  jenova-ca.log:21 :  -ngl all  →  "n_gpu_layers already set by user to 99, abort"
•  server.log:25 :  -ngl 33  →  "n_gpu_layers already set by user to -2, abort"
•  jenova-ca.runlog : No  -ngl  → fitter succeeded, distributed 38/49 layers across both GPUs

### The Answer: Drop  -ngl  for Both Models, Let  -fitt  Auto-Fit

From  llama.cpp/common/arg.cpp:2322 : when  -ngl  is omitted, it defaults to  auto  ( -1 ). With  --fit  enabled
(default  on ), the fitter:

1. Reads available VRAM on each device
2. Subtracts the  -fitt  margin (768 MiB per your config)
3. Auto-distributes layers across GPUs respecting  -ts  ratios
4. Sets  n_gpu_layers  internally

For 14B:  -fitt 768 -sm layer -ts 2.0,1.0  (no  -ngl ) → fitter auto-tunes ~38-49 layers across both GPUs with 768 MiB
safety margin. Your  runlog  proves this works.

For 7B:  -fitt 768 -sm layer -ts 2.0,1.0  (no  -ngl ) → fitter will put all 28 layers on GPU since 7B easily fits in
~4.4 GiB. The margin ensures no OOM.

The  NGL_7B  and  NGL_14B  config variables become documentation-only — they're not passed to launch commands.

--------

## Verified Bug Status (All 12)

 #  │ Bug                                │ Verified?                                  │ Seve… │ Paste Accuracy
────┼────────────────────────────────────┼────────────────────────────────────────────┼───────┼───────────────────────
 1  │  -fitt  useless with explicit  -   │ YES — source-level proof in                │ HIGH  │ All 3 pastes correct
    │ ngl                                │ llama.cpp/src/llama.cpp:327 , confirmed by │       │
    │                                    │ 6 log files                                │       │
 2  │  embed.lua:56  missing             │ YES —  daemon.start_background  called     │ HIGH  │ All 3 pastes correct
    │ GGML_VULKAN_DISABLE=1              │ with 4 args,  daemon.lua:58  accepts 5th   │       │
    │                                    │ env  param                                 │       │
 3  │ Double embed startup / stale PID   │ YES —  .jenova/llama-embed.pid  exists     │ MEDIU │ All 3 pastes correct
    │                                    │ with stale PID 41945,  jenova-ca  tracks   │ M     │
    │                                    │ in  $PID_FILE  separately                  │       │
 4  │ Dead  CODER_ROOT  in               │ YES —  grep  finds zero definitions of     │ MEDIU │ All 3 pastes correct
    │ bin/jenova:90                      │ CODER_ROOT  anywhere                       │ M     │
 5  │ No  trap  in  bin/jenova           │ YES — lines 102-115 have sequential        │ MEDIU │ All 3 pastes correct
    │                                    │ cleanup only, no  trap  statement          │ M     │
 6  │ SIGPIPE double-set in  proxy.lua   │ YES — line 278 sets  SIG_IGN , line 319    │ MEDIU │ All 3 pastes correct
    │                                    │ overrides with GC-able callback            │ M     │
 7  │  COROUTINE_TIMEOUT=120  too short  │ YES — line 308 is 120s,  jenova.conf:66    │ HIGH  │ All 3 pastes correct
    │                                    │ TIMEOUT=600                                │       │
 8  │  search.lua:455  indentation       │ YES —  if not ok then  at 2-space indent   │ LOW   │ All 3 pastes correct
    │                                    │ inside 4-space block                       │       │
 9  │ README.md contradictions           │ YES — line 47 says Iris Xe "not used",     │ LOW   │ All 3 pastes correct
    │                                    │ lines 53-54 show old NGL, line 71 shows    │       │
    │                                    │ Vulkan0  only                              │       │
 10 │ Dead  assess_complexity            │ YES — defined at  agent.lua:136-168 ,      │ LOW   │ All 3 pastes correct
    │                                    │ grep  finds zero call sites                │       │
 11 │  jenova-ca stop  doesn't clean     │ YES — stop verb (lines 103-126) only       │ LOW   │ All 3 pastes correct
    │ .jenova/llama-embed.pid            │ handles  $PID_FILE                         │       │
 12 │  llama-server-nvim  dual-GPU       │ PARTIALLY — file exists at  bin/llama-     │ LOW   │ Paste 1 correct;
    │ contention                         │ server-nvim , uses  $DEVICES  (dual-GPU) + │       │ other pastes omit
    │                                    │ $NGL_7B  (all). However, with  -fitt       │       │
    │                                    │ approach, fitter handles memory            │       │
    │                                    │ contention. Risk is real but mitigated by  │       │
    │                                    │ -fitt  if the main server isn't running    │       │
    │                                    │ simultaneously                             │       │

### Additional Bug Found (not in pastes)

 #  │ Bug                                          │ File             │ Evidence
────┼──────────────────────────────────────────────┼──────────────────┼───────────────────────────────────────────────
 13 │  SPLIT_ARGS  hardcodes  768  instead of      │  jenova-ca:96    │  SPLIT_ARGS="-sm layer -fitt 768"  — should
    │ $FIT_TARGET                                  │                  │ use  $FIT_TARGET  variable
 14 │ Timeout sweeper bare  ffi.C.close()          │  proxy.lua:383-  │ No  pcall  on close in sweeper, but shutdown
    │                                              │ 385              │ cleanup (lines 393-398) uses  pcall  —
    │                                              │                  │ inconsistent, potential double-close

--------

## Paste Discrepancies

The 3 pastes are substantively consistent and accurate. Minor differences:

• Paste 1 mentions Bug 12 (llama-server-nvim), pastes 2 & 3 defer it
• Paste 3 recommends "Option A: -fitt only" — this is the correct recommendation, confirmed by source code and log
evidence
• Paste 2 includes Bug 14 (timeout sweeper bare close) which pastes 1 & 3 omit
• Line number references are accurate across all pastes (verified by direct file inspection)

--------

## Comprehensive Remediation Plan

### Phase 1: GPU Loading Strategy (The Core Fix)

Goal: Make both 14B and 7B use CPU + NVIDIA + Iris Xe optimally.

#### Fix 1.1: Remove  -ngl  from launch commands, keep  -fitt

Files:  bin/jenova-ca  (lines 96, 186-187, 239-240)

Current ( jenova-ca:96 ):

  SPLIT_ARGS="-sm layer -fitt 768"

Current ( jenova-ca:186-187 ):

      -ngl "$LLAMA_NGL" \
      $SPLIT_ARGS \

Change:

1.  SPLIT_ARGS="-sm layer -fitt $FIT_TARGET"  (use config variable)
2. Remove  -ngl "$LLAMA_NGL"  from both daemon (line 186) and foreground (line 239) launch blocks
3. Keep  NGL_7B / NGL_14B  in  jenova.conf  as documentation-only comments

Rationale: The fitter ( llama_params_fit_impl  at  llama.cpp/src/llama.cpp:411 ) will auto-distribute layers. With  -
ts 2.0,1.0 , NVIDIA gets 2 parts, Iris Xe gets 1 part. The 768 MiB margin prevents OOM. Your  runlog  proves this
works — 38/49 layers auto-distributed with >1 GiB free on each GPU.

#### Fix 1.2:  llama-server-nvim  — also drop  -ngl , add  -fitt

File:  bin/llama-server-nvim  (line 42)

Current:

      -ngl "$NGL_7B" \

Change: Replace with  -fitt $FIT_TARGET -sm layer  + add  -ts $TENSOR_SPLIT  if set. Or, since 7B is small and nvim
FIM is a separate server, consider NVIDIA-only ( -dev Vulkan0 -ngl all ) to avoid contending with the main 14B server
for Iris Xe memory.

Decision needed: If nvim and main server run simultaneously, they compete for Iris Xe UMA memory. Two options:

• (A) nvim uses NVIDIA-only:  -dev Vulkan0 -ngl all  (7B fits in 4 GiB)
• (B) nvim uses dual-GPU with  -fitt : safe but contends with main server

Recommendation: (A) — dedicate Iris Xe to the 14B main server.

### Phase 2: Non-GPU Fixes (9 items, no architectural changes)

#### Fix 2.1:  embed.lua:56  — Add  GGML_VULKAN_DISABLE=1  env

  -- Before:
  local ok, pid_or_err = daemon.start_background(args, '.jenova/llama-embed.log', opts.script_dir or '.', '.
jenova/llama-embed.pid')

  -- After:
  local ok, pid_or_err = daemon.start_background(args, '.jenova/llama-embed.log', opts.script_dir or '.', '.
jenova/llama-embed.pid', {GGML_VULKAN_DISABLE="1"})

#### Fix 2.2:  bin/jenova:90  — Remove dead  CODER_ROOT

  # Before:
  export JENOVA_ROOT="${JENOVA_ROOT:-$CODER_ROOT}"

  # After:
  export JENOVA_ROOT="${JENOVA_ROOT}"

#### Fix 2.3:  bin/jenova:102  — Add trap for cleanup

  # Before line 102, wrap cleanup and add trap:
  cleanup_agent() {
      if [ -f "$PID_FILE" ]; then
          if [ -f "$SCRIPT_DIR/jenova-ca" ]; then
              "$SCRIPT_DIR/jenova-ca" stop 2>/dev/null
          elif [ -f "$SCRIPT_DIR/../jenova-ca" ]; then
              "$SCRIPT_DIR/../jenova-ca" stop 2>/dev/null
          fi
      fi
  }
  trap cleanup_agent EXIT INT TERM

  luajit "$AGENT_PATH"
  AGENT_EXIT=$?
  trap - EXIT INT TERM

  exit $AGENT_EXIT

#### Fix 2.4:  proxy.lua:319  — Remove SIGPIPE double-set

Delete line 319:  ffi.C.signal(_ffi_defs.SIGPIPE, ffi.cast("sighandler_t", function() end))

The  SIG_IGN  at line 278 is correct and sufficient.

#### Fix 2.5:  proxy.lua:308  — Increase  COROUTINE_TIMEOUT  to 600

  local COROUTINE_TIMEOUT = 600

#### Fix 2.6:  proxy.lua:383-385  — Wrap sweeper close in pcall

  -- Before:
  ffi.C.close(fd)
  if info.watch_fd and info.watch_fd ~= fd then
      ffi.C.close(info.watch_fd)
  end

  -- After:
  pcall(ffi.C.close, fd)
  if info.watch_fd and info.watch_fd ~= fd then
      pcall(ffi.C.close, info.watch_fd)
  end

#### Fix 2.7:  search.lua:455  — Fix indentation

  -- Before (2-space):
    if not ok then io.write("[search] warning: failed to create .jenova: "..tostring(err).."\n") end

  -- After (4-space):
      if not ok then io.write("[search] warning: failed to create .jenova: "..tostring(err).."\n") end

#### Fix 2.8:  agent.lua:136-168  — Remove dead  assess_complexity

Delete the entire function (lines 136-168). It's defined but never called.

#### Fix 2.9:  bin/jenova-ca  stop verb — Clean  .jenova/llama-embed.pid

After  rm -f "$PID_FILE"  (line ~120), add:

  rm -f "$JENOVA_STATE/llama-embed.pid"

### Phase 3: Documentation

#### Fix 3.1: Update README.md

Sync the GPU section to reflect dual-GPU with auto-fit:

 Item                   │ Current (wrong)          │ Correct
────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────────────────────
 Line 47                │ "Intel Iris Xe not used" │ "Intel Iris Xe (Vulkan1) used as secondary GPU via tensor split"
 Line 53-54             │ NGL 22/15                │ "Auto-tuned via -fitt (typically 28/28 for 7B, ~38/49 for 14B)"
 Line 71                │  DEVICES="Vulkan0"       │  DEVICES="Vulkan0,Vulkan1"
 Line 74                │  CTX_SIZE="16384"        │  CTX_SIZE="8192"  (14B default)

--------

## Implementation Order

1. Phase 1 first — the GPU strategy is the foundation
2. Phase 2 next — all 9 fixes are independent and safe
3. Phase 3 last — documentation follows implementation
