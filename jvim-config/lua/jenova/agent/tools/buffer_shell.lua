-- jenova/agent/tools/buffer_shell.lua
-- jvim-native Shell tool. Runs commands via vim.system so the event loop stays free.

local paths = require("jenova.agent.utils.paths")

local M = {
  name        = "Shell",
  description = "Run a shell command. Use this for builds and tests — NOT for linting/diagnostics (use LSP for that). Output is capped at 10 KB.",
  parameters  = {
    type = "object",
    properties = {
      command     = { type = "string", description = "Shell command to execute" },
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

function M.check_permissions() return { allowed = true } end

function M.call(args, context)
  local command = args.command
  if not command then return { type = "error", error = "command is required" } end

  local timeout = args.timeout or 30000
  local cwd = (context and context.cwd) or vim.fn.getcwd()

  -- Resolve relative cwd references in the command context only — not the command itself.
  if paths.is_restricted(cwd) then return paths.restricted_error(cwd) end

  local co = coroutine.running()
  local result = nil

  if co then
    vim.system({ "sh", "-c", command }, { text = true, timeout = timeout, cwd = cwd }, function(res)
      result = res
      vim.schedule(function() coroutine.resume(co) end)
    end)
    coroutine.yield()
  else
    result = vim.system({ "sh", "-c", command }, { text = true, timeout = timeout, cwd = cwd }):wait()
  end

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""

  local function cap(s, limit)
    if #s <= limit then return s end
    return s:sub(1, math.floor(limit / 2)) .. "\n...[truncated]...\n" .. s:sub(-math.floor(limit / 2))
  end

  local out = string.format("Exit: %d\n", result.code)
  out = out .. "Stdout:\n" .. cap(stdout, 10000)
  if stderr ~= "" then
    out = out .. "\nStderr:\n" .. cap(stderr, 5000)
  end
  if result.signal and result.signal ~= 0 then
    out = out .. string.format("\nKilled by signal %d", result.signal)
  end

  return { type = "text", text = out }
end

return M
