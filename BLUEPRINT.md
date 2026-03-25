# Jenova Cognitive Architecture — Remediation Blueprint

**Date:** 2026-03-26 (updated 2026-03-25)
**Branch:** `build`
**Status:** All phases implemented ✅

---

## 1. Summary

All bugs documented in this blueprint have been fixed. The codebase now runs exclusively on the **7B model** (Qwen2.5-Coder-7B-Q5_K_M) with full dual-GPU auto-fit, 16k context, 2 slots, and q8_0 quantized KV cache.

---

## 2. Hardware Context

| Component | Specification |
|---|---|
| OS | FreeBSD 15 (STABLE/CURRENT) |
| CPU | Intel i5-1135G7 (4P cores / 8 logical threads) |
| GPU 0 | NVIDIA GTX 1650 Ti — 4 GiB discrete VRAM (Vulkan0) |
| GPU 1 | Intel Iris Xe TGL GT2 — UMA, ~7 GiB addressable from system RAM (Vulkan1) |
| Memory | 16 GB DDR4 |
| Swap | 27 GB Intel Optane NVMe (~7 μs random read) |
| Combined GPU | ~11 GiB addressable across both Vulkan devices |

---

## 3. Architecture Overview

Three persistent daemon processes, managed as a unit by `jenova-ca`:

| Process | Port | Purpose | GPU |
|---|---|---|---|
| `llama-server` | 8081 | Main inference (7B, 16k ctx, 2 slots) | Dual Vulkan auto-fit |
| `proxy.lua` | 8080 | Async I/O proxy, RAG injection, intent routing | — |
| `llama-server --embedding` | 8082 | CPU-only embedding (nomic-embed-text-v1.5, 4k ctx) | Disabled (`GGML_VULKAN_DISABLE=1`) |

PID tracking: `.jenova/jenova-ca.pid` (space-separated, no "0" placeholders)

---

## 4. Bug Inventory — Current Status

### Phase 1: GPU Strategy ✅ Fixed

#### Bug 1.1 — `-ngl` conflicted with `-fitt` auto-tuning
- **Fix:** Removed `-ngl` from all launch commands. `-sm layer -fitt $FIT_TARGET` handles layer distribution.
- **Status:** ✅ Fixed in `bin/jenova-ca`, `bin/llama-server-nvim`

### Phase 2: Non-GPU Bug Fixes ✅ All Fixed

#### Bug 2.1 — `embed.lua` missing `GGML_VULKAN_DISABLE=1`
- **Status:** ✅ Fixed — `{GGML_VULKAN_DISABLE="1"}` passed to `daemon.start_background()`

#### Bug 2.2 — Dead `CODER_ROOT` reference in `bin/jenova`
- **Status:** ✅ Fixed — removed; `JENOVA_ROOT` used directly

#### Bug 2.3 — No trap in `bin/jenova`
- **Status:** ✅ Fixed — `cleanup_agent()` + `trap cleanup_agent EXIT INT TERM` added; now guards with `STARTED_BY_THIS_INVOCATION` so pre-existing daemons are not stopped on agent exit

#### Bug 2.4 — SIGPIPE double-set in `proxy.lua`
- **Status:** ✅ Verified not present — `ffi.C.signal(_ffi_defs.SIGPIPE, _ffi_defs.SIG_IGN)` is the only SIGPIPE handler; no GC-able closure override found in current code

#### Bug 2.5 — `COROUTINE_TIMEOUT` too short
- **Status:** ✅ Fixed — `COROUTINE_TIMEOUT = 600` in `lib/proxy.lua`

#### Bug 2.6 — Bare `ffi.C.close()` in sweeper
- **Status:** ✅ Fixed — sweeper uses `pcall(ffi.C.close, fd)` with timeout logging

#### Bug 2.7 — `search.lua` indentation error
- **Status:** ✅ Fixed

#### Bug 2.8 — Dead `assess_complexity` in `agent.lua`
- **Status:** ✅ Verified not present in current `lib/agent.lua`

#### Bug 2.9 — `jenova-ca stop` didn't clean `llama-embed.pid`
- **Status:** ✅ Fixed — `rm -f "$JENOVA_STATE/llama-embed.pid"` added to stop verb

### Phase 3: Documentation ✅ Updated

#### Bug 3.1 — README/docs contradicted actual configuration
- **Status:** ✅ Updated — BLUEPRINT.md and FIX.md refreshed to match current code

---

## 5. Additional Fixes (from cohesion pass)

All items from the inline code review have been applied:

- `bin/jenova-ca` — 14B model removed; KV cache type (`-ctk/-ctv q8_0`) added; embed server ctx raised to 4096; `--cache-prompt` added
- `lib/ffi_defs.lua` — `F_GETFL`, `F_SETFD`, `FD_CLOEXEC`, `pipe()`, `read()`, `write()` added
- `lib/daemon.lua` — parent/child pipe handshake ensures exec success before pidfile write
- `lib/proxy.lua` — `LLAMA_HOST` extracted from `LLAMA_URL`; `set_nonblocking` preserves existing flags via `F_GETFL`; chunked terminator uses `body_raw:sub(-5)` plain comparison; system content merged not overwritten; `async_send` result checked; timeout logging added; unused `fd` → `_fd`
- `lib/http.lua` — `send_all` retries `EAGAIN/EWOULDBLOCK/ETIMEDOUT`; HTTPS scheme rejected early
- `lib/embed.lua` — `initialized` reset to `false` at start of `embed.init()` and on all failure paths; embed server ctx raised to 4096
- `lib/healthcheck.lua` — only HTTP 200 treated as healthy
- `lib/indexer_runner.lua` — queue not deleted when `embed.init()` fails
- `lib/search.lua` — atomic queue write (temp file + rename); `save_vectors` merges on-disk state and writes atomically
- `lib/agent.lua` — HTTP 499 retryable; `trim_messages` seeds from fresh system prompt; `CONTEXT_WINDOW` default raised to 16384; 14B architecture note updated for 7B
- `lib/chat.lua` — `data.choices[1]` existence guarded with `#data.choices > 0`
- `lib/ui.lua` — `HEADER_SMALL` used as intermediate fallback (30–52 cols)
- `jenova-setup` — regex metacharacters escaped in `sysctl_persist`; page counts computed from runtime `PAGESIZE`; nvme sysctl keys tested independently
- `tests/` — all test scripts: conf file guarded; preflight checks added; hardcoded `Vulkan0` replaced with `$DEVICES`; exit codes tracked

