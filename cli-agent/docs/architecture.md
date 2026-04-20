# cli-agent Architecture

## Overview

cli-agent is a pure C + Lua AI coding agent. All system services are implemented in C11; all
application logic runs in Lua 5.4. There is no Rust dependency.

## Migration Map (Rust → C, completed)

| Former Rust Crate | C File | Dependencies |
|---|---|---|
| jenova-ffi | src/core/lua_bindings.c | Lua 5.4 API |
| jenova-net | src/net/net.c | libcurl |
| jenova-auth | src/auth/auth.c | POSIX (env, files) |
| jenova-json | src/json/json.c | None (minimal pretty-printer + extractor) |
| jenova-crypto | src/crypto/crypto.c | OpenSSL (optional) |
| jenova-sandbox | src/sandbox/sandbox.c | POSIX (realpath) |
| jenova-fs | src/fs/fs.c | POSIX (stdio, dirent) |
| jenova-process | src/process/process.c | POSIX (fork, pipe, exec) |
| jenova-mcp | src/mcp/mcp.c | None (string building) |
| jenova-llama | src/llama/llama.c | llama.cpp (optional) |

## C Service Layer (src/)

```
src/
├── core/
│   ├── main.c          — Entry point; CLI arg parsing; Lua VM init
│   ├── init.c          — C service initialisation; binding table setup
│   └── lua_bindings.c  — Exposes C services to Lua via jenova.* global table
├── agent/agent.c       — C-level agent state; lifecycle; LSP request framing
├── auth/auth.c         — API key storage (HOME/.config/cli-agent/keys/)
├── crypto/crypto.c     — SHA-256, HMAC, UUID, base64 (OpenSSL-backed)
├── fs/fs.c             — File read/write/glob/grep/list/stat
├── json/json.c         — JSON pretty-printer, path extractor, validator
├── llama/llama.c       — llama.cpp embedding and generation bindings
├── mcp/mcp.c           — JSON-RPC MCP client (stdio transport)
├── net/net.c           — HTTP GET/POST via libcurl; streaming support
├── process/process.c   — fork/exec subprocess with pipe capture + timeout
└── sandbox/sandbox.c   — Path validation (realpath + prefix check); command blacklist
```

## Lua Application Layer (lua/)

