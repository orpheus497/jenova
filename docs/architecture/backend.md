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
- **Stack**: `lib/proxy.lua` (LuaJIT, coroutine-based non-blocking I/O).
- **API surface**: OpenAI-compatible
  `POST /v1/chat/completions`, `POST /v1/completions`, `GET /v1/models`,
  `GET /v1/health`.
- **RAG pipeline**: Hybrid retrieval over the local index — semantic
  (embedding-server lookups) + BM25 — injecting the top snippets into the
  system prompt before forwarding to `llama-server`.
- **Streaming**: Chunked transfer-encoding pass-through with token-level
  flushing, keeping latency low for the chat sidebar.

## 3. Embedding Server (port 8082)
A second `llama-server` process running in embedding mode.
- **Model**: `nomic-embed-text-v1.5` (configurable via `JENOVA_EMBED_MODEL`).
- **Placement**: CPU by default, preserving VRAM for the main model.
- **Consumers**: the proxy's RAG pipeline and the codebase indexer
  (`lib/indexer_runner.lua`).

## Process Management — `bin/jenova-ca`

| Verb / flag | Action |
|-------------|--------|
| `--daemon` | Fork the supervisor; bring up llama-server + proxy + embed. |
| `--lan` | Bind to `0.0.0.0` instead of `127.0.0.1` (LAN mode). |
| `--watch` | Stay attached and tail logs (foreground). |
| `start [...]` | Alias for `--daemon`. |
| `stop` | Read `var/run/jenova.pid`, signal each tracked PID, clean up. |
| `restart` | `stop` + `start`. |
| `status` | Report PID + alive/dead per service. |

State and logs live under `var/` (`var/run/`, `var/log/`, `var/cache/`).

## Networking
All internal communication is HTTP/1.1 over localhost (or LAN when
`--lan` is set). Streaming responses use chunked transfer-encoding so the
chat buffer can render tokens as they arrive.
