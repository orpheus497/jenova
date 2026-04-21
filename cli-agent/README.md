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
│  ┌──────┐ ┌─────┐ ┌────┐ ┌──────┐ ┌────┐ ┌──┐ ┌───┐  │
│  │Agent │ │ HTTP│ │Auth│ │Crypto│ │JSON│ │FS│ │MCP│  │
│  │(LSP) │ │curl │ │    │ │ ssl  │ │    │ │  │ │   │  │
│  └──────┘ └─────┘ └────┘ └──────┘ └────┘ └──┘ └───┘  │
│  ┌─────────┐ ┌───────┐ ┌─────────┐                     │
│  │ Process │ │ llama │ │ sandbox │                     │
│  │  fork   │ │ .cpp  │ │         │                     │
│  └─────────┘ └───────┘ └─────────┘                     │
├─────────────────────────────────────────────────────────┤
│                   llama.cpp (Local LLM)                   │
│  GGUF model loading · Text generation · Token counting   │
└─────────────────────────────────────────────────────────┘
```

The agentic loop lives in `lua/engine/query_engine.lua` (QueryEngine). `lua/agent/loop.lua` is a thin shim that sets up the REPL and delegates all LLM generation and tool execution to QueryEngine.

## Design Principles

| Aspect | cli-agent |
|--------|----------|
| Services | Pure C11 (11 modules under `src/`) |
| Build | CMake + GNU make wrapper |
| Dependencies | libcurl, OpenSSL (optional) |
| Binary size | ~2MB (C static) |
| Compile time | 10–30 sec |
| Agent | Unified agentic loop (QueryEngine) |
| Memory | Session memory with TTL-based GC |

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
│   ├── agent/       Agent lifecycle, LSP framing (Content-Length), write_all helper
│   ├── auth/        API key management (~/.config/cli-agent/keys)
│   ├── core/        main.c, init.c, lua_bindings.c
│   ├── crypto/      SHA-256, HMAC, UUID, base64
│   ├── fs/          Filesystem operations (glob, grep, read, write, edit)
│   ├── json/        JSON pretty-printer and utilities
│   ├── llama/       llama.cpp integration (model load, generate, embed)
│   ├── mcp/         Model Context Protocol (JSON-RPC framing, init/call)
│   ├── net/         HTTP client (libcurl wrapper)
│   ├── process/     Subprocess spawning (fork/exec, pipe capture)
│   └── sandbox/     Path and command validation
├── lua/
│   ├── agent/       REPL loop shim, session memory, ANSI UI
│   ├── assistant/   Session history, query engine integration
│   ├── buddy/       Companion mode
│   ├── cli/         REPL commands (registry, extended, ported)
│   ├── config/      Configuration loader
│   ├── constants/   Shared constants
│   ├── context/     Context window management
│   ├── coordinator/ Multi-agent coordinator mode
│   ├── engine/      QueryEngine — unified Plan→Execute→Reflect loop
│   ├── history/     Conversation history
│   ├── hooks/       Event hooks
│   ├── permissions/ Permission manager (default/auto/plan/bypass modes)
│   ├── plugins/     Plugin loader
│   ├── providers/   LLM providers (jenova_backend, llamacpp, cloud)
│   ├── services/    Memory and API services
│   ├── skills/      Skill definitions
│   ├── state/       Application state (app_state)
│   ├── tools/       43 built-in tools (see table below)
│   ├── ui/          Terminal UI screens and manager
│   ├── utils/       json_fallback, http, shell, paths, string, …
│   ├── vim/         Vim/Neovim integration bridge
│   └── init.lua     Bootstrap entry point (REPL, one-shot, MCP server modes)
├── include/         jenova.h (public C API)
├── docs/            Architecture documentation
├── tests/           C + Lua + integration tests
├── vendor/          Vendored dependencies (Lua 5.4)
├── CMakeLists.txt   Build configuration
├── Makefile         Convenience targets (gmake wrapper)
└── README.md        This file
```

## Tools (43)

All built-in tools registered via the tool registry (`lua/tools/registry.lua`). Tool names are canonical — they match the `M.name` field used by the LLM and permissions manager:

