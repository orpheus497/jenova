# Architecture Overview

Jenova is a local Human Cognition Enhancement system designed for consumer laptops. It provides a complete personal AI environment by integrating an inference backend, a browser-based Workspace, and an intelligent system management layer — running entirely on your hardware, with no cloud dependency.

## Core Philosophy

- **Human-first** — Jenova amplifies the user's own thinking, creativity, and judgment. It does not replace the user's reasoning or do the creative work on their behalf. The goal is to help the user become better at whatever they are trying to do.
- **Local-first** — no cloud dependencies; all inference, retrieval, and context processing happen on your machine.
- **Hardware-aware** — the install path detects your GPU(s), CPU, and RAM and deploys a matching `jenova.conf` overlay from `hardware-profiles/`. Model size selection (3B–4B vs 7B–9B) is driven by this detection.
- **Platform support** — first-class support for FreeBSD (ZFS, Vulkan, swap-backed model storage), Linux, and macOS (experimental).

## Component Breakdown

The **Jenova Cognitive Architecture** is structured around several interconnected pillars:

| Component | Role | Stack |
|-----------|------|-------|
| **Jenova Workspace** | Browser-based WebUI offering persistent workspaces and general chat. | SvelteKit / Tailwind CSS |
| **Intelligence Proxy** | Fronts the inference engine; handles RAG, web search, tool execution, and the filesystem API. | LuaJIT / C |
| **Server and OpenAI API** | Exposes an OpenAI-compatible API (`lib/proxy.lua`) allowing external integrations such as the Leo browser or other API-driven tools. | LuaJIT / C++ |
| **Remote Connections** | Architecture natively supports LAN bindings, enabling browser-based workspace access from mobile devices or secondary PCs. | POSIX sh / Networking |
| **Local Inference** | GGUF model execution (llama.cpp) handling chat, RAG embeddings, and speculative decoding. | C++ |

## System Flow

1. **User input** — typed into the Web UI or submitted via an API client.
2. **Intelligence proxy (port 8080)** — `lib/proxy.lua` (LuaJIT) provides a fully asynchronous, coroutine-based gateway. It injects RAG context (semantic and BM25 hits), performs non-blocking health checks, and handles background directory discovery to keep the WebUI responsive.
3. **Inference (port 8081)** — `llama-server` runs the active GGUF model with Vulkan or CUDA offload. Optimised for stability with socket-level FD isolation (CLOEXEC) to prevent resource leaks during heavy tool-calling.
4. **Tool calls** — when the model emits a tool call, the proxy runs it locally (storage read/write, web search, filesystem glob) and feeds the result back as the next conversation turn.
5. **Embedding (port 8082)** — a second `llama-server` process running in embedding mode (CPU) serves vector lookups for the proxy's RAG pipeline.
6. **Output** — tokens are streamed back through the proxy into the chat interface, with tool calls rendered inline.

## Persistent State

| Path | Purpose |
|------|---------|
| `var/log/` | Daemon stdout/stderr logs (rotated by `jenova-ca`). |
| `var/cache/` | Embedding/vector index, RAG snapshots. |
| `etc/jenova.conf` | Active hardware profile and model paths. |
| `models/` | Local GGUF storage: `agent/`, `draft/`, `embed/`. |

## External Dependencies

All external code lives in `external/`. The distinction matters for updates:

| Directory | Type | Source | Update method |
|-----------|------|--------|---------------|
| `external/llama.cpp` | Git submodule (managed automatically) | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | `git submodule update` |
| `external/ext_bin` | Build output | Local script | Stores compiled backend binaries to isolate the final runtime from the raw build tree. |

Vendored dependencies are full copies committed into the repo — no network fetch is needed after clone.
