-- jenova/agent/tools/buffer_edit.lua
-- jvim-native override for the shared "Edit" tool.
-- Applies line-range-based edits via vim.api.nvim_buf_set_lines so:
--   • Edits are immediately visible in the open buffer (real-time preview)
--   • Undo history is preserved inside vim
--   • Exact string matching is completely avoided, making edits robust

local paths = require("utils.paths")

local M = {
  name        = "Edit",
  description = "Edit a file using line ranges instead of string matching. " ..
    "Replaces lines from start_line to end_line (inclusive) with new_string. " ..
    "Line numbers are 1-based. To insert without deleting, use start_line = end_line + 1. " ..
    "Always Read the file first to know the exact line numbers.",
  parameters  = {
    type = "object",
    properties = {
      file_path   = { type = "string",  description = "Absolute or workspace-relative file path to edit" },
      start_line  = { type = "integer", description = "The 1-based line number to start replacing from" },
      end_line    = { type = "integer", description = "The 1-based line number to end replacing at (inclusive)" },
      new_string  = { type = "string",  description = "The new replacement text" },
    },
    required = { "file_path", "start_line", "end_line", "new_string" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
  return input and input.file_path and ("Edit: " .. input.file_path) or "Edit"
end

function M.check_permissions(input, ctx)
  local ok_mgr, manager = pcall(require, "permissions.manager")
  if not ok_mgr or not manager or not manager.can_use_tool then
    return { allowed = true }
  end
  local allowed, reason = manager.can_use_tool("Edit", input, ctx or {})
  return { allowed = allowed, reason = reason }
end

function M.call(args, context)
  local path       = args.file_path or args.path
  local start_line = args.start_line
  local end_line   = args.end_line
  local new_string = args.new_string

  if not path or path == "" then return { type = "error", error = "file_path is required" } end
  if type(start_line) ~= "number" then return { type = "error", error = "start_line is required and must be a number" } end
  if type(end_line) ~= "number" then return { type = "error", error = "end_line is required and must be a number" } end
  if new_string == nil then return { type = "error", error = "new_string is required" } end
  if start_line < 1 then return { type = "error", error = "start_line must be >= 1" } end
  if end_line < start_line - 1 then return { type = "error", error = "end_line cannot be less than start_line - 1" } end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")

  -- Use bufadd/bufload to handle the file transparently whether open or not
  local buf = vim.fn.bufadd(abs)
  pcall(vim.fn.bufload, buf)

  local buf_line_count = vim.api.nvim_buf_line_count(buf)
  if start_line > buf_line_count + 1 then
    return { type = "error", error = string.format("start_line %d is beyond the file length of %d lines", start_line, buf_line_count) }
  end

  -- Trim any trailing newline to prevent inserting an extra blank line
  if new_string:sub(-1) == "\n" then
    new_string = new_string:sub(1, -2)
  end

  local new_lines = new_string == "" and {} or vim.split(new_string, "\n", { plain = true })
  
  local ok, err = pcall(function()
    -- vim.api.nvim_buf_set_lines uses 0-based indexing and is end-exclusive
    vim.api.nvim_buf_set_lines(buf, start_line - 1, math.min(end_line, buf_line_count), false, new_lines)
  end)

  if not ok then
    return { type = "error", error = "Failed to apply edit: " .. tostring(err) }
  end

  vim.bo[buf].modified = true
  local bname = vim.api.nvim_buf_get_name(buf)
  if bname ~= "" then
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent! write " .. vim.fn.fnameescape(bname))
    end)
  end

  return { type = "text", text = string.format("Successfully replaced lines %d to %d in %s", start_line, end_line, path) }
end

return M
