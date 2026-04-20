-- state/app_state.lua — Global application state
-- Equivalent to src/state/AppState.tsx

local AppState = {}

-- Seed the RNG once at module load so session IDs don't collide
math.randomseed(os.time() + math.floor(os.clock() * 1000))

-- Global state instance
local state = {
    -- Session
    session_id = nil,
    session_dir = nil,
    working_directory = nil,

    -- UI state
    current_screen = "repl", -- "repl", "doctor", "resume", "plan"
    vim_mode = false,
    compact_mode = false,
    show_thinking = false,

    -- Query state
    is_querying = false,
    abort_controller = nil,
    current_turn = 0,
    max_turns = 25,

    -- Messages
    messages = {},
    pending_tool_uses = {},

    -- Cost tracking
    total_input_tokens = 0,
    total_output_tokens = 0,
    total_cost_usd = 0,

    -- Permissions
    permission_mode = "default",
    pending_permissions = {},

    -- History
    history = {},
    history_index = 0,

    -- MCP servers
    mcp_connections = {},

    -- Plugins
    loaded_plugins = {},

    -- Skills
    loaded_skills = {},

    -- File state cache
    file_state_cache = {},

    -- Memory
    memory_items = {},
}

-- ── Session Management ────────────────────────────────────────────────

function AppState.init_session(session_id)
    state.session_id = session_id or AppState.generate_session_id()
    state.session_dir = AppState.get_session_dir(state.session_id)

    -- Create session directory using safe fs module
    local ok, fs = pcall(require, "utils.fs_fallback")
    if ok then
        fs.mkdir(state.session_dir)
    end

    return state.session_id
end

function AppState.generate_session_id()
    -- Simple session ID generation
    return os.date("%Y%m%d-%H%M%S") .. "-" .. math.random(1000, 9999)
end

function AppState.get_session_dir(session_id)
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/.cache/cli-agent/sessions/" .. session_id
end

-- ── Session Persistence ───────────────────────────────────────────────
-- Sessions are serialized to <session_dir>/state.json so /resume can
-- rehydrate messages, history, usage totals, and working directory.

local function _session_file(session_id)
    return AppState.get_session_dir(session_id) .. "/state.json"
end

-- Snapshot of state that's safe to serialize (omit live handles like
-- abort_controller and connection objects).
local function _snapshot()
    return {
        session_id = state.session_id,
        working_directory = state.working_directory,
        messages = state.messages,
        history = state.history,
        total_input_tokens = state.total_input_tokens,
        total_output_tokens = state.total_output_tokens,
        total_cost_usd = state.total_cost_usd,
        permission_mode = state.permission_mode,
        memory_items = state.memory_items,
        saved_at = os.time(),
    }
end

function AppState.save_session(session_id)
    session_id = session_id or state.session_id
    if not session_id then return nil, "No active session" end

    local json = require("utils.json_fallback")
    local ok_dump, content = pcall(json.stringify, _snapshot())
    if not ok_dump then
        return nil, "Failed to serialize session: " .. tostring(content)
    end

    local dir = AppState.get_session_dir(session_id)
    local ok_fs, fs = pcall(require, "utils.fs_fallback")
    if ok_fs and fs and fs.mkdir then fs.mkdir(dir) end

    local path = _session_file(session_id)
    local f, ferr = io.open(path, "w")
    if not f then return nil, "Failed to open session file: " .. tostring(ferr) end
    f:write(content)
    f:close()
    return path
end

function AppState.load_session(session_id)
    if not session_id then return nil, "session_id required" end

    local path = _session_file(session_id)
    local f = io.open(path, "r")
    if not f then return nil, "No saved state for session " .. session_id end
    local content = f:read("*a")
    f:close()

    local json = require("utils.json_fallback")
    local ok, data = pcall(json.parse, content)
    if not ok or type(data) ~= "table" then
        return nil, "Failed to parse session state"
    end

    state.session_id = data.session_id or session_id
    state.session_dir = AppState.get_session_dir(state.session_id)
    state.working_directory = data.working_directory or state.working_directory
    state.messages = data.messages or {}
    state.history = data.history or {}
    state.history_index = #state.history
    state.total_input_tokens = data.total_input_tokens or 0
    state.total_output_tokens = data.total_output_tokens or 0
    state.total_cost_usd = data.total_cost_usd or 0
    state.permission_mode = data.permission_mode or state.permission_mode
    state.memory_items = data.memory_items or {}
    return state.session_id
end

-- A "session id" is a single directory entry under the sessions root.
-- Anything containing a path separator, "." / "..", or trailing/leading
-- whitespace is rejected so a malicious or stale entry can't traverse out
-- of the sessions root or shadow another file. We also bound the length
-- to keep the join below sane.
local function _is_safe_session_name(name)
    if type(name) ~= "string" or #name == 0 or #name > 255 then return false end
    if name == "." or name == ".." then return false end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return false end
    if name:find("%z") then return false end -- embedded NUL
    return true
