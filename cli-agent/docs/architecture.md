# cli-agent Architecture

## Overview

cli-agent is a pure C + Lua AI coding agent.
All system services are implemented in C11 with no external runtime dependencies beyond libcurl.

## Rust → C Migration Map

| Rust Crate | C File | Dependencies |
|------------|--------|--------------|
| jenova-ffi | src/core/lua_bindings.c | Lua 5.4 API |
| jenova-net | src/net/net.c | libcurl |
| jenova-auth | src/auth/auth.c | POSIX (env, files) |
| jenova-json | src/json/json.c | None (minimal parser) |
| jenova-crypto | src/crypto/crypto.c | OpenSSL (optional) |
| jenova-sandbox | src/sandbox/sandbox.c | POSIX (realpath) |
| jenova-fs | src/fs/fs.c | POSIX (stdio, dirent) |
| jenova-process | src/process/process.c | POSIX (fork, pipe, exec) |
| jenova-mcp | src/mcp/mcp.c | None (string building) |
| jenova-llama | src/llama/llama.c | llama.cpp (optional) |

## New: Agent Core (C)

`src/agent/agent.c` provides C-level agent state management:
- Lifecycle (init/shutdown/reset)
- Turn counting and max-turn enforcement
- State serialization for debugging

## New: Agent Loop (Lua)

`lua/agent/loop.lua` integrates the legacy-agent's agentic loop:
- Plan → Execute → Reflect cycle
- Tool calling via the full tool registry
- Action deduplication via memory module
- Context injection from memory state

## Legacy Agent Integration

The standalone `legacy-agent/` has been decomposed and merged:
- `agent.lua` → `lua/agent/loop.lua` (main loop + tool parsing)
- `memory.lua` → `lua/agent/memory.lua` (session memory + dedup)
- `ui.lua` → `lua/agent/ui.lua` (terminal rendering)
- `chat.lua` → subsumed by the simple chat fallback in init.lua

## Build System

Single CMake build (no Cargo step):
1. Compile vendored Lua 5.4 as static library
2. Compile all src/**/*.c into object files
3. Link against Lua, libcurl, optionally OpenSSL and llama.cpp
4. Produces single `cli-agent` binary

## Standalone Design

This folder (`cli-agent/`) is fully self-contained.
It can be built and deployed independently with no cross-dependencies.
