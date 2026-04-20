-- services/memory/manager.lua — Session-aware memory with TTL, action tracking, and plan tracking
-- Ported from jenova/lib/memory.lua for the Jenova CLI "trio" integration.

-- jenova.json is a validator (string→validated string via FFI) and cannot
-- encode/decode Lua tables. Route every json.parse/json.stringify call in
-- this module through the pure-Lua codec so entries written to disk
-- (errors/actions/learned/prefs/manual_memory) actually serialize.
local json_codec = require("utils.json_fallback")
local json = json_codec
local app_state = require("state.app_state")
local config = require("config.loader")

local Memory = {}

-- Files and paths
local JENOVA_DIR = nil
local ERROR_FILE = nil
local LEARN_FILE = nil
local ACTION_FILE = nil
local PREFS_FILE = nil
local NOTES_FILE = nil

-- TTL constants (seconds)
local ERROR_TTL = 3600        -- errors expire after 1 hour
local LEARN_TTL = 86400 * 7   -- learned patterns expire after 7 days
local ACTION_TTL = 1800       -- action history expires after 30 minutes
local MAX_ERRORS = 50         -- max error entries on disk
local MAX_LEARNED = 100       -- max learned entries on disk
local MAX_ACTIONS = 200       -- max action entries on disk
local MAX_SESSION_ERRORS = 100  -- cap in-memory session error list
local MAX_INDEX_KEYS = 400    -- cap in-memory action index map

-- Session state (in-memory)
local session_id = nil
local session_start = 0
local session_actions = {}
local session_plan = {}
local session_errors = {}
local session_action_index = {}
local session_action_key_order = {}

-- ── Initialization ────────────────────────────────────────────────────

function Memory.init()
    local memory_dir = Memory.get_memory_dir()
    JENOVA_DIR = memory_dir
    
    -- Ensure directory exists
    local shell = require("utils.shell")
    local ok_fs, fs = pcall(require, "utils.fs_fallback")
    if ok_fs and fs and fs.mkdir then
        fs.mkdir(JENOVA_DIR)
        fs.mkdir(JENOVA_DIR .. "/backups")
    else
        os.execute("mkdir -p " .. shell.quote(JENOVA_DIR))
        os.execute("mkdir -p " .. shell.quote(JENOVA_DIR .. "/backups"))
    end

    ERROR_FILE = JENOVA_DIR .. "/errors.jsonl"
    LEARN_FILE = JENOVA_DIR .. "/learned.jsonl"
    ACTION_FILE = JENOVA_DIR .. "/actions.jsonl"
    PREFS_FILE = JENOVA_DIR .. "/preferences.json"
    NOTES_FILE = JENOVA_DIR .. "/notes.md"

    session_id = app_state.get("session_id") or (string.format("%x", os.time()) .. string.format("%04x", math.random(0, 0xFFFF)))
    session_start = os.time()
    
    Memory.clear_session()
    Memory.gc()
end

function Memory.get_memory_dir()
    local memory_dir = config.get("memory_dir")
    if not memory_dir then
        local config_dir = config.get_config_dir()
        if config_dir then
            memory_dir = config_dir .. "/memory"
        else
            local home = os.getenv("HOME")
            memory_dir = home .. "/.local/share/cli-agent/memory"
        end
    end
    return memory_dir
end

-- ── Garbage Collection ────────────────────────────────────────────────