end

function AppState.list_sessions()
    local home = os.getenv("HOME")
    if not home then return {} end
    local root = home .. "/.cache/cli-agent/sessions"

    local results = {}
    local seen = {}

    local function _add_if_session(name)
        if not _is_safe_session_name(name) then return end
        if seen[name] then return end
        seen[name] = true
        local path = root .. "/" .. name .. "/state.json"
        local f = io.open(path, "r")
        if f then
            f:close()
            table.insert(results, { session_id = name, path = path })
        end
    end

    local ok, fs = pcall(require, "utils.fs_fallback")
    local list_fn = ok and fs and (fs.list_dir or fs.listdir)
    if list_fn then
        local entries = list_fn(root) or {}
        for _, name in ipairs(entries) do
            _add_if_session(name)
        end
    else
        -- Fallback: scan via the FFI process bridge so we get a real
        -- argv path (no shell quoting concerns) and so the same code
        -- works on Windows. Falls through to io.popen on builds without
        -- the FFI.
        local listed = false
        if jenova and jenova.process and jenova.process.spawn then
            local json = require("utils.json_fallback")
            local cmd, argv = "ls", { "-1", root }
            local config = json.stringify({
                cmd = cmd,
                args = argv,
                timeout_ms = 10000,
                capture_stdout = true,
                capture_stderr = false,
            })
            local res = jenova.process.spawn_json(config)
            if res and type(res) == "table" then
                local pok, parsed = true, res
                if pok and parsed and parsed.exit_code == 0 then
                    for name in (parsed.stdout or ""):gmatch("[^\r\n]+") do
                        _add_if_session(name)
                    end
                    listed = true
                end
            end
        end
        if not listed then
            local shell = require("utils.shell")
            local cmd = "ls -1 " .. shell.quote(root) .. " 2>/dev/null"
            local handle = io.popen(cmd)
            if handle then
                for name in handle:lines() do
                    _add_if_session(name)
                end
                handle:close()
            end
        end
    end

    table.sort(results, function(a, b) return a.session_id > b.session_id end)
    return results
end

-- ── State Getters ─────────────────────────────────────────────────────

function AppState.get(key)
    if key then
        return state[key]
    else
        return state
    end
end

function AppState.set(key, value)
    state[key] = value
end

function AppState.update(updates)
    for k, v in pairs(updates) do
        state[k] = v
    end
end

-- ── Message Management ────────────────────────────────────────────────

function AppState.add_message(message)
    table.insert(state.messages, message)
end

function AppState.get_messages()
    return state.messages
end

function AppState.clear_messages()
    state.messages = {}
end

-- ── History Management ────────────────────────────────────────────────

function AppState.add_history_item(item)
    table.insert(state.history, item)
    state.history_index = #state.history

    -- Limit history size
    local max_size = 1000
    if #state.history > max_size then
        table.remove(state.history, 1)
        state.history_index = state.history_index - 1
    end
end

function AppState.get_history_item(index)
    return state.history[index]
end

function AppState.navigate_history(direction)
    if direction == "up" then
        if state.history_index > 1 then
            state.history_index = state.history_index - 1
        end
    elseif direction == "down" then
        if state.history_index < #state.history then
            state.history_index = state.history_index + 1
        end
    end
    return state.history[state.history_index]
end

-- ── Cost Tracking ─────────────────────────────────────────────────────

function AppState.update_usage(input_tokens, output_tokens, cost_usd)
    state.total_input_tokens = state.total_input_tokens + (input_tokens or 0)
    state.total_output_tokens = state.total_output_tokens + (output_tokens or 0)
    state.total_cost_usd = state.total_cost_usd + (cost_usd or 0)
end

function AppState.get_usage()
    return {
        input_tokens = state.total_input_tokens,
        output_tokens = state.total_output_tokens,
        total_cost_usd = state.total_cost_usd
    }
end

function AppState.reset_usage()
    state.total_input_tokens = 0
    state.total_output_tokens = 0
    state.total_cost_usd = 0
end

-- ── Permissions ───────────────────────────────────────────────────────

function AppState.set_permission_mode(mode)
    state.permission_mode = mode
end

function AppState.get_permission_mode()
    return state.permission_mode
end

function AppState.add_pending_permission(tool_name, input)
    table.insert(state.pending_permissions, {
        tool_name = tool_name,
        input = input,
        timestamp = os.time()
    })
end

function AppState.clear_pending_permissions()
    state.pending_permissions = {}
end

-- ── Working Directory ─────────────────────────────────────────────────

function AppState.set_cwd(dir)
    state.working_directory = dir
end

function AppState.get_cwd()
    return state.working_directory or os.getenv("PWD") or os.getenv("CD") or "."
end

return AppState
