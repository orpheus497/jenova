-- jenova/agent/tools/buffer_read.lua
-- jvim-native override for the shared "Read" tool.
--
-- Critical: the parameter schema MUST match shared/tools/file_read.lua
-- (`file_path`, `offset`, `limit`) because the JSON schema sent to the model
-- is built from whichever tool is registered last under the name "Read",
-- and the model will only ever send the parameters it sees in the schema.
-- The previous version of this file accepted `path`/`start_line`/`end_line`
-- which broke every model-driven Read call ("path is required").
--
-- Output shape also mirrors file_read so QueryEngine's read-dedupe cache
-- works (`text`, `num_lines`, `truncated`, `truncation_hint`).
--
-- When the file is open in a jvim buffer the live buffer content is
-- returned (no stale-file risk). Otherwise we fall back to a disk read.

local paths = require("utils.paths")

local M = {
  name        = "Read",
  description = "Read the contents of a file. " ..
    "When the file is open in a jvim buffer the live buffer content is returned " ..
    "(unsaved edits included). Otherwise the file is read from disk. " ..
    "Returns line-numbered output. Supports offset (lines to skip, 0-based) and limit (default 2000).",
  parameters  = {
    type = "object",
    properties = {
      file_path = { type = "string",  description = "Absolute or workspace-relative path to read" },
      offset    = { type = "integer", description = "Number of lines to skip from the start (0-based)" },
      limit     = { type = "integer", description = "Maximum lines to return (default 2000)" },
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

local function find_buf_by_path(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs_path then return b end
    end
  end
  return nil
end

local function format_lines(lines, offset, limit)
  -- Mirror file_read.lua line numbering: "%d\t%s", 1-based starting after offset.
  local out = {}
  local start_line = (offset or 0) + 1
  local cap = limit or 2000
  local total = #lines
  local truncated = false
  for i, l in ipairs(lines) do
    if i >= start_line then
      if #out < cap then
        table.insert(out, string.format("%d\t%s", i, l))
      else
        truncated = true
        break
      end
    end
  end
  return table.concat(out, "\n"), total, truncated
end

function M.call(args, context)
  -- Backward-compat: accept legacy `path`/`start_line`/`end_line` from
  -- callers that pre-date the schema fix, but the canonical parameters
  -- are file_path/offset/limit.
  local raw_path = args.file_path or args.path
  if not raw_path or raw_path == "" then
    return { type = "error", error = "No file path provided (expected file_path)" }
  end

  local offset = args.offset
  if not offset and args.start_line then
    offset = math.max(0, args.start_line - 1)
  end
  local limit = args.limit
  if not limit and args.end_line then
    limit = math.max(1, args.end_line - (offset or 0))
  end

  local resolved = paths.resolve(raw_path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")

  -- Try live buffer first
  local buf = find_buf_by_path(abs)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text, total, truncated = format_lines(lines, offset, limit)
    local hint
    if truncated then
      local next_off = (offset or 0) + (limit or 2000)
      hint = string.format(
        "[BUFFER TRUNCATED: showing lines %d-%d of %d total. Call Read('%s', offset=%d) to continue.]",
        (offset or 0) + 1, next_off, total, abs, next_off)
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

  -- Fall back to disk read
  local f, err = io.open(abs, "r")
  if not f then
    return {
      type  = "error",
      error = string.format(
        "Cannot open file: %s — %s. Use Glob to discover available files.",
        abs, err or "not found"),
    }
  end

  local lines = {}
  for line in f:lines() do table.insert(lines, line) end
  f:close()

  local text, total, truncated = format_lines(lines, offset, limit)
  local hint
  if truncated then
    local next_off = (offset or 0) + (limit or 2000)
    hint = string.format(
      "[FILE TRUNCATED: showing lines %d-%d of %d total. Call Read('%s', offset=%d) to continue.]",
      (offset or 0) + 1, next_off, total, abs, next_off)
  end

  return {
    type            = "text",
    text            = text,
    num_lines       = total,
    truncated       = truncated,
    truncation_hint = hint,
    source          = "disk",
  }
end

return M
