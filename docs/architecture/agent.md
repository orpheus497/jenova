# Unified Agent System

The Jenova Agent is an autonomous "coding partner" that lives inside your
editor. It is context-aware by default and uses native Neovim APIs (buffers,
LSP, ex-commands) instead of shelling out to external CLIs.

## Unification

The agent is fully unified. The engine, tools, registry, memory, and provider
all live under `jvim-config/lua/jenova/agent/`. The same code can be driven by
the interactive editor (`jvim`) or by the headless `bin/jenova` launcher.

- **jvim agent** — canonical interactive experience. Full access to live
  Neovim buffers, LSP servers, the project tree, and the ex-command surface.
- **Headless agent** — invoked via `bin/jenova` (one-shot / scripted /
  CI-friendly).

## Core Components

### 1. Engine (`engine.lua`)
Runs the Plan → Execute → Reflect loop. Manages multi-turn tool calling, retry
budgets, and the conversation transcript.

### 2. Context (`context.lua`)
Builds a per-turn snapshot:
- active buffer (path + visible window or full content)
- project file tree (bounded)
- LSP diagnostics (errors / warnings) for open buffers
- conversation history (windowed)
- pinned long-term memory facts
- detected hardware profile + active model

### 3. Memory (`memory.lua`, `learning.lua`, `learning_extractors.lua`)
Long-term memory store. The `Remember` tool pins user-stated preferences /
project conventions / build commands. Auto-extractors observe successful tool
outcomes and promote durable facts. Pinned facts are auto-injected into the
system prompt when relevant.

### 4. Compactor (`compactor.lua`)
Aggressive token compression for tool schemas, system prompts, and history —
built so 3B/7B models keep room for code and reasoning.

### 5. Provider (`provider.lua`)
OpenAI-compatible chat-completion client that targets the local
intelligence proxy on `http://localhost:8080/v1`.

### 6. Registry (`registry.lua`)
Loads and exposes the native tool set declared in `agent/tools/init.lua`.

## Native Tools

All tools live in `jvim-config/lua/jenova/agent/tools/` and operate directly
on the Neovim runtime — no out-of-process subprocesses for buffer I/O.

| Tool | Purpose |
|------|---------|
| `BufferRead` | Read a file via the buffer system (loads off-disk if not open). |
| `BufferEdit` | Single-range line edit on a file/buffer. |
| `BufferMultiEdit` | Multiple line-range edits to one file (sorted bottom-up so line numbers stay stable). |
| `BufferWrite` | Create / overwrite a file. |
| `BufferGlob` | Glob across the project tree. |
| `BufferGrep` | Ripgrep-style content search (LSP/buffer-aware). |
| `BufferLs` | List a directory. |
| `BufferList` | List currently open buffers + status. |
| `LSP` | Hover, definition, references, and diagnostics through any active LSP server. |
| `Shell` | Run a shell command (gated by interactive confirmation). |
| `VimCmd` | `ex` (run an ex-command and capture `:redir`) or `lua` (eval Lua and read plugin state). |
| `Remember` | Pin a durable fact to long-term memory. |
| `AskUser` | Prompt the user for a missing decision before continuing. |

## Security & Permissions
- **Interactive confirmation** — destructive tools (`Shell`, \`BufferWrite\`,
  \`BufferEdit\`, \`BufferMultiEdit\`) require explicit user approval by default.
- **Plan mode** — a read-only mode (toggled with `<leader>amm`) where the agent
  can investigate but not mutate.
- **Path validation** — file tools resolve through \`agent/utils/paths.lua\`,
  which rejects escapes outside the project root unless overridden.

## Persona Integrity & Prompt Prioritization
To ensure high reliability for agentic tasks, the Jenova system employs a strict **System Prompt Prioritization** logic at the proxy layer:
1. **Client Sovereignty**: If a client (like \`jvim\`) provides its own specialized agent system prompt, the proxy **prioritizes** it.
2. **Mandate Injection**: The "CORE MANDATE" (Identity and Autonomy instructions) is only prepended if no existing system prompt is detected, preventing "identity confusion" and conversational drift.
3. **Context Merging**: Project-specific contexts (RAG hits, web search results) are cleanly appended to the existing system prompt rather than overwriting it, ensuring the agent retains its core operating instructions while gaining fresh knowledge.
