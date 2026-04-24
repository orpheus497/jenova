# Jenova Master Plan

## Vision

Jenova is a local-first AI coding environment. The **canonical interactive experience** is
`jvim` — the purpose-built Neovim hard-fork. The agent lives *inside* the editor, not
alongside it in a terminal pane. The CLI agent remains as a thin headless wrapper for
scripted / CI / one-shot workflows only.

```
jenova          → starts backend daemons + jvim (full environment)
jvim            → starts ONLY the editor (no backend management)
bin/jenova-ca   → starts ONLY the backend daemons (headless / server use)
bin/jenova      → CLI agent (headless / scripted / one-shot)
```

The central thesis: **the CLI agent's failures come from context-blindness**. It cannot
see what is in the editor, what the cursor is on, or what the LSP knows. Embedding the
agent in jvim fixes this at the root by giving it:

- **Hardened context automation** — project tree + active buffer + LSP pushed to prompt
- **Zero-paste chat flow** — context is linked via metadata, not copied into history
- [ ] `jenova/agent/ui/inline.lua` — inline diff preview before applying edits
- [ ] `jenova/agent/tools/lsp.lua` — LSP hover, definition, references via `vim.lsp`
- [ ] `jenova/agent/tools/cursor.lua` — cursor position / selection context tool

---

## Research: Database & Indexing Strategy (Internal Only)

**Current State:**
- **Legacy (`.crush/crush.db`):** An independent SQLite store used for session history, file versioning, and TODO tracking. It is a standalone system and is **NOT** currently connected to the jvim environment.
- **Active (`.jenova/vectors.json`):** A lightweight JSON-based hybrid (BM25 + Semantic) index managed by the backend (`lib/search.lua`). This is the primary source for the jvim agent's codebase awareness.

**Goal:**
Identify a unified, high-performance method for persistent agent state without introducing the overhead of the legacy `crush` system.
- **Do NOT** connect jvim to `crush.db`.
- Research how to move from `vectors.json` to a more robust, queryable format (e.g., a dedicated `jenova.db`) while keeping it fully separate from legacy implementations.
- Investigate "Passive RAG" — where the editor pushes relevant snippets to the agent based on cursor movement and buffer activity.

---

## Current State (as of this branch)

