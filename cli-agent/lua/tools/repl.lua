-- tools/repl.lua — REPL Tool: Execute code in a persistent interactive session
--
-- Session persistence strategy:
--   * Lua: each session_id gets its own sandbox environment table stored in
--     `lua_sessions`. Subsequent calls reuse the same env, so variables and
--     function definitions survive across calls.
--   * Python / Node: jenova.process.spawn is fire-and-wait, so we can't
--     keep a long-lived interpreter pinned to the Lua VM. Instead each call
--     re-runs the session's accumulated history followed by the new
--     snippet, but we make this honest about its costs:
--       1. We inject a sentinel `print` between the history and the new
--          snippet and slice the captured output at that sentinel — only
--          the new code's output is returned to the agent. This stops the
--          cumulative-growth context blow-up that affected the previous
--          implementation.
--       2. History is capped at MAX_HISTORY_ENTRIES / MAX_HISTORY_BYTES.
--          Older entries are dropped (oldest first). This bounds the
--          replay time so it doesn't grow without limit.
--       3. The cost trade-off (history is replayed, so any side-effecting
--          statements run again) is documented for the agent in the tool
--          description so it knows to keep history to definitions /
--          imports / assignments where possible.
--   * When no session_id is provided, the call is stateless (historic
--     behavior).

local M = {}
M.name = "REPL"
M.description = "Execute code in a persistent interactive REPL session (Python, Node, Lua)."

