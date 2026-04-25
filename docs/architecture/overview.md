# Architecture Overview

Jenova is a local AI coding environment designed for laptops. It provides a complete terminal IDE by integrating an inference backend, a purpose-built editor, and an agentic workflow system.

## Core Philosophy
- **Local-First**: No cloud dependencies. All inference and data processing happen on your machine.
- **Hardware-Aware**: Automatically optimizes for your specific GPU and memory configuration.
- **FreeBSD-First**: Built for FreeBSD 15, ZFS, and Vulkan, though it supports Linux.

## Component Breakdown

| Component | Stack | Role |
|-----------|-------|------|
| **Cognitive Backend** | C++ / LuaJIT | Manages `llama-server`, proxy logic, and RAG pipelines. |
| **jvim** | C / Lua | A Neovim hard-fork with native agent integration. |
| **Agentic Loop** | Lua | The "brain" that uses tools to read, write, and analyze code. |

## System Flow
1. **User Input**: Received via `jvim` chat or inline commands.
2. **Proxy**: The `proxy.lua` daemon receives the request, injects RAG context (semantic search), and routes it to `llama-server`.
3. **Inference**: `llama-server` runs the GGUF model using Vulkan GPU offload.
4. **Tool Execution**: If the model requests a tool (e.g., `Read`, `Edit`), the Agent executes it locally and sends the result back for another inference turn.
5. **Output**: The final result is streamed back to the editor.