| Component | Status |
|---|---|
| `jvim` — editor | ✅ Built in-tree, native UI (statusline, tree, finder, notify…) |
| `jenova/` runtime plugins | ✅ chat, monitor, health, LAN discovery, llama.vim FIM |
| `cli-agent` — C + Lua 5.4 | ✅ Phases 1–3 complete; file tracker + tool verifier merged (PR #43) |
| `lib/` — backend daemons | ✅ proxy, embedding server, daemon supervisor |
| `bin/jvim` launcher | ✅ starts backend + editor |
| `bin/jenova` launcher | ✅ CLI REPL / one-shot |
| **jvim embedded agent** | 🟡 Phase 2 in progress — skeleton complete |
| `jenova` top-level launcher | 🔴 Not started — this plan |

---

## Architecture: Three Entry Points

### `jenova` (new top-level launcher)
The *full environment* entry point. A shell script that:
1. Starts `jenova-ca --daemon` (if not already running)
2. Waits for backend health
3. Launches `jvim` (which loads the embedded agent automatically)

Users who want the complete experience type `jenova`. Power users who manage the backend
separately type `jvim`.

### `jvim` (editor only)
Launches the editor. Does **not** start the backend. Accepts the same `--remote`,
`--no-backend`, `--check` flags as today. The embedded agent is always available inside
jvim — it connects to whatever backend is reachable (local or remote).

### `bin/jenova` (CLI agent)
Unchanged thin wrapper. Headless / scripted use, CI pipelines, one-shot prompts.
Context-blind by nature; useful for tasks that don't need editor integration.

---

## Phase 1 — Launch Semantics (immediate)

**Goal:** `jenova` starts the world; `jvim` starts just the editor.

### 1.1 Create `bin/jenova` top-level launcher (rename / refactor)

Current `bin/jenova` invokes `cli-agent`. Rename it to `bin/jenova-cli`. Create a new
`bin/jenova` that:

```sh
#!/bin/sh
# bin/jenova — full environment launcher
# 1. Start backend
bin/jenova-ca --daemon --wait
# 2. Launch editor (which has the embedded agent)
exec bin/jvim "$@"
```

Flags pass through to `jvim` (`--remote`, `--no-backend`, etc.).
`bin/jenova --cli` or `bin/jenova --headless` drops through to `bin/jenova-cli`.

### 1.2 Update `bin/jvim`

Remove backend auto-start responsibility from `jvim`. `jvim` should:
- Export env vars (`JENOVA_CONNECT_HOST`, `JENOVA_PORT`, etc.) from `jenova.conf`
- Launch the editor
- NOT call `jenova-ca --daemon` (that is `jenova`'s job now)

Keep `--no-backend` flag for raw editor use.

### 1.3 Update `scripts/install.sh`

Symlink `jenova`, `jvim`, `jenova-ca`, `jenova-cli` to PATH. Update the man page and
help text in each binary.

### 1.4 Update `Makefile`

`make install` wires the new `bin/jenova` launcher. `make cli-agent` still builds
`cli-agent/build/cli-agent` and wires it as `jenova-cli`.

---

## Phase 2 — jvim Embedded Agent (core work)

**Goal:** A fully functional agentic loop running inside jvim, context-aware, with
buffer/LSP tools.

- [x] Create `jenova/agent/init.lua` — path shim + QueryEngine bootstrap with jvim callbacks
- [x] Create `jenova/agent/provider.lua` — jvim-native HTTP via `vim.system` (non-blocking)
- [x] Create `jenova/agent/tools/buffer_read.lua` — live buffer read via `vim.api`
- [x] Create `jenova/agent/tools/buffer_edit.lua` — buffer search-and-replace via `vim.api`
- [x] Create `jenova/agent/tools/init.lua` — registers jvim overrides on the shared tool registry
- [x] Create `jenova/agent/context.lua` — editor state injected into system prompt
- [x] Wire `chat.lua` `respond()` → `jenova.agent.query()` (full agentic loop, falls back to streaming)
- [x] Add `<leader>aa` and `<leader>af` keymaps
- [x] Add `make sync-modules` Makefile target
- [ ] `jenova/agent/ui/inline.lua` — inline diff preview before applying edits
- [ ] `jenova/agent/tools/lsp.lua` — LSP hover, definition, references via `vim.lsp`
- [ ] `jenova/agent/tools/cursor.lua` — cursor position / selection context tool

| cli-agent module | jvim reuse strategy |
|---|---|
| `engine/query_engine.lua` | Copy/symlink — minimal changes |
| `tools/registry.lua` | Reuse with jvim-native tool overrides |
| `providers/` | Reuse entirely |
| `config/loader.lua` | Reuse (reads same `etc/jenova.conf`) |
| `history/manager.lua` | Reuse |
| `context/manager.lua` | Reuse |
| `permissions/manager.lua` | Reuse with jvim UI adapter |
| `utils/` | Reuse entirely |
| `constants/prompts.lua` | Reuse, extend with editor context |

New jvim-native modules:

| Module | Purpose |
|---|---|
| `jenova/agent/init.lua` | Bootstrap: load engine, register jvim tools, start agent loop |
| `jenova/agent/tools/buffer.lua` | Read/write buffer content via `vim.api` |
| `jenova/agent/tools/edit_buffer.lua` | Apply edits to buffer (replaces file_edit.lua) |
| `jenova/agent/tools/lsp.lua` | LSP: hover, definition, references, diagnostics |
| `jenova/agent/tools/cursor.lua` | Cursor position, selection, surrounding context |
| `jenova/agent/tools/treesitter.lua` | AST-aware symbol extraction |
| `jenova/agent/ui/panel.lua` | Chat panel (extends existing `jenova/chat.lua`) |
| `jenova/agent/ui/inline.lua` | Inline diff preview in buffer |
| `jenova/agent/context/editor.lua` | Editor context: open files, git status, diagnostics |

### 2.2 Tool Override Table

When the agent runs inside jvim, certain CLI tools are replaced by buffer-native versions:

| CLI tool | jvim replacement | Why |
|---|---|---|
| `file_read.lua` (disk read) | `buffer.lua` (buffer API) | Instant, no stale-file risk |
| `file_edit.lua` (string search) | `edit_buffer.lua` (buffer API) | Zero false-negatives |
| `file_write.lua` (disk write) | `buffer.lua` write path | Visible in real-time |
| `lsp.lua` (CLI LSP client) | `lsp.lua` (native vim.lsp) | Full workspace LSP |
| `glob.lua` / `grep.lua` | Keep CLI versions | Fine for file discovery |
| `bash.lua` | Keep CLI version | Shell commands unchanged |

The tool registry uses a priority system: jvim tools shadow CLI tools when running
inside the editor.

### 2.3 Context Injection

The system prompt is augmented with live editor context before every query:

```
## Editor Context
- Current file: lua/engine/query_engine.lua (line 143, col 5)
- Cursor symbol: QueryEngine:query
- LSP diagnostics: 2 warnings in current buffer
- Open buffers: [list of open files]
- Git branch: cli3, 3 unstaged changes
- Selection: [if active visual selection, include the text]
```

This is injected by `jenova/agent/context/editor.lua` and replaces the need for the
agent to explicitly call Read before every edit.

### 2.4 UI: Chat Panel

Extend the existing `jvim/runtime/lua/jenova/chat.lua` to be the agent's primary UI.
The panel renders:
- Conversation history (markdown rendered via treesitter)
- Streaming token output
- Tool-use progress (inline: `⚙ Reading buffer...`, `✏ Editing line 143...`)
- Inline diff preview before applying edits (user can accept/reject)

Key bindings inside the agent panel:

| Key | Action |
|---|---|
| `<leader>aa` | Open / focus agent panel |
| `<leader>ac` | Chat with current buffer as context |
| `<leader>ae` | Explain visual selection |
| `<leader>ai` | Inline rewrite of selection |
| `<leader>af` | Fix diagnostics in current buffer |
| `<leader>ar` | Resume last conversation |
| `<leader>ax` | Stop generation |
| `<CR>` (in panel) | Send message |
| `q` / `<Esc>` (in panel) | Close panel |

### 2.5 Inline Edit Preview

Before the agent applies an edit to a buffer, it shows a floating diff:

```
┌─ Proposed edit ───────────────────────────────────────┐
│  - local result = tool_registry.execute(name, args)   │
│  + local ok, result = pcall(tool_registry.execute,    │
│  +   name, args, context)                             │
│                                                       │
│  [a] Accept  [r] Reject  [A] Accept all  [R] Reject all │
└───────────────────────────────────────────────────────┘
```

This is opt-in: configurable via `jenova.conf` (`JENOVA_AGENT_PREVIEW_EDITS=1`).
When disabled (default for non-interactive use), edits apply immediately.

### 2.6 Permission Model

The jvim permission model mirrors the CLI agent's permission manager but uses
`vim.ui.input` / floating prompts instead of stdin reads:

- `JENOVA_PERMISSION_MODE=auto` — all tools run without prompting (default)
- `JENOVA_PERMISSION_MODE=cautious` — prompt before destructive tools (edit, write, shell)
- `JENOVA_PERMISSION_MODE=strict` — prompt before every tool use

---

## Phase 3 — Build System Integration

### 3.1 Shared Lua Modules

The modules shared between `cli-agent` and jvim are maintained in `cli-agent/lua/`
as the source of truth. At build time (`make jvim`), a subset is copied into
`jvim/runtime/lua/jenova/agent/shared/`:

```makefile
SHARED_MODULES = \
  engine/query_engine.lua \
  tools/registry.lua \
  providers/base.lua \
  providers/init.lua \
  providers/jenova_backend.lua \
  providers/llamacpp.lua \
  config/loader.lua \
  history/manager.lua \
  context/manager.lua \
  context/file_tracker.lua \
  permissions/manager.lua \
  utils/array.lua \
  utils/http.lua \
  utils/json_fallback.lua \
  utils/paths.lua \
  utils/string.lua \
  constants/prompts.lua
```

Copy is preferred over symlinks to keep jvim's runtime self-contained and to allow
divergence where needed (jvim-specific overrides sit in `jenova/agent/` and shadow
shared modules via Lua's module resolution order).

### 3.2 Makefile Targets

```makefile
make              # build everything: llama + cli-agent + jvim (including module sync)
make jvim         # build jvim only (also syncs shared modules)
make cli-agent    # build cli-agent only
make sync-modules # copy shared Lua modules from cli-agent → jvim runtime
make install      # deploy, symlink jenova / jvim / jenova-ca / jenova-cli
```

### 3.3 Module Resolution in jvim

jvim's Lua `package.path` is set to prefer `jenova/agent/` over `jenova/agent/shared/`,
so any jvim-native override automatically wins without touching shared code.

---

## Phase 4 — CLI Agent Transition (Decommissioning)

The CLI agent (`bin/jenova-cli`, formerly `bin/jenova`) is **decommissioned as an interactive interface**. 
It remains available for:
- Headless / CI / scripted workflows
- Remote machines without a display
- One-shot prompts piped from shell scripts

**The canonical interactive experience is now `jvim` only.** 

### 4.1 CLI Agent Cleanup (open)
- [x] Add decommissioning notice to REPL.
- [ ] Remove dead `process_tool_calls()` / `execute_tool()` in `agent/loop.lua`
- [ ] Consolidate `provider_base.generate()` vs `create_message_stream()` call paths
- [ ] Fix `providers/base.lua:87` duplicate entry in priority list
- [ ] Make `config/loader.lua` health check async or skippable

---

## Phase 5 — Documentation & Cleanup

- [x] Update `README.md` — keymaps table, directory layout, build instructions
- [x] Consolidate auxiliary docs into root `README.md` + `PLAN.md` (removed `cli-agent/README.md`, `cli-agent/docs/architecture.md`, `cli-agent/docs/UNIFICATION_PLAN.md`; `models/README.md` and `hardware-profiles/README.md` retained as in-tree references)
- [ ] Add `jvim/runtime/lua/jenova/agent/` architecture doc
- [ ] Remove references to launching `bin/jenova` as an interactive terminal agent in
      user-facing docs (redirect to `jenova` top-level launcher)
- [ ] Update `scripts/install.sh` to symlink `jenova-cli` in addition to the new
      `jenova` top-level launcher

---

## Risk Register

| Risk | Mitigation |
|---|---|
| Shared module divergence (cli-agent vs jvim copy) | `make sync-modules` is idempotent; diff checked in CI |
| Lua 5.4 (cli-agent) vs LuaJIT (jvim) API incompatibilities | Shared modules avoid Lua 5.4-isms; tested in both runtimes |
| jvim buffer API instability | Buffer tools wrap `vim.api` with pcall; fallback to disk read on error |
| Permission model UX regression | jvim permission prompts tested manually; auto mode is default |
| `jenova` launcher masking old `bin/jenova` CLI semantics | `--cli` / `--headless` flag drops through; old `jenova-cli` binary preserved |

---

## Milestones

| Milestone | Description | Phase |
|---|---|---|
| M1 | `jenova` starts world; `jvim` starts editor only | 1 |
| M2 | `jenova/agent/` skeleton with buffer read/write tools | 2.1–2.2 |
| M3 | Context injection (editor state in system prompt) | 2.3 |
| M4 | Chat panel + streaming in jvim | 2.4 |
| M5 | Inline edit preview | 2.5 |
| M6 | LSP tools (`hover`, `definition`, `diagnostics`) | 2.2 |
| M7 | Build system: `make sync-modules` + CI | 3 |
| M8 | CLI agent cleanup (Phase 4) | 4 |
| M9 | Documentation pass | 5 |

---

## What We Are NOT Doing

- Not deleting the CLI agent
- Not replacing the backend (proxy.lua, llama-server) — it remains shared
- Not requiring a display for server / headless installs (`jenova-ca` + `jenova-cli` still work)
- Not introducing a plugin manager (jvim is self-contained)
- Not adding new external dependencies for the embedded agent
