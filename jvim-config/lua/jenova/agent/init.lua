-- jvim-config/lua/jenova/agent/init.lua
-- 100% jvim-native Agent Bootstrap. ZERO CLI SHIMS.

local M = {}
local registry = require("jenova.agent.registry")
local engine_mod = require("jenova.agent.engine")
local context = require("jenova.agent.context")

M._running = false
M._engine = nil

function M.setup()
  -- Register all native jvim tools
  local tools = {
    "jenova.agent.tools.buffer_read",
    "jenova.agent.tools.buffer_edit",
    "jenova.agent.tools.buffer_write",
    "jenova.agent.tools.buffer_multiedit",
    "jenova.agent.tools.buffer_glob",
    "jenova.agent.tools.buffer_grep",
    "jenova.agent.tools.buffer_ls",
    "jenova.agent.tools.buffer_list",
    "jenova.agent.tools.buffer_shell",
    "jenova.agent.tools.lsp",
  }
  for _, mod in ipairs(tools) do
    local ok, tool = pcall(require, mod)
    if ok and tool then registry.register(tool) end
  end
end

function M.query(prompt, opts, buf, history)
  M._running = true
  local sys = context.build_system_prompt(buf)
  
  if not M._engine then
    M._engine = engine_mod.new({
      system_prompt = sys,
      on_text = opts.on_text,
      on_tool_use = opts.on_tool_use,
      on_tool_result = opts.on_tool_result,
    })
  else
    M._engine.system_prompt = sys
  end

  if history then M._engine.messages = history end

  local provider = require("jenova.agent.provider")
  
  local co = coroutine.create(function()
    M._engine:query(prompt, provider)
    M._running = false
    if opts.on_done then opts.on_done({ input = 0, output = 0, cost = 0 }) end
  end)
  
  coroutine.resume(co)
end

function M.clear()
  if M._engine then M._engine.messages = {} end
end

function M.reset()
  M._engine = nil
end

return M