function Memory.gc()
    local now = os.time()

    local function prune_file(filepath, ttl, max_entries)
        local f = io.open(filepath, "r")
        if not f then return end
        local lines = {}
        for line in f:lines() do
            -- Fast path: extract the top-level "ts" key without full JSON parsing.
            -- Require '{' or ',' before the key so we never match an escaped
            -- \"ts\" that appears inside a JSON string value.
            local ts_str = line:match('[{,]%s*"ts"%s*:%s*(%d+)')
            if ts_str then
                local ts = tonumber(ts_str)
                if ts and (now - ts) < ttl then
                    lines[#lines + 1] = line
                end
            else
                -- Fallback for unexpectedly formatted lines
                local ok, entry = pcall(json.parse, line)
                if ok and entry and entry.ts then
                    if (now - entry.ts) < ttl then
                        lines[#lines + 1] = line
                    end
                end
            end
        end
        f:close()

        if #lines > max_entries then
            local trimmed = {}
            for i = #lines - max_entries + 1, #lines do
                trimmed[#trimmed + 1] = lines[i]
            end
            lines = trimmed
        end

        local wf = io.open(filepath, "w")
        if wf then
            for _, line in ipairs(lines) do
                wf:write(line .. "\n")
            end
            wf:close()
        end
    end

    prune_file(ERROR_FILE, ERROR_TTL, MAX_ERRORS)
    prune_file(LEARN_FILE, LEARN_TTL, MAX_LEARNED)
    prune_file(ACTION_FILE, ACTION_TTL, MAX_ACTIONS)
end

-- ── Error Tracking ────────────────────────────────────────────────────

function Memory.log_error(tool_name, args_summary, error_msg)
    local entry = {
        ts = os.time(),
        sid = session_id,
        tool = tool_name,
        args = args_summary,
        error = error_msg,
    }

    -- Persistent
    local f = io.open(ERROR_FILE, "a")
    if f then
        f:write(json.stringify(entry) .. "\n")
        f:close()
    end

    -- Session-local
    table.insert(session_errors, entry)
    if #session_errors > MAX_SESSION_ERRORS then
        table.remove(session_errors, 1)
    end
end

function Memory.format_errors_for_prompt(n)
    if #session_errors == 0 then return "" end
    n = n or 3

    local seen = {}
    local unique = {}
    -- Walk backwards (newest first)
    for i = #session_errors, 1, -1 do
        if #unique >= n then break end
        local e = session_errors[i]
        local key = (e.tool or "") .. ":" .. ((e.error or ""):sub(1, 40))
        if not seen[key] then
            seen[key] = true
            unique[#unique + 1] = e
        end
    end

    if #unique == 0 then return "" end

    local parts = { "\nErrors THIS session (do NOT repeat these):" }
    for _, e in ipairs(unique) do
        parts[#parts + 1] = string.format(
            "- %s(%s): %s",
            e.tool or "?", (e.args or ""):sub(1, 40), (e.error or ""):sub(1, 80)
        )
    end
    return table.concat(parts, "\n")
end

-- ── Action Tracking ───────────────────────────────────────────────────

local function action_key(tool_name, args)
    local key_parts = { tool_name }
    if type(args) == "table" then
        if args.command then key_parts[#key_parts + 1] = args.command:sub(1, 80) end
        if args.path then key_parts[#key_parts + 1] = args.path end
        if args.query then key_parts[#key_parts + 1] = args.query end
        if args.old then key_parts[#key_parts + 1] = "old:" .. args.old:sub(1, 40) end
    elseif type(args) == "string" then
        key_parts[#key_parts + 1] = args:sub(1, 80)
    end
    return table.concat(key_parts, "|")
end

function Memory.record_action(tool_name, args, result, success)
    local key = action_key(tool_name, args)
    local entry = {
        ts = os.time(),
        sid = session_id,
        tool = tool_name,
        key = key:sub(1, 200),
        success = success,
        result_summary = tostring(result or ""):sub(1, 100),
    }

    local idx = session_action_index[key]
    if not idx then
        idx = { count = 0, last_result = "", successes = 0, failures = 0 }
        session_action_index[key] = idx
        table.insert(session_action_key_order, key)
        if #session_action_key_order > MAX_INDEX_KEYS then
            local evict_key = table.remove(session_action_key_order, 1)
            session_action_index[evict_key] = nil
        end
    end
    idx.count = idx.count + 1
    idx.last_result = tostring(result or ""):sub(1, 200)
    if success then idx.successes = idx.successes + 1 else idx.failures = idx.failures + 1 end

    table.insert(session_actions, entry)
    if #session_actions > 200 then table.remove(session_actions, 1) end

    local f = io.open(ACTION_FILE, "a")
    if f then
        f:write(json.stringify(entry) .. "\n")
        f:close()
    end
end

function Memory.format_action_history(max_entries)
    max_entries = max_entries or 8
    if #session_actions == 0 then return "" end

    local parts = { "\nActions tried this session (avoid repeating failures):" }
    local start = math.max(1, #session_actions - max_entries + 1)

    local seen_index = {}
    local unique = {}
    for i = start, #session_actions do
        local a = session_actions[i]
        if not seen_index[a.key] then
            table.insert(unique, a)
            seen_index[a.key] = #unique
        else
            unique[seen_index[a.key]] = a
        end
    end

    for _, a in ipairs(unique) do
        local status = a.success and "OK" or "FAILED"
        parts[#parts + 1] = string.format("- [%s] %s: %s", status, a.tool, a.result_summary:sub(1, 60))
    end

    return table.concat(parts, "\n")
end

-- ── Plan Tracking ─────────────────────────────────────────────────────

function Memory.set_plan(steps)
    session_plan = {}
    for i, step in ipairs(steps) do
        session_plan[i] = { step = step, status = "pending", detail = "" }
    end
end

function Memory.update_plan_step(index, status, detail)
    if session_plan[index] then
        session_plan[index].status = status
        session_plan[index].detail = detail or ""
    end
end

function Memory.format_plan()
    if #session_plan == 0 then return "" end
    local parts = { "\nCurrent plan:" }
    for i, step in ipairs(session_plan) do
        local icon = "[ ]"
        if step.status == "done" then icon = "[x]"
        elseif step.status == "active" then icon = "[>]"
        elseif step.status == "failed" then icon = "[!]"
        end
        local line = string.format("%s %d. %s", icon, i, step.step)
        if step.detail ~= "" then
            line = line .. " — " .. step.detail:sub(1, 50)
        end
        parts[#parts + 1] = line
    end
    return table.concat(parts, "\n")
end

-- ── Learned Patterns ──────────────────────────────────────────────────

function Memory.learn_from_turn(user_query, total_actions, success)
    local entry = {
        ts = os.time(),
        sid = session_id,
        query_type = Memory.categorize_query(user_query),
        query_summary = user_query:sub(1, 80),
        actions = total_actions,
        success = success,
    }
    local f = io.open(LEARN_FILE, "a")
    if f then
        f:write(json.stringify(entry) .. "\n")
        f:close()
    end
end

function Memory.categorize_query(query)
    local q = query:lower()
    if q:match("fix") or q:match("error") or q:match("bug") then return "fix" end
    if q:match("create") or q:match("write") or q:match("new") then return "create" end
    if q:match("update") or q:match("change") or q:match("modify") then return "modify" end
    if q:match("build") or q:match("compile") or q:match("make") then return "build" end
    if q:match("test") or q:match("check") or q:match("verify") then return "test" end
    return "general"
end

function Memory.get_learned_patterns(query_type)
    local f = io.open(LEARN_FILE, "r")
    if not f then return "" end

    local now = os.time()
    local count = 0
    local total_actions = 0

    for line in f:lines() do
        local ts_str = line:match('[,{]%s*"ts"%s*:%s*(%d+)')
        local ts = tonumber(ts_str)
        if ts and (now - ts) < LEARN_TTL then
            local success_str = line:match('[,{]%s*"success"%s*:%s*([a-z]+)')
            if success_str == "true" then
                local qt = line:match('[,{]%s*"query_type"%s*:%s*"([^"]+)"')
                if not query_type or qt == query_type then
                    local actions_str = line:match('[,{]%s*"actions"%s*:%s*(%d+)')
                    local actions = actions_str and tonumber(actions_str) or 0
                    count = count + 1
                    total_actions = total_actions + actions
                end
            end
        end
    end
    f:close()

    if count < 3 then return "" end
    local avg = math.floor(total_actions / count + 0.5)
    return string.format("\nSimilar %s tasks: %d completed before, avg %d actions.", query_type or "general", count, avg)
end

-- ── User Preferences ─────────────────────────────────────────────────

local prefs_cache = nil

local function load_prefs()
    if prefs_cache then return prefs_cache end
    if not PREFS_FILE then prefs_cache = {}; return prefs_cache end
    local f = io.open(PREFS_FILE, "r")
    if not f then prefs_cache = {}; return prefs_cache end
    local content = f:read("*a")
    f:close()
    local data = json_codec.parse(content)
    prefs_cache = (type(data) == "table") and data or {}
    return prefs_cache
end

function Memory.set_preference(key, value)
    local prefs = load_prefs()
    prefs[key] = value
    prefs_cache = prefs
    if not PREFS_FILE then return end
    local f = io.open(PREFS_FILE, "w")
    if f then f:write(json_codec.stringify(prefs)); f:close() end
end

function Memory.get_preference(key, default)
    local prefs = load_prefs()
    local v = prefs[key]
    if v == nil then return default end
    return v
end

function Memory.get_preferences()
    local prefs = load_prefs()
    if not next(prefs) then return "" end
    local parts = {}
    for k, v in pairs(prefs) do
        local val_str = type(v) == "table" and json_codec.stringify(v) or tostring(v)
        parts[#parts + 1] = string.format("- %s: %s", tostring(k), val_str)
    end
    table.sort(parts)
    return table.concat(parts, "\n")
end

-- ── Session Management ────────────────────────────────────────────────

function Memory.clear_session()
    session_actions = {}
    session_plan = {}
    session_errors = {}
    session_action_index = {}
    session_action_key_order = {}
end

-- ── Build Context ─────────────────────────────────────────────────────

function Memory.build_context(current_query)
    local parts = {}
    local query_type = current_query and Memory.categorize_query(current_query) or nil

    local errs = Memory.format_errors_for_prompt(3)
    if errs ~= "" then table.insert(parts, errs) end

    local acts = Memory.format_action_history(6)
    if acts ~= "" then table.insert(parts, acts) end

    local plan = Memory.format_plan()
    if plan ~= "" then table.insert(parts, plan) end

    local learned = Memory.get_learned_patterns(query_type)
    if learned ~= "" then table.insert(parts, learned) end

    local prefs = Memory.get_preferences()
    if prefs ~= "" then table.insert(parts, "\nUser preferences:\n" .. prefs) end

    return table.concat(parts, "\n")
end

-- Compatibility with old API
function Memory.add(subject, fact, citations, reason)
    -- Map old 'add' to learning or preferences if needed
    -- For now, just log it as a structured log
    local entry = { ts = os.time(), type = "manual", subject = subject, fact = fact, citations = citations }
    local f = io.open(JENOVA_DIR .. "/manual_memory.jsonl", "a")
    if f then f:write(json.stringify(entry) .. "\n"); f:close() end
end

function Memory.get_recent(count) return {} end
function Memory.search(query) return {} end
function Memory.clear() Memory.clear_session() end

return Memory
