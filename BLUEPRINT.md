# Jenova Cognitive Architecture — Remediation Blueprint

**Date:** 2026-03-26
**Branch:** `build`
**Status:** Approved — implementing

---

## 1. Executive Summary

Comprehensive diagnostic of the Jenova codebase revealed **12 actionable bugs** across the launcher, proxy, agent, embedding, and documentation layers. The most critical finding is a fundamental conflict between `-ngl` (explicit GPU layer count) and `-fitt` (auto-fit target), which causes the llama.cpp fitter to abort on every launch — silently falling back to CPU-only inference despite having ~11 GiB of addressable GPU memory across two Vulkan devices.

This blueprint documents every confirmed bug, the root-cause analysis, and the exact remediation for each.

---

## 2. Hardware Context

| Component | Specification |
|---|---|
| OS | FreeBSD 15 (STABLE/CURRENT) |
| CPU | Intel i5-1135G7 (4P cores / 8 logical threads) |
| GPU 0 | NVIDIA GTX 1650 Ti — 4 GiB discrete VRAM (Vulkan0) |
| GPU 1 | Intel Iris Xe TGL GT2 — UMA, ~7 GiB addressable from system RAM (Vulkan1) |
| Memory | 16 GB DDR4 |
| Swap | 27 GB Intel Optane NVMe (p910, ~7 μs random read) |
| Combined GPU | ~11 GiB addressable across both Vulkan devices |

---

## 3. Architecture Overview

Three persistent daemon processes, managed as a unit by `jenova-ca`:

| Process | Port | Purpose | GPU |
|---|---|---|---|
| `llama-server` | 8081 | Main inference (14B/7B) | Dual Vulkan (auto-fit) |
| `proxy.lua` | 8080 | Non-blocking I/O proxy, RAG injection, intent routing | — |
| `llama-server --embedding` | 8082 | CPU-only embedding (nomic-embed-text-v1.5) | Disabled (`GGML_VULKAN_DISABLE=1`) |

PID tracking: `.jenova/jenova-ca.pid` (3-PID format: `LLAMA_PID PROXY_PID EMBED_PID`)

---

## 4. Critical Finding: -fitt vs -ngl Conflict

### The Problem

`bin/jenova-ca` passes both `-fitt 768` and `-ngl $LLAMA_NGL` to `llama-server`. This causes the fitter to abort unconditionally.

### Root Cause (source-level proof)

**`llama.cpp/src/llama.cpp:327-328`:**
```cpp
if (mparams->n_gpu_layers != default_mparams.n_gpu_layers) {
    throw llama_params_fit_exception("n_gpu_layers already set by user to "
        + std::to_string(mparams->n_gpu_layers) + ", abort");
}
```

**`llama.cpp/common/common.h:382`:** `n_gpu_layers` default is `-1` ("auto").

**`llama.cpp/common/arg.cpp:2322-2338`:** `-ngl` parsing: `"auto"` → `-1`, `"all"` → `-2`, number → explicit value.

ANY explicit `-ngl` value (0, 33, 99, "all"/-2) sets `n_gpu_layers != -1`, causing the fitter to throw. The fitter only runs when `n_gpu_layers` remains at its default `-1`.

### Evidence from Logs

- `var/log/jenova-ca.log:21` — `"n_gpu_layers already set by user to 99, abort"` (when `-ngl all`)
- `var/log/server.log:25` — `"n_gpu_layers already set by user to -2, abort"` (when `-ngl 33` mapped to `-2`)
- `var/log/jenova-ca.runlog` — **Fitter SUCCEEDED when `-ngl` was omitted**: auto-distributed 38/49 layers across both GPUs with proper memory margins

### Fix

**Drop `-ngl` from all `llama-server` launch commands.** Let `-fitt $FIT_TARGET` handle layer distribution automatically. The `NGL_7B`/`NGL_14B` config variables remain for banner display and documentation reference only.

---

## 5. Bug Inventory & Remediation Plan

### Phase 1: GPU Strategy (Critical)

