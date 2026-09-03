-- jvim.layout — coordinate the IDE panel layout. Replaces edgy.nvim by
-- driving jvim.tree (left), jvim.terminal / jvim.diagnostics_list (bottom),
-- and the chat region (right) directly. No third-party docking layer.
--
-- Public API:
--   require("jvim.layout").open_ide()    -- :IDE entry point
--   require("jvim.layout").close_ide()
--   require("jvim.layout").toggle_ide()

local M = {}

local function safe(mod, fn, ...)
  local ok, m = pcall(require, mod)
  if not ok then return end
  if m[fn] then m[fn](...) end
end

local function dashboard_close()
  if vim.bo.filetype == "jvimdashboard" then
    pcall(function() require("jvim.dashboard").close() end)
  end
end

function M.open_ide()
  dashboard_close()
  -- Order matters: open the tree first so the editor area is to the right
  -- of it; then drop the terminal at the bottom of the editor area.
  safe("jvim.tree", "open")
  safe("jvim.terminal", "toggle_shell")
  -- Move focus back to the editor (centre column).
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local ft = vim.bo[b].filetype
    if ft ~= "jvimtree" and ft ~= "jvimterminal" and ft ~= "jvimdiaglist" then
      vim.api.nvim_set_current_win(w)
      break
    end
  end
end

function M.close_ide()
  safe("jvim.tree", "close")
  -- Terminal exposes only toggle_shell; if a shell window exists, toggle off.
  local ok, term = pcall(require, "jvim.terminal")
  if ok and term.toggle_shell then
    -- Best-effort: find the terminal window and close it directly.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "jvimterminal" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end
  safe("jvim.diagnostics_list", "close")
end

function M.toggle_ide()
  local tree_open = (function()
    local ok, t = pcall(require, "jvim.tree")
    return ok and t.is_open and t.is_open()
  end)()
  if tree_open then M.close_ide() else M.open_ide() end
end

function M.setup()
  vim.api.nvim_create_user_command("JvimIDE", M.open_ide, { desc = "Open IDE layout" })
  vim.api.nvim_create_user_command("JvimIDEClose", M.close_ide, { desc = "Close IDE layout" })
end

return M
