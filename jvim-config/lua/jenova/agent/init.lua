-- jvim-config/lua/jenova/agent/init.lua
-- 100% jvim-native Agent Bootstrap. ZERO CLI SHIMS.

local M = {}
local engine_mod = require("jenova.agent.engine")
local context = require("jenova.agent.context")

M._running    = false
M._engine     = nil
M._usage      = { input_tokens = 0, output_tokens = 0, total_cost_usd = 0 }
M._just_reset = false   -- set by reset(); cleared after next engine creation so
                        -- the caller's history is ignored for that one query.
M._active_job = nil     -- vim.system handle for the in-flight curl, if any

-- Register all native jvim tools via the tools module.
function M.setup()
  require("jenova.agent.tools").setup()
end

function M.query(prompt, opts, buf, history)
  if M._running then
    if opts and opts.on_error then
      opts.on_error("Agent is already running. Use /stop first.")
    end
    return
  end
  M._running = true

  if not M._engine then
    -- On a brand-new session with no prior conversation, inject the open file
    -- as a background seed exchange so the model has it prominently in its
    -- conversation history (in addition to the system-prompt snapshot).
    if not M._just_reset and (not history or #history == 0) then
      local seed = context.build_file_seed_prompt()
      if seed then
        history = {
          { role = "user",      content = seed },
          { role = "assistant", content = "File received. Ready." },
        }
      end
    end
    -- First query in this session (or after a reset): build the full system
    -- prompt with the active buffer content injected.
    local sys = context.build_system_prompt(buf)
    M._engine = engine_mod.new({
      system_prompt  = sys,
      on_text        = opts.on_text,
      on_tool_use    = opts.on_tool_use,
      on_tool_result = opts.on_tool_result,
      on_thinking    = opts.on_thinking,
    })
    -- After a reset we deliberately ignore the caller's history so the
    -- engine starts with a clean slate even though the buffer still contains
    -- the old turns.
    if M._just_reset then
      M._just_reset = false
      history = nil
    end
  else
    -- Continuing session: update only the per-turn callbacks.
    M._engine.on_text        = opts.on_text        or M._engine.on_text
    M._engine.on_tool_use    = opts.on_tool_use    or M._engine.on_tool_use
    M._engine.on_tool_result = opts.on_tool_result or M._engine.on_tool_result
    M._engine.on_thinking    = opts.on_thinking    or M._engine.on_thinking
  end

  -- Caller passes prior conversation turns as history; engine appends the new
  -- user message itself so we only supply the preceding turns here.
  if history then M._engine.messages = history end

  local provider = require("jenova.agent.provider")

  local co = coroutine.create(function()
    local ok, err = pcall(M._engine.query, M._engine, prompt, provider)
    local was_stopped = M._engine and M._engine._stop
    M._running    = false
    M._active_job = nil
    if not ok then
      if was_stopped then
        -- User intentionally stopped: the kill produced an internal error but
        -- we surface a clean completion (no "✗ Error:" in the buffer).
        if opts.on_done then opts.on_done({ input = 0, output = 0, cost = 0 }) end
      else
        if opts.on_error then opts.on_error(tostring(err)) end
      end
    else
      if opts.on_done then opts.on_done({ input = 0, output = 0, cost = 0 }) end
    end
  end)

  coroutine.resume(co)
end

-- ── Query introspection (used by chat.lua /history and /debug) ────────────────

function M.get_messages()
  return M._engine and M._engine.messages or {}
end

function M.get_usage()
  return M._usage
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function M.clear()
  if M._engine then M._engine.messages = {} end
end

function M.reset()
  M._engine     = nil
  M._just_reset = true
  -- Wipe the per-session repetition cache so a fresh conversation starts
  -- with no held-over "this call just failed" state. Persistent learning
  -- stats on disk are unaffected.
  local ok, registry = pcall(require, "jenova.agent.registry")
  if ok and registry and registry.reset_learning_session then
    pcall(registry.reset_learning_session)
  end
end

-- Signal the engine to stop after the current tool call completes, and kill
-- the in-flight curl process immediately so the proxy connection is freed.
function M.stop()
  M._running = false
  if M._engine then M._engine._stop = true end
  if M._active_job then
    pcall(function() M._active_job:kill(9) end)
    M._active_job = nil
  end
end

return M
