# CLI Agent Unification Plan

> **Status:** Phases 1–3 complete. Phase 4 (cleanup) is low-priority and ongoing.

## Problem Statement (resolved)

The CLI agent previously had two competing agentic loops:
1. `agent/loop.lua` — legacy, simple, single tool-batch per turn, text-based tool parsing
2. `engine/query_engine.lua` — proper multi-turn tool loop, streaming, permissions, memory

Slash commands (`/review`, `/commit`, `/btw`) used QueryEngine. The REPL main loop used
the legacy `agent/loop.lua`. This meant the primary user experience got inferior tool-calling
compared to slash commands.

**Resolution:** `agent/loop.lua` now delegates entirely to `QueryEngine:query()`. There is a
single agentic code path for all entry points.

---

## Phase 1: Bug Fixes ✅ (complete)

### 1.1 `permissions/manager.lua` — state access ✅
`app_state.permission_mode` → `app_state.get("permission_mode")`.
Now reads from `app_state.get()` first, then falls back to `config.get()`.

### 1.2 `tools/registry.lua:83` — forward context to tool.call() ✅
`tool_registry.execute(name, args, context)` passes `context` through to `tool.call(args, context)`.

### 1.3 `tools/registry.lua` — register `local_search` ✅
`LocalSearch` tool is registered in the tool registry.

### 1.4 `extended.lua` — `/backend` arg parsing ✅
Uses `args:match("^(%S+)")` instead of `args[1]`.

### 1.5 `file_edit.lua` — permission bypass ✅
Delegates permission check to `permissions.manager` like Shell does.

### 1.6 `config/loader.lua` — remove unused top-level `fs` ✅
Dead import removed.

### 1.7 `context/manager.lua` — wire user_ctx into output ✅
User context is included in `build_context_string()`.

### 1.8 `app_state.lua` — seed random ✅
`math.randomseed` called in module init for unique session IDs.

### 1.9 `ported.lua` — `stringify_pretty` call ✅
`stringify(..., {pretty=true})` used consistently.

---

## Phase 2: Eliminate Double Permission Check ✅ (complete)

`tool_registry.execute()` is the single enforcement point for permissions.
`QueryEngine` does not duplicate the `can_use_tool()` check.

---

## Phase 3: Unify the Agent Loop ✅ (complete)

`agent/loop.lua` is a thin shim that delegates to `QueryEngine:query()`.
All REPL and slash-command paths use the same multi-turn tool loop with streaming,
proper tool_use block parsing, memory/cost tracking, and permission enforcement.

---

## Phase 4: Cleanup (ongoing, low priority)

- [ ] Remove dead `process_tool_calls()` and `execute_tool()` in `agent/loop.lua` if confirmed unreachable
- [ ] Consolidate `provider_base.generate()` vs `create_message_stream()` (two call paths remain)
- [ ] Fix `providers/base.lua:87` duplicate entry in priority list
- [ ] Make `config/loader.lua` health check async or skippable
