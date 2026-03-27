# Jenova Cognitive Architecture — Remediation Blueprint

**Date:** 2026-03-27
**Branch:** `claude/roadmap-alignment-y91ZF`
**Status:** All phases implemented ✅ — Alignment audit pass applied

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
- **Status:** ✅ Fixed in `bin/jenova-ca`

#### Bug 1.2 — `bin/llama-server-nvim` spawned a duplicate model instance

- **Root cause:** Script was `exec`'ing a second `llama-server` on port 8012 with the same 7B model, causing double VRAM load and bypassing the proxy entirely (no RAG injection for Neovim).
- **Fix:** Rewritten as a "ensure jenova-ca is running" helper. Starts the shared backend via `jenova-ca --daemon` if not already up, waits for health, then exits. All clients (CLI, Neovim, HTTP) now share the single model instance.
- **Neovim endpoints:** FIM/infill → `:8081` (direct, `--spm-infill` enabled); chat + RAG → `:8080` (proxy).
- **Status:** ✅ Fixed in `bin/llama-server-nvim`

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

## 5. Hardware Optimization Pass (2026-03-26)

Performed a deep analysis of the compiled llama.cpp build against actual hardware capabilities. Three changes applied:

### Opt 1 — Tensor split corrected: `2.0,1.0` → `1.0,1.8`
- **Previous:** NVIDIA was assigned 2/3 of model layers despite having only 4 GiB discrete VRAM.
- **Fix:** Ratio flipped to reflect actual VRAM budget: Intel Xe has ~7 GiB UMA (vs 4 GiB NVIDIA), so Intel carries more layers. NVIDIA's faster GDDR6 still handles its share cleanly within its 4 GiB limit.
- **File:** `etc/jenova.conf` — `TENSOR_SPLIT`

### Opt 2 — Ubatch raised: `256` → `512`
- **Previous:** `-ub 256` under-utilised Vulkan compute queues during prompt prefill.
- **Fix:** Doubled to 512 for better GPU kernel saturation with dual-GPU Vulkan.
- **File:** `bin/jenova-ca` — both daemon and foreground launch paths

### Opt 3 — Speculative decoding enabled by default
- **Previous:** Draft model was configured but gated behind opt-in `JENOVA_DRAFT` env var (empty = off).
- **Fix:** `JENOVA_DRAFT` defaults to `1` in `etc/jenova.conf`. Condition in `bin/jenova-ca` updated to treat `JENOVA_DRAFT=0` as the explicit disable signal. The 0.5B Qwen2.5-Coder drafter now loads automatically alongside the 7B target.
- **Files:** `etc/jenova.conf`, `bin/jenova-ca`

---

## 6. Additional Fixes (from cohesion pass)

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

---

## 7. Search & Agent Cohesion Pass (2026-03-26)

Additional integration issues found and fixed after comprehensive cross-module analysis:

#### Bug 7.1 — `bm25_index_file` stale entries on filtered-out files

- **Root cause:** Early returns for files >100KB, binary files, and zero-term files skipped the stale-entry cleanup (`df` decrement, `total_docs` decrement, `bm25_index[filepath] = nil`). If `reindex_file` was called after a file grew above the 100KB threshold, the old terms remained in the BM25 index indefinitely.
- **Fix:** All three early-return paths in `bm25_index_file` now evict the existing entry before returning nil.
- **Status:** ✅ Fixed in `lib/search.lua`

#### Bug 7.2 — `/reindex` command dropped extension filter

- **Root cause:** `search.index_dir(".")` in the `/reindex` slash command was called without an extension array. The initial startup index uses an explicit whitelist (`lua`, `sh`, `c`, `h`, etc.), so `/reindex` produced a wider index that included all non-excluded file types.
- **Fix:** `/reindex` now passes the identical extension array as the startup index.
- **Status:** ✅ Fixed in `lib/agent.lua`

#### Bug 7.3 — `search.lua` formatting: double-statement on single line