#### Bug 1.1 — `-ngl` kills `-fitt` auto-tuning
- **File:** `bin/jenova-ca` lines 186, 239
- **Symptom:** Fitter aborts, falls back to CPU-only inference
- **Fix:** Remove `-ngl "$LLAMA_NGL"` from both daemon and foreground launch commands
- **Also:** Line 96 — hardcoded `768`; change to `$FIT_TARGET` so conf variable is respected

### Phase 2: Non-GPU Bug Fixes

#### Bug 2.1 — `embed.lua` self-start missing `GGML_VULKAN_DISABLE=1`
- **File:** `lib/embed.lua` line 56
- **Symptom:** If embed.lua self-starts the embedding server (when jenova-ca hasn't started it), Vulkan is not disabled — the embedding server would try to use GPU, contending with main inference
- **Fix:** Add `{GGML_VULKAN_DISABLE="1"}` as 5th argument to `daemon.start_background()`
- **Note:** `jenova-ca` correctly sets this env var (lines 205, 260); only the Lua self-start path is missing it

#### Bug 2.2 — Dead `CODER_ROOT` reference in `bin/jenova`
- **File:** `bin/jenova` line 90
- **Current:** `export JENOVA_ROOT="${JENOVA_ROOT:-$CODER_ROOT}"`
- **Problem:** `CODER_ROOT` is undefined — leftover from an earlier naming. Falls back to empty string if `JENOVA_ROOT` is also unset
- **Fix:** `export JENOVA_ROOT="${JENOVA_ROOT}"`

#### Bug 2.3 — No trap for cleanup in `bin/jenova`
- **File:** `bin/jenova` lines 102-115
- **Symptom:** If the agent is interrupted (Ctrl-C, SIGTERM), the cleanup block at lines 107-113 never runs — jenova-ca continues running orphaned
- **Fix:** Wrap cleanup in a function, add `trap cleanup_agent EXIT INT TERM` before the luajit call, clear trap after

#### Bug 2.4 — SIGPIPE double-set with GC-able callback in `proxy.lua`
- **File:** `lib/proxy.lua` line 319
- **Problem:** Line 278 correctly sets `SIGPIPE → SIG_IGN`. Line 319 overrides it with `ffi.cast("sighandler_t", function() end)` — an anonymous Lua closure cast to a C function pointer. If GC collects the closure, the signal handler becomes a dangling pointer → SIGSEGV
- **Fix:** Delete line 319 entirely. Line 278's `SIG_IGN` is sufficient and non-GC-able.

#### Bug 2.5 — `COROUTINE_TIMEOUT` too short (120s vs 600s server timeout)
- **File:** `lib/proxy.lua` line 308
- **Problem:** `COROUTINE_TIMEOUT = 120` means the proxy sweeper kills connections after 2 minutes. But `etc/jenova.conf` sets `TIMEOUT=600` and 14B inference on this hardware can take 3-5 minutes for complex prompts
- **Fix:** Change to `local COROUTINE_TIMEOUT = 600`

#### Bug 2.6 — Bare `ffi.C.close()` in sweeper can throw
- **File:** `lib/proxy.lua` lines 383-385
- **Problem:** The stale-coroutine sweeper calls `ffi.C.close(fd)` directly. If the fd is already closed (race with coroutine cleanup), this returns EBADF which LuaJIT's FFI can propagate as an error. The clean shutdown block (lines 393-398) correctly uses `pcall(ffi.C.close, fd)`.
- **Fix:** Wrap both close calls in pcall, matching the shutdown pattern

#### Bug 2.7 — Indentation error in `search.lua`
- **File:** `lib/search.lua` line 455
- **Current:** 2-space indent inside a 4-space block
- **Fix:** Re-indent to 4 spaces

#### Bug 2.8 — Dead `assess_complexity` function in `agent.lua`
- **File:** `lib/agent.lua` lines 136-168
- **Problem:** 33-line function that is never called anywhere in the codebase (confirmed via grep)
- **Fix:** Delete the entire function

#### Bug 2.9 — `llama-embed.pid` not cleaned in stop verb
- **File:** `bin/jenova-ca` lines 103-126
- **Problem:** The stop verb cleans `jenova-ca.pid` (line 119) and pkills embed processes (line 124), but never removes `.jenova/llama-embed.pid`. This stale PID file causes `daemon.start_background()` to think the embed server is already running (returns early at line 62-64 of daemon.lua)
- **Evidence:** `.jenova/llama-embed.pid` contains stale PID 41945
- **Fix:** Add `rm -f "$JENOVA_STATE/llama-embed.pid"` after `rm -f "$PID_FILE"` in the stop verb

### Phase 3: Documentation

#### Bug 3.1 — README.md contradicts actual configuration
- **File:** `README.md` lines 47, 53-54, 71, 74
- **Errors:**
  - Line 47: Claims Iris Xe is "not used" — **false**, it's Vulkan1 in `DEVICES=Vulkan0,Vulkan1`
  - Lines 53-54: Claims NGL 22/15 — actual conf has `all`/`33` (and neither matters now since fitter auto-tunes)
  - Line 71: Claims `DEVICES="Vulkan0"` — actual is `Vulkan0,Vulkan1`
  - Line 74: Claims `CTX_SIZE="16384"` — actual default is `8192` for 14B
- **Fix:** Rewrite GPU section to reflect dual-GPU auto-fit architecture

---

## 6. Deferred: `bin/llama-server-nvim`

Per user instruction, nvim integration is deferred to a later session. Notes for when it's addressed:

- Currently uses `$DEVICES` (dual-GPU) + `$NGL_7B` — same `-ngl`/`-fitt` conflict applies
- **Option A (recommended):** NVIDIA-only: `-dev Vulkan0 -ngl all` — 7B fits entirely in 4 GiB discrete VRAM, leaving Iris Xe free for the main 14B server
- **Option B:** Dual-GPU with `-fitt` — safe but contends with main server for Iris Xe memory
- Recommendation is Option A if nvim FIM and main server run simultaneously

---

## 7. Implementation Order

```
Phase 1: GPU Strategy
  1.1  bin/jenova-ca   — Remove -ngl, use $FIT_TARGET in SPLIT_ARGS

Phase 2: Bug Fixes
  2.1  lib/embed.lua   — Add GGML_VULKAN_DISABLE=1 env arg
  2.2  bin/jenova:90   — Remove dead CODER_ROOT reference
  2.3  bin/jenova      — Add trap for cleanup
  2.4  lib/proxy.lua   — Delete SIGPIPE double-set (line 319)
  2.5  lib/proxy.lua   — COROUTINE_TIMEOUT = 600
  2.6  lib/proxy.lua   — pcall in sweeper close
  2.7  lib/search.lua  — Fix indentation
  2.8  lib/agent.lua   — Delete dead assess_complexity
  2.9  bin/jenova-ca   — Add llama-embed.pid cleanup to stop verb

Phase 3: Documentation
  3.1  README.md       — Rewrite GPU section for dual-GPU auto-fit
```

---

## 8. Verification Checklist

After all changes:

- [ ] `bin/jenova-ca` launches llama-server WITHOUT `-ngl` in both daemon and foreground modes
- [ ] `SPLIT_ARGS` uses `$FIT_TARGET` not hardcoded `768`
- [ ] Stop verb cleans both `jenova-ca.pid` and `llama-embed.pid`
- [ ] `embed.lua` passes `GGML_VULKAN_DISABLE=1` env to daemon.start_background
- [ ] `bin/jenova` has no `CODER_ROOT` reference and has proper trap
- [ ] `proxy.lua` has exactly ONE `SIGPIPE` handler (line 278: `SIG_IGN`)
- [ ] `proxy.lua` `COROUTINE_TIMEOUT` = 600
- [ ] `proxy.lua` sweeper uses pcall for close
- [ ] `search.lua` line 455 uses 4-space indent
- [ ] `agent.lua` has no `assess_complexity` function
- [ ] `README.md` documents dual-GPU auto-fit, not single-GPU with explicit NGL
- [ ] No references to removed/changed variables are broken
- [ ] Banner still displays useful GPU info

---

*Blueprint generated from consolidated diagnostic of paste_3409210814, paste_2134040059, paste_4112011921, and paste_4213159784.*
