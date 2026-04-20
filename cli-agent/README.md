# cli-agent

**Pure C + Lua + llama.cpp AI coding agent.**

Zero Rust dependency. All system services implemented in C11. All application logic in Lua.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Lua Application Layer                  │
│  ┌──────────┐ ┌──────────┐ ┌─────────┐ ┌────────────┐  │
│  │  Query   │ │  Tools   │ │Providers│ │    UI      │  │
│  │  Engine  │ │ Registry │ │ (LLM)   │ │  (ANSI)    │  │
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
| Services | Pure C11 (13 .c files) |
| Build | CMake only (single C compiler) |
| Dependencies | libcurl, OpenSSL (optional) |
| Binary size | ~2MB (C static) |
| Compile time | 10-30 sec |
| Agent | Fully integrated agentic loop |
| Memory | Unified with agent core |

## Building

```bash
# Debug build (requires GNU make — use gmake on FreeBSD)
gmake

# Release build
gmake release

# With llama.cpp support
cmake -B build/cmake -DAGENT_WITH_LLAMA=ON && cmake --build build/cmake

# Install
gmake install PREFIX=/usr/local
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
│   ├── agent/       Legacy loop, memory, UI shim
│   ├── engine/      QueryEngine (unified agentic loop)
│   ├── assistant/   Session history, query engine integration
│   ├── buddy/       Companion mode
│   ├── cli/         REPL commands (ported, extended, registry)
│   ├── config/      Configuration loader
│   ├── constants/   Shared constants
│   ├── context/     Context window management
│   ├── coordinator/ Multi-agent coordinator mode
│   ├── history/     Conversation history
│   ├── hooks/       Event hooks
│   ├── permissions/ Permission manager
│   ├── plugins/     Plugin loader
│   ├── providers/   LLM providers (jenova_backend, llamacpp, cloud)
│   ├── services/    Memory, API services
│   ├── skills/      Skill definitions
│   ├── state/       Application state (app_state)
│   ├── tools/       43 built-in tools
│   ├── ui/          Terminal UI screens and manager
│   ├── utils/       Utility libraries (json, http, shell, paths, …)
│   ├── vim/         Vim/Neovim integration bridge
│   └── init.lua     Bootstrap entry point
├── include/         jenova.h (public C API)
├── docs/            Architecture documentation
├── tests/           C + Lua + integration tests
├── vendor/          Vendored dependencies
├── CMakeLists.txt   Build configuration
├── Makefile         Convenience targets
└── README.md        This file
```

## Tools (43)

All built-in tools registered via the tool registry:

| Name | Description |
|---|---|
| `Agent` | Spawn a sub-agent for a subtask |
| `AskUserQuestion` | Prompt the user for input |
| `Brief` | Summarise a file or topic |
| `Config` | Read/write agent configuration |
| `Edit` | Edit a file with search/replace |
| `EnterPlanMode` / `ExitPlanMode` | Toggle read-only planning mode |
| `EnterWorktree` / `ExitWorktree` | Enter/exit a git worktree context |
| `Glob` | Find files by name pattern |
| `Grep` | Search file contents by regex |
| `LSP` | Language-server protocol queries |
| `ListMcpResources` / `ReadMcpResource` | Browse and read MCP server resources |
| `LocalSearch` | BM25 + semantic local codebase search |
| `MCPTool` | Invoke an MCP server tool |
| `McpAuth` | Authenticate to an MCP server |
| `NotebookEdit` | Edit Jupyter notebook cells |
| `PowerShell` | Run a PowerShell command |
| `REPL` | Execute Lua snippets in a sandboxed session |
| `Read` | Read a file |
| `RemoteTrigger` | HTTP POST to an external webhook |
| `ScheduleCron` | Schedule a recurring cron command |
| `SendMessage` | Send a message to another agent/task |
| `Shell` | Run a shell command |
| `Skill` | Load and invoke a named skill |
| `Sleep` | Pause execution for N seconds |
| `Snip` | Insert a code snippet |
| `SyntheticOutput` | Emit synthetic tool output |
| `TaskCreate` / `TaskGet` / `TaskList` / `TaskOutput` / `TaskStop` / `TaskUpdate` | Async task lifecycle |
| `TeamCreate` / `TeamDelete` | Multi-agent team management |
| `TodoWrite` | Write the agent todo list |
| `ToolSearch` | Search available tool definitions |
| `VerifyPlanExecution` | Verify a plan was executed correctly |
| `WebFetch` | Fetch a URL via curl |
| `WebSearch` | DuckDuckGo web search |
| `Write` | Write or create a file |

## Agent Features

- Plan → Execute → Reflect loop (via QueryEngine)
- Multi-turn tool calling with streaming
- Action deduplication (prevents repeated failures)
- Context window management with auto-trimming
- Narration detection + nudging
- FreeBSD-aware shell command rewriting
- Session memory with TTL-based GC
- REPL commands (`/clear`, `/history`, `/debug`, `/context`, etc.)
- Permission prompts for action tools (Shell, Write, Edit, …)
- MCP server support (tool + resource access)
- Companion mode (Buddy)
- Multi-agent coordinator mode
