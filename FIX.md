# Jenova Fix Ledger

**Updated:** 2026-03-25 (cohesion pass complete)
**Branch:** `build`

All items in this ledger are **resolved**. The codebase has been fully audited and fixed in the cohesion pass commit.

---

## Resolved Items

### GPU Strategy
- [x] **Bug 1.1** — `-ngl` conflicted with `-fitt`: removed from all launch commands (`bin/jenova-ca`, `bin/llama-server-nvim`)
- [x] **14B model removed** — codebase now targets 7B (Qwen2.5-Coder-7B-Q5_K_M) exclusively; 16k context, 2 slots, q8_0 KV cache

### Launcher / Scripts
- [x] **Bug 2.2** — Dead `CODER_ROOT` reference: removed from `bin/jenova`
- [x] **Bug 2.3** — No cleanup trap in `bin/jenova`: `cleanup_agent()` + `STARTED_BY_THIS_INVOCATION` guard added
- [x] **Bug 2.9** — `jenova-ca stop` didn't clean `llama-embed.pid`: fixed
- [x] **PID "0" placeholder** — `bin/jenova-ca` pidfile never writes "0" for missing embed PID
- [x] **KV cache type** — `bin/jenova-ca` now passes `-ctk q8_0 -ctv q8_0` and `--cache-prompt`
- [x] **Embed server ctx** — raised from 2048 → 4096 tokens in both `bin/jenova-ca` and `lib/embed.lua`

### Proxy (`lib/proxy.lua`)
- [x] **Bug 2.4** — SIGPIPE double-set: not present in current code (SIG_IGN is sole handler)
- [x] **Bug 2.5** — `COROUTINE_TIMEOUT=120`: already 600 in current code
- [x] **Bug 2.6** — Bare `ffi.C.close()` in sweeper: now wrapped in `pcall` with timeout logging
- [x] **`LLAMA_HOST` extraction** — host parsed from `LLAMA_URL`; backend connect uses `LLAMA_HOST`
- [x] **`embed_err` → `embed_res`** — renamed for clarity
- [x] **`set_nonblocking` F_GETFL** — now preserves existing fd flags before setting O_NONBLOCK
- [x] **Chunked terminator** — `body_raw:find("0\r\n\r\n$")` fixed to `body_raw:sub(-5) ~= "0\r\n\r\n"`
- [x] **System content overwrite** — intent branch now merges (`system_p .. "\n\n" .. existing`) instead of replacing
- [x] **`async_send` unchecked** — return value checked; aborts if send fails before recv loop
- [x] **Timeout logging** — sweep loop logs fd, age, and COROUTINE_TIMEOUT before closing
- [x] **Unused `fd` variable** — renamed `_fd` in the FD_SET loop

### FFI / Daemon (`lib/ffi_defs.lua`, `lib/daemon.lua`)
- [x] **Missing constants** — `F_GETFL`, `F_SETFD`, `FD_CLOEXEC` added to `ffi_defs.lua`
- [x] **Missing syscalls** — `pipe()`, `read()`, `write()` added to `ffi_defs.lua`
- [x] **Daemon handshake** — `daemon.start_background` uses parent/child pipe so parent only writes pidfile after confirmed exec

### HTTP / Network (`lib/http.lua`)
- [x] **`send_all` transient errors** — EAGAIN/EWOULDBLOCK/ETIMEDOUT now retry instead of hard-fail
- [x] **HTTPS rejection** — `http.post` and `http.get` return error immediately for `https://` URLs

### Embeddings (`lib/embed.lua`)
- [x] **Bug 2.1** — `GGML_VULKAN_DISABLE=1` was missing from Lua self-start path: fixed
- [x] **`initialized` flag** — reset to `false` at start of `embed.init()` and on all failure paths

### Agent (`lib/agent.lua`)
- [x] **HTTP 499 retryable** — `http_post_retry` now treats 499 same as 5xx (socket transport error)
- [x] **`trim_messages` system prompt** — seeds `new_messages` with fresh `build_system_prompt()` not `messages[1]`
- [x] **`CONTEXT_WINDOW` default** — raised from 8192 → 16384 to match 7B conf
- [x] **14B architecture comment** — updated to reflect 7B tool call behavior

### Chat (`lib/chat.lua`)
- [x] **`choices[1]` guard** — `#data.choices > 0` check added before indexing

### Health Check (`lib/healthcheck.lua`)
- [x] **502/503 as success** — removed; only HTTP 200 triggers `os.exit(0)`

### Indexer (`lib/indexer_runner.lua`)
- [x] **Queue deleted on embed failure** — queue file and `process_embedding_queue` now skipped if `embed.init()` returns false

### Search (`lib/search.lua`)
- [x] **Bug 2.7** — indentation error: fixed
- [x] **Race condition in queue write** — unique temp file written first, then `os.rename` to final path after pidfile check
- [x] **`save_vectors` atomic write** — merges existing on-disk vectors then writes atomically via `.tmp` + `os.rename`

### UI (`lib/ui.lua`)
- [x] **`HEADER_SMALL` unused** — added as intermediate fallback (30–52 cols) in `ui.draw_header`

### Setup (`jenova-setup`)
- [x] **Regex metacharacter escaping** — `sysctl_persist` escapes `_key` before use in `grep -E` / `sed`
- [x] **Hardcoded page counts** — replaced with `getconf PAGESIZE`-derived `FREE_PAGES` / `INACTIVE_PAGES`
- [x] **NVMe coalesce knobs** — each sysctl key tested independently before calling `apply_sysctl`

### Tests
- [x] **`tests/test_gpu_single.sh`** — conf file guarded; preflight checks added; `Vulkan0` derives from `$DEVICES`
- [x] **`tests/test_gpu.sh`** — conf guarded; preflight checks; hardcoded `-dev Vulkan0` replaced with `$DEVICES`; `-ngl` replaced with `-sm layer -fitt $FIT_TARGET`
- [x] **`tests/download-draft-model.sh`** — echo fallback path corrected to `$SCRIPT_DIR/../llama.cpp/...`
- [x] **`test_bin_jenova.sh`** — preflight check for `jenova-ca`; `EXIT_CODE` tracks health check failures
- [x] **`README.md` dual-GPU notes** — docs already reflect current dual-GPU auto-fit config

---

*No outstanding items.*