```
lua/
├── init.lua            — Bootstrap: parse CLI args, init services, dispatch to REPL or print mode
│
├── agent/              — Legacy compatibility shims
│   ├── loop.lua        — Thin wrapper delegating to QueryEngine
│   ├── memory.lua      — Session memory access helper
│   └── ui.lua          — Terminal rendering helpers (spinners, boxes, colours)
│
├── engine/             — Unified agentic loop
│   ├── query_engine.lua    — Plan→Execute→Reflect; multi-turn tool calling; streaming
│   └── session_history.lua — In-memory message/turn history for QueryEngine
│
├── assistant/          — Conversation assistant mode
│   └── session_history.lua — Persistent session history (JSONL)
│
├── buddy/              — Companion (Buddy) mode
│   ├── companion.lua   — Buddy personality and conversation loop
│   └── types.lua       — Shared type definitions
│
├── cli/                — REPL and CLI command dispatch
│   ├── commands/
│   │   ├── extended.lua    — Extended slash commands (/commit, /review, /diff, …)
│   │   ├── ported.lua      — Ported legacy-agent slash commands
│   │   └── registry.lua    — Command registration and dispatch table
│   └── registry.lua    — Top-level CLI registry
│
├── config/             — Configuration
│   └── loader.lua      — Reads env vars + etc/jenova.conf; exposes config.get()
│
├── constants/          — Shared constants (model names, limits, exit codes)
│
├── context/            — Context window management
│   └── manager.lua     — Token counting, trimming, priority-based retention
│
├── coordinator/        — Multi-agent coordinator
│   ├── coordinator_mode.lua — Orchestrator logic
│   └── manager.lua         — Task/team state management
│
├── history/            — Conversation history
│   └── manager.lua     — Load/save/prune JSONL history files
│
├── hooks/              — Event hook system
│   └── loader.lua      — Register and fire pre/post-tool hooks
│
├── permissions/        — Permission management
│   └── manager.lua     — can_use_tool(); permission prompt; mode enforcement
│
├── plugins/            — Plugin loader
│   └── loader.lua      — Dynamic plugin loading from .jenova/plugins/
│
├── providers/          — LLM provider adapters
│   ├── base.lua            — Provider base class and priority selection
│   ├── init.lua            — Provider initialisation
│   ├── jenova_backend.lua  — Jenova proxy (port 8080) — primary provider
│   ├── llamacpp.lua        — Direct llama.cpp via C bindings
│   ├── loader.lua          — Lazy provider loader
│   ├── openai.lua          — OpenAI-compatible API (cloud fallback)
│   └── pricing.lua         — Token cost estimation
│
├── services/           — Background services
│   ├── memory/
│   │   └── manager.lua — Session memory store; TTL-based GC; JSONL pruning
│   └── api/            — Jenova backend API client helpers
│
├── skills/             — Named reusable agent scripts
│
├── state/              — Application-wide mutable state
│   └── app_state.lua   — get()/set() for permission_mode, session_id, flags
│
├── tools/              — 43 built-in tools (see README.md for full list)
│   └── registry.lua    — Tool registration, lookup, and execute() dispatch
│
├── ui/                 — Terminal UI
│   ├── manager.lua     — Top-level UI manager; route to active screen
│   └── screens/        — Individual screen modules (chat, settings, …)
│
├── utils/              — Utility libraries
│   ├── array.lua       — Array helpers
│   ├── embed.lua       — Embedding utilities
│   ├── fs_fallback.lua — Pure-Lua filesystem fallback
│   ├── http.lua        — curl-based HTTP client (GET, POST)
│   ├── json_fallback.lua — Pure-Lua JSON encoder/decoder
│   ├── paths.lua       — Path classification (.jenova blocking, resolution)
│   ├── shell.lua       — Shell quoting, env formatting
│   ├── string.lua      — String utilities (trim, split, wrap, …)
│   └── trio.lua        — Jenova trio endpoint discovery
│
└── vim/                — Vim/Neovim integration bridge
    └── keybindings.lua — Keymap helpers for embedded Neovim mode
```

## Unified Agent Loop (QueryEngine)

`engine/query_engine.lua` is the single agentic loop used by all entry points:

```
User input
    │
    ▼
QueryEngine:query()
    │
    ├─ Build system prompt (context + memory)
    ├─ Send to provider (jenova_backend / llamacpp / cloud)
    │
    ├─ Stream response
    │    ├─ Render text tokens via ui.agent_response()
    │    └─ Collect tool_use blocks
    │
    ├─ For each tool call:
    │    ├─ permissions.manager.can_use_tool() → prompt user if needed
    │    ├─ tool_registry.execute(name, args, context)
    │    └─ Append tool result to message history
    │
    ├─ If tool calls were made → loop (multi-turn)
    └─ Return final response
```

The REPL (`agent/loop.lua`) and all slash commands (`cli/commands/`) delegate to
`QueryEngine:query()`. There is no separate agentic code path.

## Legacy Agent Integration (completed)

The former standalone `legacy-agent/` has been fully decomposed:

| legacy-agent file | Destination |
|---|---|
| `agent.lua` (main loop) | `lua/engine/query_engine.lua` |
| `memory.lua` | `lua/agent/memory.lua` + `lua/services/memory/manager.lua` |
| `ui.lua` | `lua/agent/ui.lua` |
| `chat.lua` | `lua/init.lua` (simple chat fallback path) |

## Build System

Single CMake project (no Cargo step):

1. Compile vendored Lua 5.4 as a static library
2. Compile all `src/**/*.c` into object files
3. Link: Lua + libcurl + optionally OpenSSL and llama.cpp
4. Output: single `build/cli-agent` binary (~2 MiB)

```bash
gmake            # debug (FreeBSD/Linux/macOS)
gmake release    # optimised
gmake test       # run C + Lua + integration tests
```

## Standalone Design

`cli-agent/` is fully self-contained. It can be built and deployed independently of the rest of
the Jenova repo. The only external runtime dependencies are `libcurl` and (optionally) `libssl`.
The Jenova backend services (`jenova-ca`, `proxy.lua`, `llama-server`) are optional — the agent
can run against any OpenAI-compatible API by setting `JENOVA_PROVIDER` appropriately.
