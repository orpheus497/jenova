# cli-agent

**Pure C + Lua + llama.cpp AI coding agent.**

Zero Rust dependency. All system services implemented in C11. All application logic in Lua.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Lua Application Layer                  │
│  ┌──────────┐ ┌──────────┐ ┌─────────┐ ┌────────────┐  │
│  │  Agent   │ │  Tools   │ │Providers│ │    UI      │  │
│  │  Loop    │ │ Registry │ │ (LLM)   │ │  (ANSI)    │  │
│  └──────────┘ └──────────┘ └─────────┘ └────────────┘  │
├─────────────────────────────────────────────────────────┤
│                   C Service Layer                         │
│  ┌─────┐ ┌────┐ ┌──────┐ ┌────┐ ┌──┐ ┌───────┐ ┌───┐  │
│  │ HTTP│ │Auth│ │Crypto│ │JSON│ │FS│ │Process│ │MCP│  │
│  │curl │ │    │ │ ssl  │ │    │ │  │ │ fork  │ │   │  │
│  └─────┘ └────┘ └──────┘ └────┘ └──┘ └───────┘ └───┘  │
├─────────────────────────────────────────────────────────┤
│                   llama.cpp (Local LLM)                   │
│  GGUF model loading · Text generation · Token counting   │
└─────────────────────────────────────────────────────────┘
```

## Design Principles

| Aspect | cli-agent |
|--------|----------|
| Services | Pure C11 (~10 .c files) |
| Build | CMake only (single C compiler) |
| Dependencies | libcurl, OpenSSL (optional) |
| Binary size | ~2MB (C static) |
| Compile time | 10-30 sec |
| Agent | Fully integrated agentic loop |
| Memory | Unified with agent core |

## Building

```bash
# Debug build
make

# Release build
make release

# With llama.cpp support
cmake -B build -DAGENT_WITH_LLAMA=ON && cmake --build build

# Install
make install PREFIX=/usr/local
```

## Requirements

- C11 compiler (gcc, clang, cc)
- CMake ≥ 3.16
- libcurl (dev package)
- OpenSSL (optional, for crypto)
- Lua 5.4 (vendored, or system)

### FreeBSD
```bash
pkg install cmake curl openssl
```

### Linux
```bash
apt install cmake libcurl4-openssl-dev libssl-dev
```

### macOS
```bash
brew install cmake curl openssl
```

## Structure

```
cli-agent/
├── src/
│   ├── core/        main.c, init.c, lua_bindings.c
│   ├── net/         HTTP client (libcurl)
│   ├── auth/        API key management
│   ├── crypto/      SHA-256, HMAC, UUID, base64
│   ├── sandbox/     Path/command validation
│   ├── json/        JSON utilities
│   ├── fs/          Filesystem operations
│   ├── process/     Subprocess spawning
│   ├── mcp/         Model Context Protocol
│   ├── llama/       llama.cpp integration
│   └── agent/       Agent lifecycle (C)
├── lua/
│   ├── agent/       Agent loop, memory, UI
│   ├── tools/       40+ built-in tools
│   ├── providers/   LLM providers (llama.cpp, cloud)
│   ├── services/    Memory, API services
│   ├── utils/       Utility libraries
│   ├── config/      Configuration loader
│   ├── ui/          Terminal UI screens
│   └── init.lua     Bootstrap entry point
├── include/         jenova.h (public C API)
├── docs/            Architecture documentation
├── tests/           C + Lua + integration tests
├── CMakeLists.txt   Build configuration
├── Makefile         Convenience targets
└── README.md        This file
```

## Tools (40+)

All built-in tools are available: bash, file_read, file_write, file_edit,
glob, grep, agent, web_fetch, web_search, ask_user, todo_write, notebook_edit,
skill, brief, plan mode, MCP tools, task management, send_message, tool_search,
sleep, config, LSP, REPL, powershell, snip, verify_plan, worktree, cron,
remote_trigger, team management.

## Agent Features (from legacy-agent)

- Plan → Execute → Reflect loop
- Action deduplication (prevents repeated failures)
- Context window management with auto-trimming
- Narration detection + nudging
- FreeBSD-aware shell command rewriting
- Session memory with TTL-based GC
- REPL commands (/clear, /history, /debug, /context, etc.)
