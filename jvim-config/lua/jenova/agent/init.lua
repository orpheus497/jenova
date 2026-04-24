-- jvim-config/lua/jenova/agent/init.lua
-- 100% jvim-native Agent Bootstrap. ZERO CLI SHIMS.

local M = {}
local registry = require("jenova.agent.registry")
local engine_mod = require("jenova.agent.engine")
local context = require("jenova.agent.context")

M._running = false
M._engine  = nil
M._usage   = { input_tokens = 0, output_tokens = 0, total_cost_usd = 0 }

-- Register all native jvim tools via the tools module.
function M.setup()
  require("jenova.agent.tools").setup()
end

function M.query(prompt, opts, buf, history)
  M._running = true

  if not M._engine then
    -- First query in this session: build the full system prompt with the
    -- active buffer content injected. This happens once per chat — the
    -- agent has the file from the start and doesn't need it re-injected.
    local sys = context.build_system_prompt(buf)
    M._engine = engine_mod.new({
      system_prompt  = sys,
      on_text        = opts.on_text,
      on_tool_use    = opts.on_tool_use,
      on_tool_result = opts.on_tool_result,
      on_thinking    = opts.on_thinking,
    })
  else
    -- Continuing session: update only the per-turn callbacks. System prompt
    -- (and the buffer snapshot it contains) is left as set at session start.
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
    M._running = false
    if not ok then
      if opts.on_error then opts.on_error(tostring(err)) end
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
  M._engine = nil
end

-- Signal the engine to stop after the current tool call completes.
function M.stop()
  M._running = false
  if M._engine then M._engine._stop = true end
end

return M
