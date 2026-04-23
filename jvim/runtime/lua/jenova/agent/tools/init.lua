-- jenova/agent/tools/init.lua
-- Registers jvim-native tool overrides on the shared tool registry.
-- Called once during agent bootstrap from jenova/agent/init.lua.
--
-- Priority: jvim tools shadow cli-agent tools with the same name so the
-- agent automatically uses buffer APIs instead of disk I/O when running
-- inside the editor.

local M = {}

function M.register_overrides()
  -- The shared tool registry lives in cli-agent/lua/tools/registry.lua,
  -- synced to jenova/agent/shared/tools/registry.lua at build time.
  local ok, registry = pcall(require, "tools.registry")
  if not ok then
    -- Try absolute shared path as fallback
    ok, registry = pcall(require, "jenova.agent.shared.tools.registry")
  end
  if not ok then
    vim.notify("jenova.agent.tools: registry not found — skipping overrides",
      vim.log.levels.WARN, { title = "Jenova Agent" })
    return
  end

  local buffer_read = require("jenova.agent.tools.buffer_read")
  local buffer_edit = require("jenova.agent.tools.buffer_edit")

  -- Override Read → buffer_read (live buffer content, falls back to disk)
  registry.register(buffer_read)

  -- Override Edit → buffer_edit (buffer API search-and-replace)
  registry.register(buffer_edit)
end

return M