- **Root cause:** `ok_mkdir` error handler was placed immediately after `end)` on the same line (no newline), making it visually invisible.
- **Fix:** Split to separate lines.
- **Status:** ✅ Fixed in `lib/search.lua`

---

## 8. Resource & Memory Management Pass (2026-03-26)

Deep analysis of all Lua modules for memory leaks, unbounded allocations, FD leaks, and disk exhaustion. Eight issues found and fixed.

### Issue 8.1 — `session_action_index` unbounded growth (`lib/memory.lua`)
- **Root cause:** Every unique action key created an entry in `session_action_index` that was never evicted. While `session_actions` (the sequential history) was capped at 200, the backing index map had no size limit. Over long sessions with many unique commands, the map could grow without bound.
- **Fix:** Added `MAX_INDEX_KEYS = 400` cap with insertion-order tracking (`session_action_key_order`). When the limit is exceeded, the oldest quarter of entries are evicted. The order tracker is reset in `memory.clear_session()` and `memory.init()`.
- **Status:** ✅ Fixed in `lib/memory.lua`

### Issue 8.2 — `session_errors` unbounded growth (`lib/memory.lua`)
- **Root cause:** `session_errors` was appended to indefinitely within a session. `memory.gc()` is only called at init, so in-memory errors accumulated with no cap for the lifetime of the process.
- **Fix:** Added `MAX_SESSION_ERRORS = 100`. When the cap is exceeded in `memory.log_error()`, the oldest half is trimmed (keeping the newest 50 entries).
- **Status:** ✅ Fixed in `lib/memory.lua`

### Issue 8.3 — `io.popen()` FD leak in `file_mtime()` (`lib/search.lua`)
- **Root cause:** If `pcall(p.read, p, "*l")` raised an exception (rare but possible), the error path `if not ok then return 0 end` executed before `p:close()`, leaking the pipe FD. Called in a loop during directory indexing, this could exhaust the 8192 FD limit on FreeBSD.
- **Fix:** Close the handle before returning on the error path: `if not ok then p:close(); return 0 end`.
- **Status:** ✅ Fixed in `lib/search.lua`

### Issue 8.4 — Shell output fully buffered before truncation (`lib/agent.lua`)
- **Root cause:** `exec_shell()` read the entire tmpfile with `f:read("*a")` before truncating to 8000 chars. A command producing 1GB+ output (e.g., a run-away loop) would load the full output into the LuaJIT heap before the guard fired — potentially causing OOM on a 16GB system.
- **Fix:** Replaced full read with a head+tail capped read: reads first 8KB from the file start, then if the file exceeds 10KB also reads the final 2KB. This caps heap usage at ~10KB regardless of actual output size while still capturing both leading context and trailing errors.
- **Status:** ✅ Fixed in `lib/agent.lua`

### Issue 8.5 — Backup files accumulate without bound (`lib/agent.lua`)
- **Root cause:** Both `exec_edit_file()` and `exec_write_file()` created timestamped backups in `.jenova/backups/` on every invocation with no rotation policy. Over hundreds of edits, the backup directory would grow without bound and eventually fill available disk.
- **Fix:** Added `prune_backups(bk_dir, basename)` helper and `MAX_BACKUPS_PER_FILE = 5` constant. After each backup is written, all older backups for the same filename are pruned, keeping only the 5 most recent. Also standardised the timestamp format to `%Y%m%d_%H%M%S` in both functions (was `%H%M%S` in `write_file`, causing name collisions across days).
- **Status:** ✅ Fixed in `lib/agent.lua`

