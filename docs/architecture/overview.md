# Architecture Overview

Jenova is a local AI coding environment designed for laptops. It provides a
complete terminal IDE by integrating an inference backend, a purpose-built
editor, and an embedded agentic workflow system.

## Core Philosophy
- **Local-First** — no cloud dependencies; all inference, retrieval, and
  context processing happen on your machine.
- **Hardware-Aware** — the install path detects your GPU(s), CPU and RAM and
  deploys a matching `jenova.conf` overlay from `hardware-profiles/`.
- **Platform Support** — First-class support for FreeBSD (ZFS, Vulkan,
  swap-backed model storage), Linux, and macOS.

## Component Breakdown

The **Jenova Cognitive Architecture** is structured around several interconnected pillars:

| Component | Role | Stack |
|-----------|------|-------|
| **Jenova Workspace** | WebUI offering persistent workspaces and a general chat interface. | SvelteKit / Tailwind CSS |
| **J Vim (Jenova Vim)** | A comprehensive *Interactive Director Environment* (IDE). A Jenova-specific fork of NeoVim that enables agentic work and actions through the LSP and plugin extensibility of the jvim architecture. | C / Lua |
| **Server & OpenAI API**| Exposes an OpenAI-compatible API (`lib/proxy.lua`) allowing external integrations like the Leo browser or other API-driven tools. | LuaJIT / C++ |
| **Remote Connections** | Architecture natively supports LAN bindings, enabling browser-based workspace access from mobile phones or secondary PCs. | POSIX sh / Networking |
| **Local Inference** | GGUF model execution (llama.cpp) handling agents, RAG embeddings, and speculative decoding. | C++ |

## System Flow
1. **User input** — typed into the `jvim` chat sidebar (`<leader>aa`) or piped
   into `bin/jenova` for one-shot use.
2. **Agent engine** — `jvim-config/lua/jenova/agent/engine.lua` builds a
   context snapshot (active buffer, project tree, LSP diagnostics, recent
   history, pinned memory facts) and emits a chat-completion request.
3. **Intelligence proxy (port 8080)** — `lib/proxy.lua` (LuaJIT) provides a **fully asynchronous**, coroutine-based gateway. It injects RAG context (semantic + BM25 hits), handles non-blocking health checks, and performs background directory discovery to keep the editor and WebUI responsive.
4. **Inference (port 8081)** — `llama-server` runs the active GGUF model with Vulkan offload. Optimized for stability with **socket-level FD isolation (CLOEXEC)** to prevent resource leaks during heavy tool-calling.
5. **Tool calls** — when the model emits a tool call, the agent runs it locally
   (buffer read / edit / write, glob / grep, LSP, shell, vim ex-command,
   remember, ask_user) and feeds the result back as the next turn.
6. **Embedding (port 8082)** — a second `llama-server` process running in
   embedding mode (CPU) serves vector lookups for the proxy's RAG pipeline.
7. **Output** — tokens are streamed back through the proxy into the chat
   buffer, with tool calls rendered inline as `✓` / `✗` lines.

## Persistent State

| Path | Purpose |
|------|---------|
| `var/log/` | Daemon stdout/stderr logs (rotated by `jenova-ca`). |
| `var/cache/` | Embedding/vector index, RAG snapshots. |
| `~/.config/jvim/` | Editor config (deployed by `scripts/install.sh`). |
| `etc/jenova.conf` | Active hardware profile + model paths. |
| `models/` | Local GGUF storage: `agent/`, `draft/`, `embed/`. |

## External Dependencies

All external code lives in `external/`. The distinction matters for updates:

| Directory | Type | Source | Update method |
|-----------|------|--------|---------------|
| `external/llama.cpp` | Submodule (Advanced) | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | Git submodule update |

**Note**: By default, Jenova downloads and uses pre-built universal binaries. The `external/llama.cpp` submodule is provided for advanced users who wish to build from source.
