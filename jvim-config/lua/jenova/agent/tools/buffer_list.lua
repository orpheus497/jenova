-- jenova/agent/tools/buffer_list.lua
-- jvim-native tool: list all open jvim buffers/tabs.
--
-- The user's normal workflow is to have several files open and ask the
-- agent about "the other related files". Without a tool that exposes the
-- editor state, the model has to guess paths via Glob. This tool returns
-- the same buffer list jvim's tabline shows, so the model can directly
-- Read each entry.

local M = {
  name        = "Buffers",
  description = "List all currently open files (buffers/tabs) in jvim. " ..
    "Use this when the user mentions 'the other files', 'this project', " ..
    "'related files', or 'open tabs'. Each entry includes the absolute path, " ..
    "a 'modified' flag for unsaved buffers, and a marker for the active buffer. " ..
    "After listing, you can pass any path straight to Read.",
  parameters  = {
    type = "object",
    properties = {},
    required = {},
  },
}

function M.is_enabled()    return true end
function M.is_read_only()  return true end
function M.user_facing_name(_) return "Buffers" end
function M.check_permissions(_i, _c) return { allowed = true } end

function M.call(_args, _ctx)
  local current = vim.api.nvim_get_current_buf()
  local entries = {}

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name and name ~= "" then
        local marker   = (b == current) and "*" or " "
        local modified = vim.bo[b].modified and " [modified]" or ""
        local ft       = vim.bo[b].filetype or ""
        local lines    = vim.api.nvim_buf_line_count(b)
        table.insert(entries, string.format(
          "%s %s  (%s, %d lines)%s",
          marker, name, ft ~= "" and ft or "?", lines, modified))
      end
    end
  end

  if #entries == 0 then
    return {
      type = "text",
      text = "No open buffers (only the chat / scratch buffer is loaded).",
    }
  end

  table.insert(entries, 1, string.format(
    "%d buffer(s) open. '*' marks the active buffer.\ncwd: %s\n",
    #entries, vim.fn.getcwd()))

  return {
    type = "text",
    text = table.concat(entries, "\n"),
  }
end

return M
