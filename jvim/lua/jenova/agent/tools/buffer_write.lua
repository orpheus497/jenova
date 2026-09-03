-- jenova/agent/tools/buffer_write.lua
-- jvim-native Write tool. Creates or overwrites a file via the buffer API.

local paths = require("jenova.agent.utils.paths")

local M = {
  name        = "Write",
  description = "Write content to a file. The file is opened in a jvim buffer so changes appear immediately.",
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

function M.check_permissions() return { allowed = true } end

function M.call(args, context)
  local path    = args.file_path
  local content = args.content
  if not path    then return { type = "error", error = "file_path is required" } end
  if not content then return { type = "error", error = "content is required" } end

  local resolved = paths.resolve(path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")
  vim.fn.mkdir(dir, "p")

  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)

  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = true

  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent! write! " .. vim.fn.fnameescape(abs))
  end)

  if ok then
    return { type = "text", text = "Written: " .. abs }
  else
    return { type = "error", error = "Failed to write: " .. tostring(err) }
  end
end

return M
