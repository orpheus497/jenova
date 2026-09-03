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

-- POSIX-aware shell-word splitter. Handles single-quoted strings (literal,
-- no escapes), double-quoted strings (with backslash escaping for ", \, $,
-- `, and newline), and backslash escapes outside quotes. This is what the
-- safety check needs so that legitimate arguments like `"--no-preserve-root
-- is fine"` or `'rm -rf /'` (a literal filename or echo argument) don't
-- get falsely flagged, AND so that `rm\ -rf` (escaped space) IS recognised
-- as a single token that doesn't form the destructive `rm` invocation.
local function shell_split(s)
  local out, cur = {}, {}
  local i, n = 1, #s
  local in_single, in_double = false, false

  local function flush()
    if #cur > 0 then
      table.insert(out, table.concat(cur))
      cur = {}
    end
  end

  while i <= n do
    local c = s:sub(i, i)
    if in_single then
      if c == "'" then in_single = false
      else cur[#cur + 1] = c end
    elseif in_double then
      if c == "\\" and i < n then
        local nxt = s:sub(i + 1, i + 1)
        if nxt == '"' or nxt == "\\" or nxt == "$" or nxt == "`" or nxt == "\n" then
          cur[#cur + 1] = nxt
          i = i + 1
        else
          cur[#cur + 1] = c
        end
      elseif c == '"' then
        in_double = false
      else
        cur[#cur + 1] = c
      end
    else
      if c == "'" then
        in_single = true
      elseif c == '"' then
        in_double = true
      elseif c == "\\" and i < n then
        cur[#cur + 1] = s:sub(i + 1, i + 1)
        i = i + 1
      elseif c:match("%s") then
        flush()
      else
        cur[#cur + 1] = c
      end
    end
    i = i + 1
  end
  flush()
  return out
end

-- Split a shell command on statement separators (`;`, `&&`, `||`, `|`, `&`,
-- newline) while respecting quoting, so the destructive-rm check can be
-- applied to every individual statement. This catches injection patterns
-- like `echo ok; rm -rf /` or commands containing literal newlines that the
-- previous single-statement check would have missed.
local function split_statements(s)
  local out, cur = {}, {}
  local i, n = 1, #s
  local in_single, in_double = false, false

  local function flush()
    local stmt = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
    if #stmt > 0 then table.insert(out, stmt) end
    cur = {}
  end

  while i <= n do
    local c = s:sub(i, i)
    if in_single then
      cur[#cur + 1] = c
      if c == "'" then in_single = false end
    elseif in_double then
      cur[#cur + 1] = c
      if c == "\\" and i < n then
        cur[#cur + 1] = s:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_double = false
      end
    else
      if c == "'" then
        in_single = true; cur[#cur + 1] = c
      elseif c == '"' then
        in_double = true; cur[#cur + 1] = c
      elseif c == "\\" and i < n then
        cur[#cur + 1] = c; cur[#cur + 1] = s:sub(i + 1, i + 1); i = i + 1
      elseif c == ";" or c == "\n" then
        flush()
      elseif c == "&" and s:sub(i + 1, i + 1) == "&" then
        flush(); i = i + 1
      elseif c == "|" and s:sub(i + 1, i + 1) == "|" then
        flush(); i = i + 1
      elseif c == "|" or c == "&" then
        flush()
      else
        cur[#cur + 1] = c
      end
    end
    i = i + 1
  end
  flush()
  return out
end

local function expand_home(tok)
  if tok == "~" or tok == "~/" then return vim.fn.expand("~") end
  if tok:sub(1, 2) == "~/" then return vim.fn.expand("~") .. tok:sub(2) end
  if tok == "$HOME" then return vim.fn.expand("$HOME") end
  return tok
end

-- Paths whose recursive deletion is essentially unrecoverable. Stored
-- canonically (no trailing slash). is_destructive_rm normalises tokens
-- (strips trailing slashes, expands ~) before the lookup so variants like
-- `/etc/`, `/etc//`, `~/`, and `$HOME/` all map to the canonical key.
local DANGEROUS_RM_TARGETS = {
  ["/"]          = true,  ["/*"]         = true,
  ["/bin"]       = true,  ["/sbin"]      = true,
  ["/usr"]       = true,  ["/usr/bin"]   = true,
  ["/usr/sbin"]  = true,  ["/usr/lib"]   = true,
  ["/usr/local"] = true,
  ["/etc"]       = true,
  ["/lib"]       = true,  ["/lib64"]     = true,
  ["/var"]       = true,  ["/var/log"]   = true,
  ["/boot"]      = true,
  ["/root"]      = true,
  ["/home"]      = true,  ["/Users"]     = true,
  ["/dev"]       = true,  ["/proc"]      = true,
  ["/sys"]       = true,  ["/tmp"]       = true,
  ["/run"]       = true,
  ["/opt"]       = true,  ["/srv"]       = true,
  ["/private"]   = true,  ["/private/etc"] = true,  -- macOS
}

-- Long flags that mean "recursive" / "force" — checked alongside the
-- bundled short forms (-r, -R, -f). Anything not listed here is ignored
-- (we only care about flags that modify rm's destructive behaviour).
local RECURSIVE_LONG_FLAGS = {
  ["--recursive"]      = true,
  ["--recursive=true"] = true,
  ["-r"] = true,
  ["-R"] = true,
}

local function strip_trailing_slashes(s)
  if not s or s == "" or s == "/" then return s end
  local out = s:gsub("/+$", "")
  if out == "" then out = "/" end
  return out
end

local function canonical_path_token(tok)
  return strip_trailing_slashes(expand_home(tok))
end

local function is_destructive_rm(tokens)
  if tokens[1] ~= "rm" then return false end
  local has_recursive    = false
  local no_preserve_root = false
  local has_root_arg     = false

  for i = 2, #tokens do
    local tok = tokens[i]
    if tok == "--no-preserve-root" then
      no_preserve_root = true
    elseif RECURSIVE_LONG_FLAGS[tok] then
      has_recursive = true
    elseif tok:sub(1, 2) == "--" then
      -- other long option (--force, --interactive, --verbose, …): ignored.
      -- We deliberately do NOT require --force / -f to block destructive
      -- recursive deletion of a system path; `rm -r /etc` is just as
      -- catastrophic as `rm -rf /etc`.
    elseif tok:sub(1, 1) == "-" and #tok > 1 then
      -- bundled short flags: check each char
      for c in tok:sub(2):gmatch(".") do
        if c == "r" or c == "R" then has_recursive = true end
      end
    else
      -- Positional argument: normalise (expand ~, strip trailing slashes)
      -- so /etc, /etc/, /etc//, $HOME, ~/ all map to their canonical form
      -- before the dangerous-target lookup.
      local canon = canonical_path_token(tok)
      local home  = strip_trailing_slashes(vim.fn.expand("~"))
      if DANGEROUS_RM_TARGETS[canon] or canon == home then
        has_root_arg = true
      end
    end
  end

  -- --no-preserve-root with anything is unconditional refusal: that flag
  -- only exists to override the GNU coreutils safety net for `rm -rf /`.
  if no_preserve_root then return true end
  -- Otherwise: recursive + dangerous target = block. We don't require
  -- -f / --force because GNU rm without -f still deletes a writable tree
  -- and only stops to prompt on read-only files; against /etc that prompt
  -- would still wipe most of the system before tripping.
  return has_recursive and has_root_arg
end

-- Best-effort fork-bomb detection. The primary safeguard is the registry's
-- interactive permission prompt: every Shell call hits "Allow / Deny" before
-- it runs. This pattern check is defense-in-depth for the obvious classic
-- bash fork-bomb shape; it is NOT exhaustive and makes no claim to catch
-- perl/python/while-loop variants. We keep it because the canonical
-- :(){ :|: & };: pattern is famous enough that catching it cheaply is
-- worth the extra ten lines.
local FORK_BOMB_PATTERNS = {
  -- Whitespace-insensitive ":(){ :|:& };:"  (the canonical bash form).
  -- `[^}]+` lets the body contain any non-} bytes so variants with extra
  -- whitespace, comments, or extra commands inside the function still hit.
  "^:%(%)%s*{[^}]*:%s*|%s*:[^}]*&[^}]*}%s*;%s*:",
  ":%(%)%s*{[^}]*:%s*|%s*:[^}]*&[^}]*}%s*;%s*:",
}

local function is_fork_bomb(command)
  -- Test both with original whitespace and with all whitespace stripped,
  -- since the canonical form is often pasted as ":(){:|:&};:" with no
  -- spaces at all.
  local stripped = command:gsub("%s+", "")
  for _, pat in ipairs(FORK_BOMB_PATTERNS) do
    if command:find(pat) then return true end
    if stripped:find(pat) then return true end
  end
  return false
end

function M.check_permissions(input, _ctx)
  -- The registry's interactive prompt gates write commands. Block obviously
  -- catastrophic patterns regardless so even an "allow all" session can't
  -- nuke /, the home dir, or the workspace by accident.
  if not input or type(input.command) ~= "string" then
    return { allowed = false, reason = "command is required" }
  end
  local cmd = input.command

  if is_fork_bomb(cmd) then
    return { allowed = false, reason = "refusing fork bomb pattern" }
  end

  -- Apply the destructive-rm check to every individual statement so injection
  -- patterns like `echo ok; rm -rf /` or `echo a$'\n'rm -rf /` cannot bypass
  -- the safety net by hiding behind a benign first statement. Quoting is
  -- respected so a literal "rm -rf /" inside `echo` is correctly treated as
  -- a single argument, not a destructive command.
  for _, stmt in ipairs(split_statements(cmd)) do
    local tokens = shell_split(stmt)
    if is_destructive_rm(tokens) then
      return { allowed = false,
        reason = "refusing rm -rf on a system / home root path (statement: "
          .. stmt:sub(1, 80) .. ")" }
    end
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
