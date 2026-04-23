-- jenova/agent/tools/buffer_write.lua
-- jvim-native override for the shared "Write" tool.
-- Overwrites file and updates open buffers to show changes immediately.

local paths = require("utils.paths")

local M = {
  name        = "Write",
  description = "Write content to a file, creating it and parent directories if they don't exist. " ..
    "Overwrites existing files. When the file is open in jvim, the live buffer is updated in real-time.",
  parameters  = {
    type = "object",
    properties = {
      file_path = { type = "string", description = "Path to the file to write (absolute or relative to working directory)" },
      content   = { type = "string", description = "The content to write to the file" },
    },
    required = { "file_path", "content" }
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
  return input and input.file_path and ("Write: " .. input.file_path) or "Write"
end

function M.check_permissions(input, ctx)
  local ok_mgr, manager = pcall(require, "permissions.manager")
  if not ok_mgr or not manager or not manager.can_use_tool then
    return { allowed = true }
  end
  local allowed, reason = manager.can_use_tool("Write", input, ctx or {})
  return { allowed = allowed, reason = reason }
end

local function find_buf_by_path(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs_path then return b end
    end
  end
  return nil
end

function M.call(args, context)
  local path = args.file_path
  local content = args.content
  if not path then return { type = "error", error = "No file path provided" } end
  if not content then return { type = "error", error = "No content provided" } end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")

  vim.fn.mkdir(dir, "p")
  local lines = vim.split(content, "\n", { plain = true })
  
  -- If buffer is open, update it
  local buf = find_buf_by_path(abs)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
  end

  -- Also write to disk
  local ok = vim.fn.writefile(lines, abs)
  if ok == 0 then
    return { type = "text", text = "File written: " .. abs }
  else
    return { type = "error", error = "Failed to write file: " .. abs }
  end
end

return M