### Issue 8.6 — Vector file fully loaded into heap on every save (`lib/search.lua`)
- **Root cause:** `search.save_vectors()` merged in-memory vec_index with the on-disk `vectors.json` by reading the entire file (`ef:read("*a")`) before JSON-decoding it. With 600 indexed files at multiple chunks each, vectors.json could exceed 10–20MB, causing a large memory spike on every reindex.
- **Fix:** Added a `MAX_VECTOR_MERGE_BYTES = 20MB` guard. If the on-disk file exceeds this limit, the merge is skipped and the in-memory index overwrites the file directly. The skip is logged to stderr. Below the cap, behaviour is unchanged (merge protects concurrent background indexer results).
- **Status:** ✅ Fixed in `lib/search.lua`

### Issue 8.7 — `COROUTINE_TIMEOUT` not configurable (`lib/proxy.lua`)
- **Root cause:** The 600-second connection timeout was hardcoded. With `MAX_ACTIVE_CONNECTIONS = 6`, a stalled client could hold one of the 6 slots for the full 10 minutes. On slow hardware or under load, this could exhaust all available slots.
- **Fix:** `COROUTINE_TIMEOUT` now reads from `JENOVA_CONN_TIMEOUT` environment variable with 600 as default: `tonumber(os.getenv("JENOVA_CONN_TIMEOUT")) or 600`.
- **Status:** ✅ Fixed in `lib/proxy.lua`

### Issue 8.8 — `exec_write_file` backup indentation inconsistency (`lib/agent.lua`)
- **Root cause:** Minor: `if not ok_bkdir2 then` was indented at the wrong level, obscuring the control flow. The `ok_bkdir2` variable name also shadowed the outer `ok_bkdir` without differentiation.
- **Fix:** Fixed indentation to match surrounding code as part of the backup rotation refactor.
- **Status:** ✅ Fixed in `lib/agent.lua`

