# CLI Agent Unification Plan

## Problem Statement

The CLI agent has two competing agentic loops:
1. `agent/loop.lua` — legacy, simple, single tool-batch per turn, text-based tool parsing
2. `engine/query_engine.lua` — proper multi-turn tool loop, streaming, permissions, memory

Slash commands (`/review`, `/commit`, `/btw`) use QueryEngine. The REPL main loop
uses the legacy `agent/loop.lua`. This means the primary user experience (the REPL)
gets inferior tool-calling compared to slash commands.

Additionally, there are ~12 concrete bugs stemming from the duplication and
incomplete integration.

## Guiding Principles

- **Single source of truth**: One agentic loop (`QueryEngine`), used everywhere.
- **Surgical changes**: Each fix is small and independently correct.
- **No regressions**: The legacy loop is retired by routing through QueryEngine,
  not by deleting infrastructure it provides (UI, memory init, command dispatch).
- **Other agents at work**: Changes must be atomic per-file and avoid refactoring
  files that are actively being modified (check git status before touching).

---

## Phase 1: Bug Fixes (no architectural changes)

These are safe to apply immediately — they fix logical errors without changing
control flow or module boundaries.

### 1.1 `permissions/manager.lua:42` — state access bug
`app_state.permission_mode` → `app_state.get("permission_mode")`

### 1.2 `tools/registry.lua:83` — forward context to tool.call()
`tool_registry.execute(name, args, context)` must pass `context` through to
`tool.call(args, context)`.

### 1.3 `tools/registry.lua:108` — register `local_search`
Add `"tools.local_search"` to `load_builtin_tools()`.

### 1.4 `extended.lua:729` — `/backend` treats args as table
Change `args[1]` to `args:match("^(%S+)")`.

### 1.5 `file_edit.lua:28` — permission bypass
Delegate to permissions manager like Bash does.

### 1.6 `config/loader.lua:5` — remove unused top-level `fs`
Remove the dead import.

### 1.7 `context/manager.lua:135` — wire user_ctx into output
Include user context in `build_context_string()`.

### 1.8 `app_state.lua` — seed random
Add `math.randomseed(os.time() + (os.clock() * 1000))` in module init.

### 1.9 `ported.lua:149` — `stringify_pretty` → `stringify(..., {pretty=true})`

---

## Phase 2: Eliminate Double Permission Check

### 2.1 `query_engine.lua:259-268`
Remove the direct `permissions.can_use_tool()` call. Let `tool_registry.execute()`
handle it (it already calls `tool.check_permissions`). Or, vice versa: have
`tool_registry.execute()` NOT call check_permissions and let the caller decide.

**Decision**: The registry's `execute()` should be the single enforcement point.
QueryEngine should NOT also check. This keeps tool invocation consistent regardless
of caller.

---

## Phase 3: Unify the Agent Loop

### 3.1 Refactor `agent/loop.lua` to delegate to `QueryEngine`

The REPL infrastructure in `agent/loop.lua` (prompt reading, slash command dispatch,
history, `/clear`, `/exit`) is fine. What's broken is the **LLM call + tool execution**
path inside `agent_turn()`.

**Change**: Replace the inline generate-parse-execute logic in `agent_turn()` with a
call to `QueryEngine:query()`. This gives the REPL:
- Multi-turn tool loops (not just one follow-up)
- Streaming support
- Proper tool_use block parsing (not just text extraction)
- Memory/cost tracking

The REPL keeps: prompt, command dispatch, history, interrupts, UI.

### 3.2 Wire `is_interrupted` properly
Expose a module-level flag set by a C signal handler (or check a global that the
C main sets). For now, default to a no-op that doesn't crash.

---

## Phase 4: Cleanup (low priority, after stabilization)

- Remove `agent/loop.lua`'s inline `process_tool_calls()` (dead code after Phase 3)
- Remove `agent/loop.lua`'s inline `execute_tool()` (dead code)
- Consolidate the `provider_base.generate()` path vs `create_message_stream()`
- Fix `providers/base.lua:87` double-entry in priority list
- Fix `config/loader.lua` blocking health check (make it async or skip)

---

## Execution Order

1. Phase 1 fixes (safe, independent, no conflicts)
2. Phase 2 (depends on 1.2 being done first)
3. Phase 3 (depends on Phase 2)
4. Phase 4 (optional cleanup)
