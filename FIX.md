# Jenova Fix Ledger

**Updated:** 2026-03-27
**Branch:** `claude/roadmap-alignment-y91ZF`

All items in this ledger are **resolved**. The codebase has been fully audited and fixed in the cohesion pass commit.

---

## Resolved Items

### GPU Strategy
- [x] **Bug 1.1** — `-ngl` conflicted with `-fitt`: removed from all launch commands (`bin/jenova-ca`)
- [x] **Bug 1.2** — `bin/llama-server-nvim` spawned a second llama-server on port 8012 using the same 7B model, competing for GPU memory and bypassing the proxy. Rewritten: now ensures jenova-ca is running via the shared health-check pattern and exits. Neovim connects to `:8081` (FIM) or `:8080` (chat+RAG).
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

## Hardware Optimization Pass — 2026-03-26

- [x] **Tensor split corrected** — `TENSOR_SPLIT` changed from `2.0,1.0` to `1.0,1.8` in `etc/jenova.conf`. Previous ratio over-allocated NVIDIA (4 GiB VRAM) relative to Intel Xe (~7 GiB UMA); new ratio lets Intel carry more layers while keeping NVIDIA within its discrete VRAM budget.
- [x] **Ubatch raised** — `-ub 256` → `-ub 512` in both daemon and foreground launch paths in `bin/jenova-ca`. Improves GPU kernel utilisation during prompt prefill on dual-Vulkan setup.
- [x] **Speculative decoding on by default** — `JENOVA_DRAFT` defaults to `1` in `etc/jenova.conf`; condition in `bin/jenova-ca` updated from `[ -n "$JENOVA_DRAFT" ]` to `[ "${JENOVA_DRAFT:-1}" != "0" ]`. The 0.5B drafter (Qwen2.5-Coder-0.5B-Q8_0) now loads automatically. Set `JENOVA_DRAFT=0` to disable.
- [x] **README config example** — `TENSOR_SPLIT` and `CTX_SIZE` examples corrected to match current values (`1.0,1.8`, `16384`).

---

## Search & Agent Cohesion Pass — 2026-03-26

- [x] **`bm25_index_file` stale entries on skip** — Early returns for >100KB files, binary files, and zero-term files now evict the old entry from `bm25_index`, `df`, and `total_docs` before returning nil. Previously, calling `reindex_file` on a file that had grown large or become binary left stale BM25 data that persisted in search results.
- [x] **`/reindex` extension filter** — `search.index_dir(".")` in the `/reindex` slash command now passes the same extension whitelist as the startup index. Previously it indexed all file types (minus hardcoded exclusions), polluting BM25 with noise.
- [x] **`search.lua` line formatting** — `ok_mkdir` error handler was jammed on the same line as the preceding `end)`, making it effectively invisible. Split to separate lines.

---

## Neovim Config Audit — 2026-03-26

- [x] **`init.lua` llama.vim endpoint** — `vim.g.llama_config` pointed to `/completion` (non-existent). Corrected to `/v1/chat/completions` (the only POST endpoint on the proxy). Ghost-text completion now routes through the intelligence proxy with RAG injection.
- [x] **`init.lua` `<leader>ca` keybind** — Referenced `./jenova-agent` which does not exist. Fixed to `cd ~/Projects/jenova && bin/jenova`.

---

---

## Roadmap Alignment Audit — 2026-03-27

Full cross-module audit of all BLUEPRINT items against actual source code. Seven issues found and fixed:

- [x] **Dead `LLAMA_NGL` variable** — `bin/jenova-ca` still assigned `LLAMA_NGL` (from removed `-ngl` flag) and printed it in the startup banner as "GPU Layers: all". Removed dead variable; banner now shows "GPU: auto-fit" with tensor split and fit target.
- [x] **`JENOVA_ROOT` unconditional override** — `bin/jenova-ca` lines 49/52 clobbered user-set `JENOVA_ROOT` env var. Changed to `${JENOVA_ROOT:-...}` conditional assignment.
- [x] **`lib/embed.lua` stale `CTX_SIZE=2048`** — Local variable was 2048 while server launches with `-c 4096`. Updated to 4096.
- [x] **`agent.lua` check_server accepted 502/503** — `try_health()` accepted 502/503 as healthy, contradicting BLUEPRINT healthcheck fix. Now only accepts 200.
- [x] **`grep_search` missing from system prompt** — Tool was defined with a handler but not listed in the model's system prompt. Added to prompt.
- [x] **Proxy lacked native `/health` endpoint** — `GET /health` was forwarded to llama-server. Added native handler with JSON status response (proxy state + backend connectivity).
- [x] **`tests/test_bin_jenova.sh` missing** — Referenced in BLUEPRINT but never created. Added with 8 test cases covering config, modules, health check, PID format, cleanup guard, and trap.

---

---

## Open Items — Known Limitations

### Web Search in jvim — Non-functional (Deferred)

**Status:** Known limitation — documented for future fix
**Severity:** Low (non-critical feature; all other AI features work)
**Affected files:** `lib/proxy.lua:124-160`, `nvim/lua/plugins/gp.lua:92-121`, `lib/prompts.lua:33-41`

**Root Cause 1 — Platform-specific HTTP client:**
`exec_web_search()` in `lib/proxy.lua:129` uses FreeBSD's native `fetch` command:
```
fetch -T 5 -qo - 'https://html.duckduckgo.com/html/?q=...'
```
`fetch` is a FreeBSD-native utility (part of the base system). It does not exist on Linux.
On Linux, `io.popen(cmd)` silently returns nil, and the function returns nil.

**Root Cause 2 — Silent failure path:**
When `exec_web_search()` returns nil, the proxy simply proceeds without web results.
No error is logged, and the user receives a normal chat response without any indication
that the search failed. The chat proceeds as if websearch was never requested.

**Root Cause 3 — HTTPS requirement:**
DuckDuckGo requires HTTPS. The project's built-in `lib/http.lua` only supports plain
HTTP (raw BSD sockets via LuaJIT FFI). This is why websearch shells out to `fetch`
rather than using the internal HTTP library.

**User-visible behavior:**
- `<leader>as` (Web Search) opens a chat, sends the query, but the model responds
  without any web search context — effectively a normal chat response.
- No error message or notification is shown.

**Future fix options (not implemented — deferred):**
1. Add `curl` fallback: `curl -sL --max-time 5 'URL'` works on both FreeBSD and Linux
2. Add error feedback: log a warning and notify the user when web search fails
3. Long-term: implement HTTPS in `lib/http.lua` using LuaJIT FFI + OpenSSL bindings

**Workaround:** On FreeBSD (the target platform), `fetch` is available in the base
system and websearch should work as designed, provided the system has outbound HTTPS
access to `html.duckduckgo.com`.
