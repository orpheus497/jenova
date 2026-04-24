-- jenova/agent/tools/buffer_multiedit.lua
-- jvim-native override for the shared "MultiEdit" tool.
-- Applies multiple sequential line-range-based edits to a single file.

local paths = require("utils.paths")

local M = {
  name        = "MultiEdit",
  description = "Apply multiple sequential line-range edits to a single file in one operation. " ..
    "Always Read the file first to get accurate line numbers. " ..
    "IMPORTANT: Edits MUST be ordered from bottom to top (highest line numbers first) " ..
    "so that earlier edits do not shift the line numbers for subsequent edits.",
  parameters  = {
    type = "object",
    properties = {
      file_path = { type = "string", description = "Absolute or workspace-relative file path to edit" },
      edits = {
        type = "array",
        description = "Array of edit operations, MUST be ordered from highest line number to lowest.",
        items = {
          type = "object",
          properties = {
            start_line = { type = "integer", description = "The 1-based line number to start replacing from" },
            end_line   = { type = "integer", description = "The 1-based line number to end replacing at (inclusive)" },
            new_string = { type = "string",  description = "The new replacement text" },
          },
          required = { "start_line", "end_line", "new_string" }
        }
      }
    },
    required = { "file_path", "edits" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
  return input and input.file_path and ("MultiEdit: " .. input.file_path) or "MultiEdit"
end

function M.check_permissions(input, ctx)
  local ok_mgr, manager = pcall(require, "permissions.manager")
  if not ok_mgr or not manager or not manager.can_use_tool then
    return { allowed = true }
  end
  local allowed, reason = manager.can_use_tool("MultiEdit", input, ctx or {})
  return { allowed = allowed, reason = reason }
end

function M.call(args, context)
  local path = args.file_path or args.path
  if not path or path == "" then return { type = "error", error = "file_path is required" } end
  local edits = args.edits
  if type(edits) ~= "table" or #edits == 0 then return { type = "error", error = "edits array is required and must not be empty" } end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")

  -- Use bufadd/bufload to handle the file transparently
  local buf = vim.fn.bufadd(abs)
  pcall(vim.fn.bufload, buf)

  local buf_line_count = vim.api.nvim_buf_line_count(buf)
  
  -- Sort edits in descending order of start_line so that replacements don't shift subsequent lines
  local sorted_edits = {}
  for _, e in ipairs(edits) do table.insert(sorted_edits, e) end
  table.sort(sorted_edits, function(a, b)
    return (a.start_line or 0) > (b.start_line or 0)
  end)

  for i, edit in ipairs(sorted_edits) do
    local start_line = edit.start_line
    local end_line = edit.end_line
    local new_string = edit.new_string

    if type(start_line) ~= "number" or type(end_line) ~= "number" or not new_string then
      return { type = "error", error = string.format("Edit %d is missing required fields or has invalid types", i) }
    end
    if start_line < 1 then return { type = "error", error = string.format("Edit %d: start_line must be >= 1", i) } end
    if end_line < start_line - 1 then return { type = "error", error = string.format("Edit %d: end_line cannot be less than start_line - 1", i) } end
    if start_line > buf_line_count + 1 then
      return { type = "error", error = string.format("Edit %d: start_line %d is beyond the file length", i, start_line) }
    end

    if new_string:sub(-1) == "\n" then
      new_string = new_string:sub(1, -2)
    end

    local new_lines = new_string == "" and {} or vim.split(new_string, "\n", { plain = true })
    
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(buf, start_line - 1, math.min(end_line, buf_line_count), false, new_lines)
    end)

    if not ok then
      return { type = "error", error = string.format("Failed to apply edit %d: %s", i, tostring(err)) }
    end
    -- Update buf_line_count for subsequent edits
    buf_line_count = vim.api.nvim_buf_line_count(buf)
  end

  vim.bo[buf].modified = true
  local bname = vim.api.nvim_buf_get_name(buf)
  if bname ~= "" then
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent! write " .. vim.fn.fnameescape(bname))
    end)
  end

  return { type = "text", text = string.format("Successfully applied %d edits to %s", #edits, path) }
end

return M
