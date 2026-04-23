-- jenova/agent/tools/buffer_shell.lua
-- jvim-native override for the shared "Shell" tool.
-- Uses vim.system to run shell commands asynchronously, preventing event loop blocking.

local paths = require("utils.paths")

local M = {
  name        = "Shell",
  description = "Run a shell command. DO NOT use this for linting, compiling to check for errors, or checking code issues. Use the LSP tool for that. Use this for testing or querying system state. Output is truncated if too long.",
  parameters  = {
    type = "object",
    properties = {
      command     = { type = "string", description = "The shell command to execute" },
      description = { type = "string", description = "Brief description of what the command does" },
      timeout     = { type = "integer", description = "Timeout in milliseconds (default 30000)" },
    },
    required = { "command" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
  return input and input.command and ("Shell: " .. input.command) or "Shell"
end

function M.check_permissions(input, ctx)
  local ok_mgr, manager = pcall(require, "permissions.manager")
  if not ok_mgr or not manager or not manager.can_use_tool then
    return { allowed = true }
  end
  local allowed, reason = manager.can_use_tool("Shell", input, ctx or {})
  return { allowed = allowed, reason = reason }
end

function M.call(args, context)
  local command = args.command
  if not command then return { type = "error", error = "command is required" } end
  
  local timeout = args.timeout or 30000
  local cwd = context and context.cwd or vim.fn.getcwd()

  local result = vim.system({"sh", "-c", command}, { text = true, timeout = timeout, cwd = cwd }):wait()
  
  local stdout = result.stdout or ""
  local stderr = result.stderr or ""
  
  if #stdout > 10000 then
    stdout = stdout:sub(1, 5000) .. "\n...\n[truncated]\n...\n" .. stdout:sub(-5000)
  end
  
  local output = "Exit Code: " .. tostring(result.code) .. "\n"
  output = output .. "Stdout:\n" .. stdout
  
  if stderr ~= "" then
    if #stderr > 10000 then
      stderr = stderr:sub(1, 5000) .. "\n...\n[truncated]\n...\n" .. stderr:sub(-5000)
    end
    output = output .. "\nStderr:\n" .. stderr
  end

  if result.signal and result.signal ~= 0 then
    output = output .. "\nTerminated by signal: " .. tostring(result.signal)
  end

  return { type = "text", text = output }
end

return M