| Name | Description |
|---|---|
| `Agent` | Spawn a sub-agent for a subtask |
| `AskUserQuestion` | Prompt the user for input |
| `Brief` | Summarise a file or topic |
| `Config` | Read/write agent configuration |
| `Edit` | Edit a file with search/replace (exact match, unique context required) |
| `EnterPlanMode` | Switch to read-only planning mode (restricts to read-only tools) |
| `EnterWorktree` | Enter a git worktree context |
| `ExitPlanMode` | Exit plan mode, restore full tool access |
| `ExitWorktree` | Exit a git worktree context |
| `Glob` | Find files by name pattern |
| `Grep` | Search file contents by regex |
| `LSP` | Language-server protocol queries (hover, definition, references) |
| `ListMcpResources` | Browse resources exposed by a connected MCP server |
| `LocalSearch` | BM25 + semantic local codebase search |
| `MCPTool` | Invoke a tool on a connected MCP server |
| `McpAuth` | Authenticate to an MCP server |
| `NotebookEdit` | Edit Jupyter notebook cells |
| `PowerShell` | Run a PowerShell command |
| `REPL` | Execute Lua snippets in a sandboxed session |
| `Read` | Read a file (with optional line offset and limit) |
| `ReadMcpResource` | Read a resource URI from a connected MCP server (sandbox-validated for `file://`) |
| `RemoteTrigger` | HTTP POST to an external webhook (CRLF-sanitized headers, argv curl path) |
| `ScheduleCron` | Schedule a recurring command (sandbox-validated at creation) |
| `SendMessage` | Send a message to another agent/task |
| `Shell` | Run a shell command (permission-prompted; read-only heuristic for pre-screening) |
| `Skill` | Load and invoke a named skill |
| `Sleep` | Pause execution for N seconds |
| `Snip` | Insert a code snippet |
| `SyntheticOutput` | Emit synthetic tool output |
| `TaskCreate` | Create a background async task |
| `TaskGet` | Get status and details of a background task |
| `TaskList` | List all background tasks |
| `TaskOutput` | Get output from a background task |
| `TaskStop` | Stop a running background task |
| `TaskUpdate` | Update a background task |
| `TeamCreate` | Create a multi-agent team |
| `TeamDelete` | Delete a multi-agent team |
| `TodoWrite` | Write the agent todo list |
| `ToolSearch` | Search available tool definitions |
| `VerifyPlanExecution` | Verify a plan was executed correctly |
| `WebFetch` | Fetch a URL via curl |
| `WebSearch` | DuckDuckGo web search |
| `Write` | Write or create a file |

## Agent Features

- **QueryEngine**: Plan → Execute → Reflect loop with multi-turn tool calling
- **Action deduplication**: prevents repeated identical tool calls
- **Context window management**: auto-trimming with narration detection and nudging
- **Session memory**: TTL-based GC, persisted to `~/.config/cli-agent/memory.json`
- **Permission prompts**: interactive y/n/always/session prompts for `Shell`, `Write`, `Edit`, and other action tools (plan mode blocks all action tools)
- **FreeBSD-aware shell rewriting**: command translation for FreeBSD vs Linux
- **MCP server support**: tool invocation and resource access over JSON-RPC stdio
- **Companion mode** (Buddy) and **multi-agent coordinator mode**
- **REPL commands**: `/clear`, `/compact`, `/config`, `/context`, `/cost`, `/cwd`, `/diff`, `/files`, `/help`, `/history`, `/mcp`, `/model`, `/plan`, `/provider`, `/quit`, `/sessions`, `/stats`, `/thinking`, `/tools`, `/version`, `/vim`, and more

## Security Notes

- **Sandbox**: The C sandbox (`src/sandbox/sandbox.c`) uses a blacklist approach to block dangerous shell patterns, direct reads of sensitive paths, and directory-prefix confusion. It is a defence-in-depth layer, not a hard security boundary.
- **Permission manager**: The primary security gate is the interactive permission manager (`lua/permissions/manager.lua`). Action tools (`Shell`, `Write`, `Edit`, etc.) always prompt for confirmation in default and plan modes.
- **Temporary files**: `lua/utils/http.lua` uses a deterministic `/tmp/jenova_http_<time>_<hex>` path rather than `os.tmpname()` to avoid TOCTOU races.
- **Header injection**: `RemoteTrigger` and `http.lua` strip `\r\n` from header names and values before constructing curl argv to prevent CRLF injection.
- **Path patterns**: `.jenova` and `.claude` are matched with escaped Lua patterns (`/%.jenova/`) to prevent false matches on paths like `/xjenova/`.

## Known Limitations (not yet addressed)

- The C sandbox uses a blacklist — a whitelist or OS-level sandboxing (capsicum/pledge) would be stronger.
- `src/fs/fs.c` uses `ftell`/`long` for file sizes — on 32-bit platforms files > 2GB will overflow (`ftello`/`off_t` needed).
- `src/process/process.c` uses a busy-wait loop (`usleep(10000)`) for subprocess output — `poll()`/`select()` would be more efficient.
- Manual JSON extraction in C (`strstr`/`strchr` pattern) is fragile; a proper C JSON library would be more robust.
- The LSP bridge in `src/agent/agent.c` is synchronous — persistent language servers that don't close stdout will cause it to hang after the first response.
- Lua REPL (`tools/repl.lua`) shares the agent's Lua VM — a resource-exhausting snippet could crash the agent.
