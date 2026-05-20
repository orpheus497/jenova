-- jenova/agent/tools/buffer_multiedit.lua
-- jvim-native MultiEdit tool.
-- Applies multiple sequential line-range-based edits to a single file.

local paths = require("jenova.agent.utils.paths")

local M = {
  name = "MultiEdit",
  description = "Apply multiple line-range edits to one file. Edits are sorted bottom-to-top automatically so line numbers stay stable.",
  parameters = {
    type = "object",
    properties = {
      file_path = { type = "string" },
      edits = {
        type = "array",
        items = {
          type = "object",
          properties = {
            start_line = { type = "integer" },
            end_line   = { type = "integer" },
            new_string = { type = "string" },
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

function M.check_permissions() return { allowed = true } end

function M.call(args, context)
  local path = args.file_path or args.path
  if not path or path == "" then return { type = "error", error = "file_path is required" } end
  local edits = args.edits
  if type(edits) ~= "table" or #edits == 0 then
    return { type = "error", error = "edits array is required and must not be empty" }
  end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")
  local buf = vim.fn.bufadd(abs)
  pcall(vim.fn.bufload, buf)

  local initial_line_count = vim.api.nvim_buf_line_count(buf)

  -- Sort descending so edits don't shift subsequent line numbers.
  -- Use end_line as a tie-breaker for stable sorting of insertions at the same line.
  local sorted = {}
  for i, e in ipairs(edits) do
    e._orig_idx = i
    table.insert(sorted, e)
  end
  table.sort(sorted, function(a, b)
    if a.start_line ~= b.start_line then
      return (a.start_line or 0) > (b.start_line or 0)
    end
    if a.end_line ~= b.end_line then
      return (a.end_line or 0) > (b.end_line or 0)
    end
    return a._orig_idx > b._orig_idx
  end)

  for i, edit in ipairs(sorted) do
    local sl = edit.start_line
    local el = edit.end_line
    local ns = edit.new_string

    if type(sl) ~= "number" or type(el) ~= "number" or ns == nil then
      return { type = "error", error = string.format("Edit at index %d is missing required fields", edit._orig_idx) }
    end
    if sl < 1 then return { type = "error", error = string.format("Edit at index %d: start_line must be >= 1", edit._orig_idx) } end
    if el < sl - 1 then return { type = "error", error = string.format("Edit at index %d: end_line < start_line - 1", edit._orig_idx) } end
    
    -- Validate against the INITIAL line count, as descending sort ensures 
    -- line numbers above the current edit haven't shifted yet.
    if sl > initial_line_count + 1 then
      return { type = "error", error = string.format("Edit at index %d: start_line %d beyond file length %d", edit._orig_idx, sl, initial_line_count) }
    end

    local new_lines = {}
    if ns ~= "" then
      new_lines = vim.split(ns, "\n", { plain = true })
      if #new_lines > 0 and new_lines[#new_lines] == "" and ns:sub(-1) == "\n" then
        table.remove(new_lines)
      end
    end

    local current_line_count = vim.api.nvim_buf_line_count(buf)
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(buf, sl - 1, math.min(el, current_line_count), false, new_lines)
    end)
    if not ok then
      return { type = "error", error = string.format("Edit at index %d failed: %s", edit._orig_idx, tostring(err)) }
    end
  end

  vim.bo[buf].modified = true
  local bname = vim.api.nvim_buf_get_name(buf)
  if bname ~= "" then
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent! write " .. vim.fn.fnameescape(bname))
    end)
  end

  return { type = "text", text = string.format("Applied %d edit(s) to %s", #edits, path) }
end

return M
