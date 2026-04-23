-- jenova/agent/tools/buffer_read.lua
-- Replaces cli-agent's file_read.lua when running inside jvim.
-- Reads buffer content via vim.api instead of disk I/O, so:
--   • Content is always current (no stale-file risk)
--   • Works for buffers that have never been written to disk
--   • Supports line-range slicing (offset / limit matching cli-agent Read API)

local M = {
  name        = "Read",
  description = "Read the contents of a file or buffer. " ..
    "When the file is open in an editor buffer the live buffer content is returned. " ..
    "Supports optional start_line and end_line to read a specific range.",
  parameters  = {
    type = "object",
    properties = {
      path       = { type = "string", description = "Absolute or repo-relative file path" },
      start_line = { type = "number", description = "First line to read (1-based, optional)" },
      end_line   = { type = "number", description = "Last line to read (1-based, optional)" },
    },
    required = { "path" },
  },
}

local function find_buf_by_path(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs or bname == path then
        return b
      end
    end
  end
  return nil
end

function M.call(args, _ctx)
  local path = args.path
  if not path or path == "" then
    return { error = "path is required" }
  end

  local start_line = args.start_line
  local end_line   = args.end_line

  -- Try live buffer first
  local buf = find_buf_by_path(path)
  if buf then
    local total = vim.api.nvim_buf_line_count(buf)
    local s = start_line and math.max(1, start_line) or 1
    local e = end_line   and math.min(total, end_line) or total
    local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
    local content = table.concat(lines, "\n")
    return {
      content    = content,
      num_lines  = #lines,
      total_lines= total,
      source     = "buffer",
    }
  end

  -- Fall back to disk read
  local abs = vim.fn.fnamemodify(path, ":p")
  local f   = io.open(abs, "r")
  if not f then
    return { error = "file not found: " .. path }
  end
  local raw = f:read("*a")
  f:close()

  if not raw then
    return { error = "could not read file: " .. path }
  end

  if start_line or end_line then
    local all = vim.split(raw, "\n", { plain = true })
    local total = #all
    local s = start_line and math.max(1, start_line) or 1
    local e = end_line   and math.min(total, end_line) or total
    local slice = {}
    for i = s, e do table.insert(slice, all[i]) end
    return {
      content    = table.concat(slice, "\n"),
      num_lines  = #slice,
      total_lines= total,
      source     = "disk",
    }
  end

  local lines = vim.split(raw, "\n", { plain = true })
  return {
    content    = raw,
    num_lines  = #lines,
    total_lines= #lines,
    source     = "disk",
  }
end

return M
