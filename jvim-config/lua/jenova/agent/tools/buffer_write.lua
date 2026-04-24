-- jenova/agent/tools/buffer_write.lua
-- jvim-native Write tool.
-- Unified buffer-first logic for creating or overwriting files.

local paths = require("utils.paths")

local M = {
  name        = "Write",
  description = "Write content to a file. Uses jvim buffers to ensure real-time updates and proper formatting.",
  parameters  = {
    type = "object",
    properties = {
      file_path = { type = "string", description = "Target file path" },
      content   = { type = "string", description = "Content to write" },
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

function M.call(args, context)
  local path = args.file_path
  local content = args.content
  if not path then return { type = "error", error = "No file path provided" } end
  if not content then return { type = "error", error = "No content provided" } end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")

  -- Ensure directory exists
  vim.fn.mkdir(dir, "p")
  
  -- Unified buffer logic: add/load the buffer (works for new or existing files)
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)

  local lines = vim.split(content, "\n", { plain = true })
  
  -- Replace entire buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = true

  -- Save the buffer
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent! write! " .. vim.fn.fnameescape(abs))
  end)

  if ok then
    return { type = "text", text = "File written successfully: " .. abs }
  else
    return { type = "error", error = "Failed to write file: " .. tostring(err) }
  end
end

return M