### Environment variable reference

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_CONN_TIMEOUT` | `600` | Max seconds a proxy coroutine may live before forced close |
| `JENOVA_MAX_TURNS` | `25` | Max agentic tool-call turns per user message |
| `JENOVA_TIMEOUT` | `600` | HTTP timeout for agent → llama-server requests |
| `JENOVA_CTX` | `16384` | Context window token limit |
| `JENOVA_DEBUG` | `""` | Set to `1` to enable verbose debug output |

---

## 9. Roadmap Alignment Audit (2026-03-27)

Full cross-module audit verifying all BLUEPRINT items against actual code. Seven issues found and fixed.

#### Bug 9A.1 — Dead `LLAMA_NGL` variable in `bin/jenova-ca`

- **Root cause:** Bug 1.1 removed `-ngl` from all launch commands, but the `LLAMA_NGL` variable assignment and its use in the startup banner were left behind. The banner printed "GPU Layers: all" misleadingly when the actual mechanism is `-fitt` auto-tuning.
- **Fix:** Removed dead `LLAMA_NGL` assignment. Updated banner to show "GPU: auto-fit" with tensor split and fit target info.
- **Status:** ✅ Fixed in `bin/jenova-ca`

#### Bug 9A.2 — `JENOVA_ROOT` unconditional override in `bin/jenova-ca`

- **Root cause:** Lines 49/52 used `export JENOVA_ROOT="$(dirname "$SCRIPT_DIR")"` which unconditionally overwrote any user-set `JENOVA_ROOT`. The config file (`etc/jenova.conf`) correctly preserves env vars with `${JENOVA_ROOT:-$_ROOT}`, but `jenova-ca` then clobbered it. Additionally, the branch-1 path (`$SCRIPT_DIR/lib/proxy.lua` found) incorrectly set the root to the parent of `SCRIPT_DIR` rather than `SCRIPT_DIR` itself.
- **Fix:** Both branches now use conditional assignment (`${JENOVA_ROOT:-...}`). Branch-1 uses `SCRIPT_DIR` as the root; branch-2 uses `dirname "$SCRIPT_DIR"`.
- **Status:** ✅ Fixed in `bin/jenova-ca`

#### Bug 9A.3 — No native `/health` endpoint in `lib/proxy.lua`

- **Root cause:** `GET /health` on the proxy port (8080) was forwarded to llama-server like any other request, making proxy liveness indistinguishable from backend health. If llama-server was starting (slow GPU init), the proxy appeared unhealthy even though it was running fine.
- **Fix:** Added native `/health` handler in `proxy_connection`. Pattern `^GET /health[ %?]` matches exactly (excludes `/healthz` etc.). Uses `async_connect` (non-blocking, coroutine-safe) to check llama-server reachability. Returns 200/503 with JSON: `{status, proxy, backend, embed (boolean), backend_ok (boolean)}`.
- **Status:** ✅ Fixed in `lib/proxy.lua`

#### Bug 9A.4 — `check_server()` accepted 502/503 as healthy (`lib/agent.lua`)

- **Root cause:** The agent's `try_health()` accepted HTTP 200, 404, 502, and 503 as "healthy", contradicting BLUEPRINT Bug 2.1 (healthcheck.lua accepts only 200). The agent considered itself ready even when the proxy was up but the backend was down, leading to immediate 502 errors on first API call.
- **Fix:** Only HTTP 200 is accepted as healthy, consistent with `lib/healthcheck.lua`.
- **Status:** ✅ Fixed in `lib/agent.lua`

#### Bug 9A.5 — `grep_search` missing from agent system prompt (`lib/agent.lua`)

- **Root cause:** `grep_search` was defined in the TOOLS table (line 217) with a working handler, but was not listed in the system prompt's TOOLS section. The model could never discover or use it, making the capability dead.
- **Fix:** Added `grep_search(pattern, include)` to the system prompt tool list.
- **Status:** ✅ Fixed in `lib/agent.lua`

#### Bug 9A.6 — Stale `CTX_SIZE = 2048` in `lib/embed.lua`

- **Root cause:** The embedding server is launched with `-c 4096`, but the Lua-side `CTX_SIZE` constant remained at 2048. Embeddings for inputs longer than 2048 tokens were silently truncated at the wrong boundary.
- **Fix:** `CTX_SIZE = 4096` with a comment referencing the matching server flag.
- **Status:** ✅ Fixed in `lib/embed.lua`

#### Bug 9A.7 — No unit-level tests for the launcher (`tests/`)

- **Root cause:** Only integration tests starting real daemons existed. No static tests for config loading, module presence, PID file format, cleanup guard, or health endpoint presence.
- **Fix:** Added `tests/test_bin_jenova.sh` (config/module/integration tests, 8 cases) and `tests/test-launcher.sh` (fully static unit tests, strict PID validation rejecting zeros, no daemon startup required). The unit test file uses a distinct name to avoid collision with root-level `test_bin_jenova.sh`.
- **Status:** ✅ Added `tests/test_bin_jenova.sh` and `tests/test-launcher.sh`

---

## 10. Neovim Config Audit (2026-03-26)

Full cross-module audit of all 14 library files + `bin/` scripts + `~/.config/nvim`. No breaking changes found in Jenova itself. Two bugs in the nvim config fixed.

#### Bug 10.1 — `llama.vim` pointed at non-existent endpoint (`~/.config/nvim/init.lua`)

- **Root cause:** `vim.g.llama_config = { endpoint = "http://127.0.0.1:8080/completion" }` — the proxy only exposes `/v1/chat/completions`. Ghost-text completions were silently failing.
- **Fix:** Updated to `/v1/chat/completions`. Llama.vim now routes through the proxy and receives RAG-injected context.
- **Status:** ✅ Fixed in `~/.config/nvim/init.lua`

#### Bug 10.2 — `<leader>ca` keybind referenced non-existent binary (`~/.config/nvim/init.lua`)

- **Root cause:** `:term ./jenova-agent<CR>` — `jenova-agent` was never the binary name. The correct entry point is `bin/jenova`.
- **Fix:** Updated to `:term cd ~/Projects/jenova && bin/jenova<CR>`.
- **Status:** ✅ Fixed in `~/.config/nvim/init.lua`
