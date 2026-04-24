-- jenova/agent/tools/buffer_read.lua
-- jvim-native override for the shared "Read" tool.
--
-- Provides line-numbered output essential for line-range based editing.
-- When the file is open in a jvim buffer the live buffer content is
-- returned. Otherwise the file is loaded into a hidden buffer.

local paths = require("utils.paths")

local M = {
  name = "Read",
  description = "Read file with line numbers. You MUST Read before Edit/MultiEdit to get exact line numbers.",
  parameters = {
    type = "object",
    properties = {
      file_path  = { type = "string" },
      start_line = { type = "integer", description = "1-based start" },
      end_line   = { type = "integer", description = "1-based end" },
    },
    required = { "file_path" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
  return input and input.file_path and ("Read: " .. input.file_path) or "Read"
end

function M.check_permissions(_input, _ctx) return { allowed = true } end

local function format_lines(lines, start_line, end_line)
  local out = {}
  local sl = start_line or 1
  local el = end_line or #lines
  local total = #lines
  local truncated = false
  
  -- Limit to a max of 2000 lines if end_line isn't provided
  if not end_line and (total - sl) > 2000 then
    el = sl + 1999
    truncated = true
  end

  for i, l in ipairs(lines) do
    if i >= sl and i <= el then
      table.insert(out, string.format("%d | %s", i, l))
    end
  end
  return table.concat(out, "\n"), total, truncated, el
end

function M.call(args, context)
  local path = args.file_path or args.path
  if not path or path == "" then
    return { type = "error", error = "file_path is required" }
  end

  local start_line = args.start_line or (args.offset and args.offset + 1) or 1
  local end_line = args.end_line or (args.limit and (start_line + args.limit - 1))

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")

  -- Try to load into buffer. This will handle both open buffers and closed files cleanly.
  local buf = vim.fn.bufadd(abs)
  local ok_load, _ = pcall(vim.fn.bufload, buf)
  
  -- Check if file exists (empty buffer on non-existent file)
  local is_new_file = vim.fn.filereadable(abs) == 0
  local is_empty_buffer = vim.api.nvim_buf_line_count(buf) <= 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  
  if is_new_file and is_empty_buffer then
    return { type = "error", error = "File not found: " .. abs }
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text, total, truncated, last_read = format_lines(lines, start_line, end_line)
  
  local hint
  if truncated then
    hint = string.format(
      "[TRUNCATED: showing lines %d-%d of %d total. Call Read('%s', start_line=%d) to continue.]",
      start_line, last_read, total, path, last_read + 1)
  end

  return {
    type            = "text",
    text            = text,
    num_lines       = total,
    truncated       = truncated,
    truncation_hint = hint,
    source          = "buffer",
  }
end

return M
