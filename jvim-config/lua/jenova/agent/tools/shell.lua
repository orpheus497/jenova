-- jenova/agent/tools/shell.lua
-- jvim-native Shell tool. Runs POSIX sh commands via vim.system so the editor
-- event loop stays responsive and the agent can be cancelled mid-run.
--
-- Why vim.system + coroutine:
--   • The agent engine runs inside a coroutine. We spawn the process with a
--     callback, register the handle on jenova.agent._active_job (so /stop can
--     kill it), then yield until the callback resumes us with the result.
--   • Outside a coroutine (e.g. ad-hoc :lua require(...).call({...}) for
--     debugging) we fall back to a blocking :wait().
--
-- Native plugin / utility access:
--   • Endpoint env vars (JENOVA_API_URL, ports, …) are injected so commands
--     can talk back to the local backend.
--   • Restricted-path guard mirrors the read/write tools.
--   • Output is capped so a noisy command can't blow up the chat buffer.

local paths    = require("jenova.agent.utils.paths")

local DEFAULT_TIMEOUT_MS = 120000   -- 2 minutes
local MAX_TIMEOUT_MS     = 600000   -- 10 minutes
local MAX_OUTPUT_BYTES   = 64 * 1024  -- 64 KiB per stream

local M = {
  name        = "Shell",
  description = "Execute a POSIX sh command and return stdout+stderr. Use for build, test, git, package install, or any workspace task that has no dedicated tool. Always provide a brief 'description'. Long-running commands can be cancelled from the editor.",
  parameters  = {
    type = "object",
    properties = {
      command     = { type = "string",  description = "POSIX sh command. No bashisms ([[ ]], arrays, process substitution)." },
      description = { type = "string",  description = "One-line description of the intent (shown in chat)." },
      cwd         = { type = "string",  description = "Working directory (default: workspace cwd)." },
      timeout     = { type = "integer", description = "Timeout in ms (default 120000, max 600000)." },
    },
    required = { "command" },
  },
}

function M.is_enabled() return true end

-- Anything with shell metacharacters is treated as write-capable so that a
-- chained `ls; rm -rf` cannot sneak through the read-only fast-path.
local READ_ONLY_PREFIXES = {
  "ls", "cat", "head", "tail", "grep", "find", "which", "echo",
  "pwd", "whoami", "date", "uname", "env", "printenv", "wc",
  "file", "stat", "du", "df",
  "git status", "git log", "git diff", "git branch", "git show",
  "git remote", "git tag",
  "python --version", "python3 --version", "node --version",
  "npm --version", "cargo --version", "rustc --version", "go version",
}

