# coder — autonomous local coding agent

Agentic coding assistant running on FreeBSD with llama.cpp (Vulkan), LuaJIT, and hybrid BM25+semantic search.

## Quick Start

```sh
./bin/coder-agent    # starts server + agent
```

## Structure

```
bin/                 # Executable scripts
  coder-server       # Launch llama-server (GPU-optimized)
  coder-agent        # Start server + connect agent REPL
  llama-server-nvim  # Server for Neovim FIM completions (port 8012)
lib/                 # Lua modules (LuaJIT)
  agent.lua          # Main agent loop, tool execution, narration detection
  http.lua           # FFI HTTP client (zero-dependency, raw sockets)
  json.lua           # Pure-Lua JSON encoder/decoder
  embed.lua          # Embedding interface (llama-embedding CLI)
  search.lua         # Hybrid BM25 + semantic vector search
  memory.lua         # Session logging, error tracking, project tree
etc/                 # Configuration
  coder.conf         # All tunables: model paths, context, tensor split, threads
models/              # GGUF model files (gitignored)
var/                 # Runtime data: logs, cache
tests/               # Test scripts
llama.cpp/           # llama.cpp source + build (gitignored)
```

## Hardware

Optimized for: **i5-1135G7 / GTX 1650 Ti 4GB / Intel Iris Xe ~7GB / 16GB RAM**

- Vulkan backend (no CUDA on FreeBSD)
- Tensor split: 35% NVIDIA / 65% Intel Xe (14B model)
- f16 KV cache (required for JSON accuracy)
- Flash attention enabled

## Models

| Model | Size | Use |
|-------|------|-----|
| Qwen2.5-Coder-14B-Q4_K_M | 8.4 GB | Primary (agent) |
| Qwen2.5-Coder-14B-Q3_K_M | 6.8 GB | Backup (less VRAM) |
| nomic-embed-text-v1.5-Q8_0 | 139 MB | RAG embeddings |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODER_MODEL` | Q4_K_M | Override model path |
| `CODER_CTX` | 8192 | Context window |
| `CODER_HOST` | 127.0.0.1 | Server bind address |
| `CODER_PORT` | 8080 | Server port |
| `CODER_DRAFT` | (unset) | Set to 1 for speculative decoding |
| `CODER_MAX_TURNS` | 25 | Max agent turns per query |
| `CODER_TIMEOUT` | 600 | HTTP timeout (seconds) |
| `CODER_DEBUG` | 0 | Set to 1 for debug output |

## REPL Commands

`/clear` `/history` `/debug` `/context` `/reindex` `/files` `/search` `/errors` `/bench` `/stats` `/quit`

## mlock

FreeBSD requires `security.bsd.unprivileged_mlock=1` for userspace mlock. Add to `/etc/sysctl.conf` for persistence. Do **NOT** run with sudo (breaks Vulkan GPU access via X11 auth).
