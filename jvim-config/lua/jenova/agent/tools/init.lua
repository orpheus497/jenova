local NATIVE_TOOLS = {
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
  "jenova.agent.tools.ask_user",
}

local M = {}

function M.setup()
  local ok, registry = pcall(require, "tools.registry")
  if not ok then
    vim.notify("jenova.agent.tools: registry not found", vim.log.levels.ERROR, {title="Jenova Agent"})
    return
  end
  if registry.clear then registry.clear() end
  for _, mod in ipairs(NATIVE_TOOLS) do
    local mok, tool = pcall(require, mod)
    if mok and tool and tool.name and tool.call then
      registry.register(tool)
    else
      vim.notify("jenova.agent.tools: failed to load "..mod..": "..tostring(tool),
        vim.log.levels.WARN, {title="Jenova Agent"})
    end
  end
end

return M