function M.is_read_only(input)
  if not input or type(input.command) ~= "string" then return false end
  local cmd = input.command:lower()
  if cmd:find("[;&|`$><]") or cmd:find("%$%(") or cmd:find("\n") then
    return false
  end
  for _, prefix in ipairs(READ_ONLY_PREFIXES) do
    if cmd == prefix or cmd:sub(1, #prefix + 1) == prefix .. " " then
      return true
    end
  end
  return false
end

function M.user_facing_name(input)
  if input and type(input.description) == "string" and #input.description > 0 then
    local short = input.description:sub(1, 60)
    if #input.description > 60 then short = short .. "…" end
    return "Shell: " .. short
  end
  if input and type(input.command) == "string" then
    local short = input.command:sub(1, 60)
    if #input.command > 60 then short = short .. "…" end
    return "Shell: " .. short
  end
  return "Shell"
end

-- Whitespace-tokenise the command line. Argument-aware so legitimate
-- arguments (filenames, paths) that *contain* substrings like "/" or
-- "--no-preserve-root" don't trigger false positives — only standalone
-- tokens count as the dangerous flag/path.
local function tokenize(command)
  local out = {}
  for tok in command:gmatch("%S+") do table.insert(out, tok) end
  return out
end

local function expand_home(tok)
  if tok == "~" or tok == "~/" then return vim.fn.expand("~") end
  if tok:sub(1, 2) == "~/" then return vim.fn.expand("~") .. tok:sub(2) end
  if tok == "$HOME" then return vim.fn.expand("$HOME") end
  return tok
end

local DANGEROUS_RM_TARGETS = {
  ["/"] = true, ["/*"] = true,
  ["/bin"] = true, ["/etc"] = true, ["/usr"] = true, ["/var"] = true,
  ["/lib"] = true, ["/sbin"] = true, ["/boot"] = true, ["/root"] = true,
  ["/home"] = true, ["/Users"] = true,
}

local function is_destructive_rm(tokens)
  if tokens[1] ~= "rm" then return false end
  local has_recursive = false
  local force = false
  local no_preserve_root = false
  local has_root_arg = false

  for i = 2, #tokens do
    local tok = tokens[i]
    if tok == "--no-preserve-root" then
      no_preserve_root = true
    elseif tok:sub(1, 2) == "--" then
      -- long option, ignore
    elseif tok:sub(1, 1) == "-" then
      -- bundled short flags: check each char
      for c in tok:sub(2):gmatch(".") do
        if c == "r" or c == "R" then has_recursive = true end
        if c == "f" then force = true end
      end
    else
      local resolved = expand_home(tok)
      local home = vim.fn.expand("~"):gsub("/+$", "")
      if DANGEROUS_RM_TARGETS[tok] or DANGEROUS_RM_TARGETS[resolved]
         or resolved == home or resolved == home .. "/" then
        has_root_arg = true
      end
    end
  end
  -- A destructive rm needs both -r/-R and a dangerous target. -f alone is
  -- fine; --no-preserve-root with / is unconditional refusal.
  if no_preserve_root then return true end
  return has_recursive and has_root_arg and force
end

local function is_fork_bomb(command)
  -- Classic shell fork bomb. Whitespace insensitive between the parts.
  local stripped = command:gsub("%s+", "")
  return stripped:find(":(){:|:&};:", 1, true) ~= nil
end

function M.check_permissions(input, _ctx)
  -- The registry's interactive prompt gates write commands. Block obviously
  -- catastrophic patterns regardless so even an "allow all" session can't
  -- nuke /, the home dir, or the workspace by accident.
  if not input or type(input.command) ~= "string" then
    return { allowed = false, reason = "command is required" }
  end
  local cmd = input.command
  local tokens = tokenize(cmd)

  if is_destructive_rm(tokens) then
    return { allowed = false, reason = "refusing rm -rf on a system / home root path" }
  end
  if is_fork_bomb(cmd) then
    return { allowed = false, reason = "refusing fork bomb pattern" }
  end

  return { allowed = true }
end

local function build_env(_ctx)
  local env = {}
  -- Endpoint discovery is optional — the tool still works without the
  -- backend daemons, just without the JENOVA_* vars.
  local ok_ep, ep = pcall(require, "jenova.endpoints")
  if ok_ep and ep then
    local function getter(fn) local ok, v = pcall(fn); return ok and v or nil end
    local host       = getter(ep.host)
    local proxy_url  = getter(ep.proxy_url)
    local proxy_port = getter(ep.proxy_port)
    local llama_port = getter(ep.llama_port)
    local embed_port = getter(ep.embed_port)
    if host       then env.JENOVA_CONNECT_HOST   = tostring(host)       end
    if proxy_url  then env.JENOVA_API_URL        = tostring(proxy_url)  end
    if proxy_port then env.JENOVA_PORT           = tostring(proxy_port) end
    if llama_port then env.JENOVA_LLAMA_PORT     = tostring(llama_port) end
    if embed_port then env.JENOVA_LLAMA_EMBED_PORT = tostring(embed_port) end
  end
  env.JENOVA_TOOL = "Shell"
  return env
end

local function clamp_output(s)
  if not s or s == "" then return "" end
  if #s <= MAX_OUTPUT_BYTES then return s end
  local kept = s:sub(1, MAX_OUTPUT_BYTES)
  return kept .. string.format(
    "\n…[output truncated: %d bytes total, showing first %d]",
    #s, MAX_OUTPUT_BYTES)
end

local function format_result(result, command, duration_ms, timed_out)
  local out  = clamp_output(result.stdout or "")
  local err  = clamp_output(result.stderr or "")
  local code = result.code or 0

  local body
  if out ~= "" and err ~= "" then
    body = out .. "\n[stderr]\n" .. err
  elseif out ~= "" then
    body = out
  elseif err ~= "" then
    body = err
  else
    body = "(no output)"
  end

  if timed_out then
    body = body .. string.format("\n[Process timed out after %d ms]", duration_ms)
  end

  return {
    type        = timed_out and "error" or (code == 0 and "text" or "error"),
    text        = body,
    error       = (code ~= 0 and not timed_out) and string.format(
      "Command exited %d. Output:\n%s", code, body) or nil,
    exit_code   = code,
    duration_ms = duration_ms,
    timed_out   = timed_out or false,
    command     = command,
  }
end

function M.call(args, context)
  local command = args and args.command
  if type(command) ~= "string" or command == "" then
    return { type = "error", error = "command is required" }
  end

  local timeout = tonumber(args.timeout) or DEFAULT_TIMEOUT_MS
  if timeout <= 0 then timeout = DEFAULT_TIMEOUT_MS end
  if timeout > MAX_TIMEOUT_MS then timeout = MAX_TIMEOUT_MS end

  local cwd = args.cwd
  if cwd and #cwd > 0 then
    cwd = paths.resolve(cwd, context and context.cwd)
    if paths.is_restricted(cwd) then return paths.restricted_error(cwd) end
    if vim.fn.isdirectory(cwd) == 0 then
      return { type = "error", error = "cwd is not a directory: " .. cwd }
    end
  else
    cwd = (context and context.cwd) or vim.fn.getcwd()
  end

  local env = build_env(context)
  local cmd = { "sh", "-c", command }
  local opts = {
    text    = true,
    cwd     = cwd,
    env     = env,
    timeout = timeout,
  }

  local started = (vim.uv or vim.loop).hrtime()
  local function elapsed_ms()
    return math.floor(((vim.uv or vim.loop).hrtime() - started) / 1e6)
  end

  -- Register the handle on the agent so /stop can kill it.
  local agent = package.loaded["jenova.agent"]
  local co = coroutine.running()

  if co then
    local handle
    handle = vim.system(cmd, opts, function(result)
      vim.schedule(function()
        if agent and agent._active_job == handle then
          agent._active_job = nil
        end
        -- vim.system signals a timeout via signal == 15 + non-zero code on
        -- some platforms; check both the explicit timeout flag (0.10+) and
        -- the elapsed time vs. requested timeout.
        local timed_out = result.signal == 15 and elapsed_ms() >= timeout - 50
        coroutine.resume(co, format_result(result, command, elapsed_ms(), timed_out))
      end)
    end)
    if agent then agent._active_job = handle end
    return coroutine.yield()
  end

  -- Synchronous fallback (debugging only — blocks the editor).
  local handle = vim.system(cmd, opts)
  if agent then agent._active_job = handle end
  local result = handle:wait(timeout + 1000)
  if agent and agent._active_job == handle then agent._active_job = nil end
  local timed_out = result.signal == 15 and elapsed_ms() >= timeout - 50
  return format_result(result, command, elapsed_ms(), timed_out)
end

return M
