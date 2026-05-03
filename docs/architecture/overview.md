# Architecture Overview

Jenova is a local AI coding environment designed for laptops. It provides a
complete terminal IDE by integrating an inference backend, a purpose-built
editor, an embedded agentic workflow system, and a modernised C-shell.

## Core Philosophy
- **Local-First** — no cloud dependencies; all inference, retrieval, and
  context processing happen on your machine.
- **Hardware-Aware** — the install path detects your GPU(s), CPU and RAM and
  deploys a matching `jenova.conf` overlay from `hardware-profiles/`.
- **FreeBSD-First** — primary target is FreeBSD 15 (ZFS, Vulkan, swap-backed
  model storage). Linux (Arch / Debian / Ubuntu) is fully supported.

## Component Breakdown

| Component | Role | Stack |
|-----------|------|-------|
| **Inference Backend** | GGUF model execution and speculative decoding. | C++ (llama.cpp) |
| **Intelligence Proxy** | RAG-aware brain, OpenAI-compatible API, and streaming. | LuaJIT (lib/proxy.lua) |
| **jvim Editor** | Interactive IDE frontend and UI for AI features. | C / Lua |
| **Unified Agent** | Autonomous coding partner embedded in the editor. | Lua (jvim-config/lua/jenova/agent/) |
| **mcsh Shell** | Integrated modern C-shell for the terminal IDE. | C (mcsh/) |
| **Daemon Manager** | Supervisor for inference, proxy, and embedding daemons. | POSIX sh (bin/jenova-ca) |

## System Flow
1. **User input** — typed into the `jvim` chat sidebar (`<leader>at`) or piped
   into `bin/jenova` for one-shot use.
2. **Agent engine** — `jvim-config/lua/jenova/agent/engine.lua` builds a
   context snapshot (active buffer, project tree, LSP diagnostics, recent
   history, pinned memory facts) and emits a chat-completion request.
3. **Intelligence proxy (port 8080)** — `lib/proxy.lua` (LuaJIT) injects RAG
   context (semantic + BM25 hits from the local index) and forwards to
   `llama-server`.
4. **Inference (port 8081)** — `llama-server` runs the active GGUF model with
   Vulkan offload. An optional 0.5B drafter speeds generation via speculative
   decoding.
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
