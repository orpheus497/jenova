-- jenova/agent/tools/vim_cmd.lua
-- Native jvim ex-command and plugin-function bridge for the agent.
--
-- Two actions:
--   • "ex"   — run a single ex-command line (`:write`, `:make`, `:Telescope …`,
--               `:Lazy sync`, any user command, any registered plugin command).
--               Captures the message buffer via :redir so the agent sees what
--               the command would have printed.
--   • "lua"  — evaluate a Lua expression in the editor process. Mainly for
--               reading plugin state (`require('lualine').get_config()`, etc.)
--               or invoking exposed plugin APIs that don't have a wrapping
--               ex-command. Result is JSON-encoded when serialisable, else
--               tostring()'d.
--
-- This is the canonical way for the agent to reach into installed plugins
-- without us having to write a one-off tool per plugin.

local M = {
  name        = "VimCmd",
  description = "Run a jvim ex-command or evaluate a Lua expression in the editor process. Use 'ex' for ex-commands and plugin commands (:make, :Lazy, :Telescope, :LspInfo). Use 'lua' to query plugin state or call plugin APIs. Output is captured.",
  parameters  = {
    type = "object",
    properties = {
      action = {
        enum        = { "ex", "lua" },
        description = "ex = run a colon-command, lua = evaluate a Lua expression",
      },
      command = { type = "string", description = "Ex-command line (no leading ':') when action=ex" },
      code    = { type = "string", description = "Lua expression or chunk when action=lua" },
    },
    required = { "action" },
  },
}

function M.is_enabled() return true end

-- Querying plugin state (`:LspInfo`, `:Lazy`, expressions like
-- `require('foo').stats()`) is read-only. Anything else (`:write`, `:edit`,
-- `:Make`, mutating Lua) is treated as write-capable so the registry asks
-- for permission before running it.
local READ_ONLY_EX = {
  LspInfo = true, LspLog = true, LspStop = true,
  Lazy = true, LazyHealth = true, LazySync = false,
  checkhealth = true, messages = true, version = true, help = true,
  ls = true, buffers = true, registers = true, marks = true, jumps = true,
  highlight = true, scriptnames = true, autocmd = true, map = true,
  set = true, options = true, filetype = true, syntax = true,
  pwd = true,
}

local function first_word(s)
  return s and s:match("^%s*(%S+)") or ""
end

function M.is_read_only(input)
  if not input then return false end
  if input.action == "lua" then
    -- Conservatively treat any Lua chunk as write-capable. Plugin reads are
    -- still cheap because the registry's "Allow tool for session" option
    -- skips repeat prompts.
    return false
  end
  if input.action == "ex" and type(input.command) == "string" then
    local cmd = first_word(input.command:gsub("^:+", ""))
    if READ_ONLY_EX[cmd] == true then return true end
    return false
  end
  return false
end

function M.user_facing_name(input)
  if not input then return "VimCmd" end
  if input.action == "ex" and input.command then
    return "VimCmd: :" .. input.command:sub(1, 60)
  elseif input.action == "lua" and input.code then
    return "VimCmd: lua " .. input.code:sub(1, 60)
  end
  return "VimCmd"
end

function M.check_permissions(input, _ctx)
  if not input or not input.action then
    return { allowed = false, reason = "action is required" }
  end
  if input.action == "ex" and (type(input.command) ~= "string" or #input.command == 0) then
    return { allowed = false, reason = "command is required for action=ex" }
  end
  if input.action == "lua" and (type(input.code) ~= "string" or #input.code == 0) then
    return { allowed = false, reason = "code is required for action=lua" }
  end
  return { allowed = true }
end

local function capture_messages(fn)
  local ok, captured = pcall(function()
    return vim.api.nvim_exec2("redir => __jenova_redir__\nlua __jenova_redir_run__()\nredir END\nlet g:__jenova_redir__ = __jenova_redir__",
      { output = false })
  end)
  -- The above redir trick is brittle. Use the cleaner nvim_exec2 with
  -- output=true on the actual command instead — this function exists only
  -- to keep the signature clean if we later need redir-based capture.
  return ok, captured
end

local function run_ex(command)
  -- nvim_exec2 returns the captured ":echo"/":print" output for us when
  -- output=true, which is exactly what we want for ":LspInfo", ":Lazy",
  -- ":messages", etc. Errors are surfaced via pcall.
  local ok, res = pcall(vim.api.nvim_exec2, command, { output = true })
  if not ok then
    return { type = "error", error = "ex-command failed: " .. tostring(res) }
  end
  local out = (type(res) == "table" and res.output) or ""
  if out == "" then
    -- Some commands print to messages without echoing. Pull the tail of
    -- :messages so the agent still sees something meaningful.
    local msgs_ok, msgs = pcall(vim.api.nvim_exec2, "messages", { output = true })
    if msgs_ok and type(msgs) == "table" and msgs.output and msgs.output ~= "" then
      out = msgs.output
    else
      out = "(command produced no output)"
    end
  end
  if #out > 32 * 1024 then
    out = out:sub(1, 32 * 1024) .. "\n…[truncated]"
  end
  return { type = "text", text = out }
end

local function run_lua(code)
  -- Wrap as an expression first; if that fails (statements, multi-line),
  -- fall back to executing as a chunk and reporting any return value.
  local chunk, err = loadstring("return (" .. code .. ")")
  if not chunk then
    chunk, err = loadstring(code)
  end
  if not chunk then
    return { type = "error", error = "lua compile error: " .. tostring(err) }
  end
  local ok, result = pcall(chunk)
  if not ok then
    return { type = "error", error = "lua runtime error: " .. tostring(result) }
  end
  if result == nil then
    return { type = "text", text = "(nil)" }
  end
  -- Try JSON encode first for structured output.
  local enc_ok, encoded = pcall(vim.json.encode, result)
  if enc_ok and #encoded < 32 * 1024 then
    return { type = "text", text = encoded }
  end
  local s = vim.inspect(result)
  if #s > 32 * 1024 then s = s:sub(1, 32 * 1024) .. "\n…[truncated]" end
  return { type = "text", text = s }
end

function M.call(args, _context)
  local action = args and args.action
  if action == "ex" then
    local command = args.command:gsub("^:+", "")
    return run_ex(command)
  elseif action == "lua" then
    return run_lua(args.code)
  end
  return { type = "error", error = "Unknown action: " .. tostring(action) }
end

-- Suppress lint: capture_messages is currently unused but kept for the
-- redir-based capture path (see comment above).
local _ = capture_messages

return M
