# Cognitive Backend

Jenova runs three persistent daemon processes — managed as a single unit by
the `jenova-ca` supervisor — that handle inference, intelligence/RAG, and
retrieval embeddings.

## 1. llama-server — Main Inference (port 8081)
The primary GGUF runtime.
- **Stack**: C++ (`llama.cpp`, built with Vulkan).
- **GPU offload**: Single or dual-GPU via `DEVICES` (e.g. `Vulkan0`,
  `Vulkan0,Vulkan1`). `NGL=all` for full offload, integer for partial.
- **Speculative decoding**: Optional 0.5B drafter model
  (`JENOVA_DRAFT=1`) — pinned to `JENOVA_DRAFT_DEVICE` (defaults to
  `Vulkan0`). Typically 1.5×–2× generation speedup when VRAM headroom
  exists.
- **KV cache**: `q8_0` by default (configurable via `JENOVA_KV_TYPE`:
  `q4_0` / `q8_0` / `f16`).

## 2. Intelligence Proxy — RAG Brain (port 8080)
LuaJIT proxy that fronts `llama-server` and shapes every request.
- **Stack**: `lib/proxy.lua` (LuaJIT, coroutine-based **non-blocking** I/O via `lib/http.lua`).
- **Architecture**: Employs a `select`-based loop with coroutine yielding for all I/O, including:
    - **Async Health Checks**: Backend liveness is verified via non-blocking TCP probes.
    - **Async Sub-processes**: Shell commands (like `find` for file discovery and `fetch`/`curl` for web search) are executed via a non-blocking `fork`/`pipe` mechanism that yields to the scheduler while waiting for output.
    - **Background Discovery**: Directory crawling and workspace listing are performed asynchronously to prevent UI/Editor freezes.
    - **Security Sealing**: All accepted sockets are marked with `FD_CLOEXEC` to prevent child processes from inheriting and locking ports.
- **API surface**:
    - OpenAI-compatible: `POST /v1/chat/completions`, `POST /infill`, `GET /v1/health`.
    - Workspace filesystem: `POST /api/storage/{path}` (write), `GET /api/storage/{path}` (read), `GET /api/storage/` (list files), `GET /api/workspaces` (list workspaces).
    - Static assets: `GET /` serves the Web UI from `public/`.
    - All other requests are proxied to llama-server.
- **RAG pipeline**: Hybrid retrieval over the local index. Inbound storage updates trigger asynchronous background re-indexing to prevent head-of-line blocking on port 8080.
- **Streaming**: Chunked transfer-encoding pass-through with token-level flushing, keeping latency low for the chat sidebar.

## 3. Embedding Server (port 8082)
A second `llama-server` process running in embedding mode.
- **Model**: `Qwen3-Embedding-0.6B` (1024-dimensional, Q8_0 quantisation) for local CPU execution.
- **Placement**: CPU-only by default (`GGML_VULKAN_DISABLE=1`), preserving VRAM for the main inference model.
- **Consumers**: the proxy's RAG pipeline and the codebase indexer (`lib/indexer_runner.lua`).

## Process Management — `bin/jenova-ca`

| Verb / flag | Action |
|-------------|--------|
| `--daemon` | Fork the supervisor; bring up llama-server + proxy + embed. |
| `--lan` | Bind to `0.0.0.0` instead of `127.0.0.1` (LAN mode). |
| `--watch` | Continuous health monitoring with auto-restart on failure. |
| `start [...]` | Alias for `--daemon`. |
| `stop` | Read `$JCA_HOME/.system/jenova-ca.pid`, signal each tracked PID, clean up. |
| `restart` | `stop` + `start`. |
| `status` | Report PID + alive/dead per service. |

State lives under `$JCA_HOME/.system/` (PIDs, lock files), with logs in
`$JCA_HOME/var/log/` and caches in `$JCA_HOME/var/cache/`.

## Persistence & Workspaces

The Intelligence Proxy includes a native **Filesystem API** (`/api/storage`) that allows frontends (like the Web UI) to persist data directly to the host machine.

- **Storage Root**: `$JCA_HOME/Workspaces` (default `~/JCA/Workspaces`)
- **Data Format**: Markdown (`.md`) for chats and notes to ensure interoperability with standard editors and Unix tools.
- **Sync Logic**: The Web UI mirrors its internal state to the filesystem on every significant change (message completion, note edit, folder move).

This architecture ensures that Jenova is "device-first" rather than "browser-first." Your data is not trapped in an IndexedDB silo; it lives in your home directory, organized by Workspace and Folder, ready for editing in any text editor or backup via standard scripts.

## Networking
All internal communication is HTTP/1.1 over localhost (or LAN when
`--lan` is set). Streaming responses use chunked transfer-encoding so the
chat buffer can render tokens as they arrive.