M.parameters = {
    type = "object",
    properties = {
        language = { type = "string", description = "Language: 'python', 'node', 'lua'" },
        code = { type = "string", description = "Code to execute" },
        session_id = {
            type = "string",
            description = "Session ID for persistent state (optional). For Lua, the sandbox env is reused directly so state is truly persistent. For Python and Node the interpreter is fire-and-wait, so the session's previous snippets are RE-EXECUTED before each new snippet. Keep history to definitions / imports / pure assignments — side-effecting statements (network calls, prints, mutations) will run again every time. Output from previous snippets is filtered out so only the new snippet's output is returned.",
        },
        reset = { type = "boolean", description = "If true, clear the session state before running this code." },
    },
    required = { "language", "code" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "REPL" end

function M.check_permissions()
    return { allowed = true }
end

-- Module-level session tables. These live for the duration of the Lua VM.
local lua_sessions = {}     -- [session_id] = { env = {}, created_at = ts }
local script_sessions = {}  -- [session_id] = { language = ..., history = {code1, code2}, created_at = ts }

-- Cap how much history we replay so cost stays bounded for long-running
-- agent sessions. Hitting either limit drops oldest entries first.
local MAX_HISTORY_ENTRIES = 32
local MAX_HISTORY_BYTES   = 16 * 1024

-- Sentinel printed between the replayed history and the new snippet, used
-- to slice the captured output so only the new snippet's output is
-- returned to the agent. Picked to be vanishingly unlikely in real code.
local OUTPUT_SENTINEL = "__JENOVA_REPL_OUTPUT_MARK_8f3a__"

-- Per-language interpreter executable plus the snippet flag, kept as an
-- argv pair so we never have to shell-quote anything.
local INTERPRETERS = {
    python     = { "python3", "-c" },
    python3    = { "python3", "-c" },
    node       = { "node",    "-e" },
    javascript = { "node",    "-e" },
    lua        = { "lua",     "-e" },
}

-- Per-language one-liner that prints OUTPUT_SENTINEL on its own line.
-- Injected between the history replay and the new snippet.
local SENTINEL_STMT = {
    python     = "import sys; sys.stdout.write('" .. OUTPUT_SENTINEL .. "\\n'); sys.stdout.flush()",
    python3    = "import sys; sys.stdout.write('" .. OUTPUT_SENTINEL .. "\\n'); sys.stdout.flush()",
    node       = "process.stdout.write('" .. OUTPUT_SENTINEL .. "\\n');",
    javascript = "process.stdout.write('" .. OUTPUT_SENTINEL .. "\\n');",
}

-- Trim the captured output so it only contains everything *after* the
-- sentinel. If the sentinel is missing (history failed to print it, e.g.
-- a syntax error in earlier code) we return the raw output so the user
-- can debug.
local function _strip_replayed_output(output)
    if not output or #output == 0 then return output end
    local idx = output:find(OUTPUT_SENTINEL, 1, true)
    if not idx then return output end
    -- Skip the sentinel and any trailing CR / LF characters. On Windows
    -- the sentinel line will end in `\r\n`, so a plain `\n` check would
    -- leave a stray `\r` at the start of the new output.
    local after = output:sub(idx + #OUTPUT_SENTINEL)
    if after:sub(1, 2) == "\r\n" then
        after = after:sub(3)
    elseif after:sub(1, 1) == "\n" then
        after = after:sub(2)
    end
    return after
end

-- Drop oldest history entries until both the entry-count and byte-size
-- limits are satisfied.
local function _trim_history(sess)
    local total_bytes = 0
    for _, snippet in ipairs(sess.history) do total_bytes = total_bytes + #snippet end
    while #sess.history > MAX_HISTORY_ENTRIES or total_bytes > MAX_HISTORY_BYTES do
        if #sess.history == 0 then break end
        total_bytes = total_bytes - #sess.history[1]
        table.remove(sess.history, 1)
    end
end

function M.call(args, ctx)
    local lang = (args.language or "python"):lower()
    local code = args.code
    local session_id = args.session_id

    if not code or #code == 0 then
        return { type = "error", error = "No code provided" }
    end

    local interpreter = INTERPRETERS[lang]
    if not interpreter then
        return { type = "error", error = "Unsupported language: " .. lang .. ". Supported: python, node, lua" }
    end

    -- Handle explicit reset
    if args.reset and session_id then
        lua_sessions[session_id] = nil
        script_sessions[session_id] = nil
    end

    -- For Lua, we can execute directly in the current VM with a persistent env
    if lang == "lua" then
        return M._exec_lua(code, session_id)
    end

    -- Python / Node: build effective code as
    --     <bounded history>
    --     <sentinel print>
    --     <new snippet>
    -- and slice the output at the sentinel so we only return the new
    -- snippet's stdout/stderr to the agent. This caps the output context
    -- regardless of how long the session has been running.
    local effective_code = code
    local replayed_history = false
    if session_id then
        local sess = script_sessions[session_id]
        if sess and sess.language ~= lang then
            return { type = "error", error = string.format(
                "Session '%s' is a %s session, cannot run %s code in it",
                session_id, sess.language, lang) }
        end
        if not sess then
            sess = { language = lang, history = {}, created_at = os.time() }
            script_sessions[session_id] = sess
        end
        _trim_history(sess)
        if #sess.history > 0 then
            local sentinel_stmt = SENTINEL_STMT[lang] or ""
            effective_code = table.concat(sess.history, "\n") .. "\n" .. sentinel_stmt .. "\n" .. code
            replayed_history = true
        end
    end

    local output, exit_code = M._run_interpreter(interpreter, effective_code)
    if replayed_history then
        output = _strip_replayed_output(output)
    end

    -- On success, append this snippet to the session history so subsequent
    -- calls see its definitions / variables. We keep history on failure too
    -- (some errors leave partial state behind); the user can pass
    -- reset=true to clear. Trim afterwards so size limits stay enforced.
    if session_id and script_sessions[session_id] then
        local sess = script_sessions[session_id]
        table.insert(sess.history, code)
        _trim_history(sess)
    end

    if exit_code and exit_code ~= 0 then
        return { type = "text", text = string.format("Exit code %d:\n%s", exit_code, output or "") }
    end
    return { type = "text", text = output or "" }
end

-- Create a read-only shallow copy of a table so sandbox code cannot mutate
-- the host's libraries or contaminate other REPL sessions. Uses a proxy
-- pattern: the returned table is empty so every access goes through
-- metamethods — reads resolve via __index, writes are rejected by __newindex.
local function _shallow_copy(t)
    if type(t) ~= "table" then return t end
    local data = {}
    for k, v in pairs(t) do data[k] = v end
    return setmetatable({}, {
        __index = data,
        __newindex = function(_, k)
            error("attempt to modify a read-only sandbox library table: " .. tostring(k), 2)
        end,
        __metatable = false,
    })
end

local safe_env = {
    print = print, type = type, tostring = tostring, tonumber = tonumber,
    ipairs = ipairs, pairs = pairs, next = next, pcall = pcall, xpcall = xpcall,
    error = error, select = select, assert = assert,
    math = _shallow_copy(math),
    string = _shallow_copy(string),
    table = _shallow_copy(table),
    coroutine = _shallow_copy(coroutine),
    os = _shallow_copy({ time = os.time, date = os.date, difftime = os.difftime, clock = os.clock }),
}

-- Execute Lua code, optionally in a persistent sandbox keyed by session_id.
function M._exec_lua(code, session_id)
    local env
    if session_id then
        local sess = lua_sessions[session_id]
        if not sess then
            sess = { env = setmetatable({}, { __index = safe_env }), created_at = os.time() }
            lua_sessions[session_id] = sess
        end
        env = sess.env
    else
        env = setmetatable({}, { __index = safe_env })
    end

    local fn, err = load("return " .. code, "=repl", "t", env)
    if not fn then
        fn, err = load(code, "=repl", "t", env)
    end

    if not fn then
        return { type = "error", error = "Lua parse error: " .. tostring(err) }
    end

    -- Capture print output — override print in the sandbox env (not globally)
    -- so concurrent callers or the host VM are unaffected.
    local output = {}
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        table.insert(output, table.concat(parts, "\t"))
    end

    -- Capture *all* return values — not just the first. We pack pcall's
    -- results into a table with an explicit length so trailing nils are
    -- preserved, then tostring() each one for display.
    local results = table.pack(pcall(fn))
    local ok = results[1]

    if not ok then
        return { type = "error", error = "Lua runtime error: " .. tostring(results[2]) }
    end

    local text = table.concat(output, "\n")
    if results.n > 1 then
        local parts = {}
        for i = 2, results.n do
            parts[i - 1] = tostring(results[i])
        end
        local rendered = "=> " .. table.concat(parts, ", ")
        if #text > 0 then
            text = text .. "\n" .. rendered
        else
            text = rendered
        end
    end

    return { type = "text", text = text }
end

-- Run code through an external interpreter. `interpreter` is a {cmd, flag}
-- argv pair (e.g. {"python3", "-c"}). Returns (output, exit_code).
function M._run_interpreter(interpreter, code)
    local cmd = interpreter[1]
    local flag = interpreter[2]

    -- Prefer the FFI's cmd+args form so we don't have to shell-quote the
    -- snippet at all — the interpreter's `-c` / `-e` arg is passed as a
    -- single argv element, so embedded quotes, dollars, semicolons,
    -- newlines, and backslashes can never inject shell commands.
    if jenova and jenova.process and jenova.process.spawn then
        local json = require("utils.json_fallback")
        local config = json.stringify({
            command = cmd,
            args = { flag, code },
            timeout_ms = 30000,
            capture_stdout = true,
            capture_stderr = true,
        })
        local result_json = jenova.process.spawn(config)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                local output = (result.stdout or "") .. (result.stderr or "")
                return output, result.exit_code
            end
        end
    end

    -- Fallback: io.popen with platform-aware shell quoting. Only used on
    -- hosts that built without the FFI bridge.
    local shell = require("utils.shell")
    local quoted = shell.quote(cmd) .. " " .. shell.quote(flag) .. " " .. shell.quote(code) .. " 2>&1"
    local handle = io.popen(quoted)
    if not handle then
        return "Failed to start interpreter", -1
    end
    local output = handle:read("*a")
    -- io.popen:close() returns (ok, "exit", status) in Lua 5.4
    local _, _, status = handle:close()
    return output or "", status or 0
end

-- Expose session management for tests / inspection
function M._reset_session(session_id)
    lua_sessions[session_id] = nil
    script_sessions[session_id] = nil
end

function M._list_sessions()
    local sessions = {}
    for id, s in pairs(lua_sessions) do
        sessions[id] = { language = "lua", created_at = s.created_at }
    end
    for id, s in pairs(script_sessions) do
        sessions[id] = { language = s.language, created_at = s.created_at, history_len = #s.history }
    end
    return sessions
end

return M
