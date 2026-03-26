-- memory.lua: Session-aware memory with TTL, garbage collection, and action tracking
-- Key design principles:
--   1. Session isolation: each startup = new session; old data ages out
--   2. Action history: tracks what was tried and whether it succeeded/failed
--   3. TTL-based GC: errors/learned data expire after configurable time
--   4. Compact prompt injection: only inject what's relevant to THIS task
--   5. Plan/checklist tracking: persistent plan state across turns

local _dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
if not package.path:find(_dir, 1, true) then
  package.path = _dir .. "?.lua;" .. package.path
end

local json = require("json")

local memory = {}

local JENOVA_DIR = os.getenv("JENOVA_STATE_DIR") or ".jenova"
local SESSION_LOG = JENOVA_DIR .. "/session.jsonl"
local ERROR_FILE = JENOVA_DIR .. "/errors.jsonl"
local LEARN_FILE = JENOVA_DIR .. "/learned.jsonl"
local PREFS_FILE = JENOVA_DIR .. "/preferences.json"
local NOTES_FILE = JENOVA_DIR .. "/notes.md"
local ACTION_FILE = JENOVA_DIR .. "/actions.jsonl"

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-------------------------------------------------------------------------------
-- TTL constants (seconds)
-------------------------------------------------------------------------------
local ERROR_TTL = 3600        -- errors expire after 1 hour
local LEARN_TTL = 86400 * 7   -- learned patterns expire after 7 days
local ACTION_TTL = 1800       -- action history expires after 30 minutes
local MAX_ERRORS = 50         -- max error entries on disk
local MAX_LEARNED = 100       -- max learned entries on disk
local MAX_ACTIONS = 200       -- max action entries on disk
local MAX_SESSION_ERRORS = 100  -- cap in-memory session error list
local MAX_INDEX_KEYS = 400    -- cap in-memory action index map

-------------------------------------------------------------------------------
-- Session state (in-memory, not persisted)
-------------------------------------------------------------------------------
local session_id = nil
local session_start = 0
local session_actions = {}     -- { {tool, args_key, result_key, ts, success} }
local session_plan = {}        -- { {step, status, detail} }  status: pending/done/failed
local session_errors = {}      -- errors from THIS session only
local session_action_index = {} -- "tool:args_hash" -> {count, last_result, success}
local session_action_key_order = {} -- insertion-order list for LRU eviction of session_action_index

-------------------------------------------------------------------------------
-- Ensure .jenova directory exists
-------------------------------------------------------------------------------
function memory.init()
  local rc_mkdir = os.execute("mkdir -p " .. shell_quote(JENOVA_DIR))
  if rc_mkdir ~= 0 then
    io.write(string.format("[memory] warning: mkdir failed for %s (exit status %s)\n", JENOVA_DIR, tostring(rc_mkdir)))
  end
  local rc_bk = os.execute("mkdir -p " .. shell_quote(JENOVA_DIR .. "/backups"))
  if rc_bk ~= 0 then
    io.write(string.format("[memory] warning: mkdir failed for %s (exit status %s)\n", JENOVA_DIR .. "/backups", tostring(rc_bk)))
  end
  -- prefer daemon helper for background tasks in future; dir creation keeps os.execute for portability

  session_id = string.format("%x", os.time()) .. string.format("%04x", math.random(0, 0xFFFF))
  session_start = os.time()
  session_actions = {}
  session_plan = {}
  session_errors = {}
  session_action_index = {}
  session_action_key_order = {}

  memory.gc()
end

-------------------------------------------------------------------------------
-- Garbage collection: prune expired entries from all persistent files
-------------------------------------------------------------------------------
function memory.gc()
  local now = os.time()

  local function prune_file(filepath, ttl, max_entries)
    local f = io.open(filepath, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do
      local ok, entry = pcall(json.decode, line)
      if ok and entry and entry.ts then
        if (now - entry.ts) < ttl then
          lines[#lines + 1] = line
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

  -- Trim session_action_index if session is old or index is large (H2 fix)
  local age = os.time() - session_start
  if age > 7200 or #session_action_key_order > 300 then
    if #session_action_key_order > 200 then
      local keep_from = #session_action_key_order - 200 + 1
      for i = 1, keep_from - 1 do
        session_action_index[session_action_key_order[i]] = nil
      end
      local new_order = {}
      for i = keep_from, #session_action_key_order do
        new_order[#new_order + 1] = session_action_key_order[i]
      end
      session_action_key_order = new_order
    end
  end

  -- Truncate session log if > 500KB
  local sf = io.open(SESSION_LOG, "r")
  if sf then
    local content = sf:read("*a")
    sf:close()
    if #content > 512000 then
      local lines = {}
      for line in content:gmatch("[^\n]+") do
        lines[#lines + 1] = line
      end
      local keep = math.min(200, #lines)
      local wf = io.open(SESSION_LOG, "w")
      if wf then
        for i = #lines - keep + 1, #lines do
          wf:write(lines[i] .. "\n")
        end
        wf:close()
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Append a structured entry to the session log (lightweight)
-------------------------------------------------------------------------------
function memory.log(entry_type, content)
  local entry = {
    ts = os.time(),
    sid = session_id,
    type = entry_type,
    data = content,
  }
  local f = io.open(SESSION_LOG, "a")
  if f then
    f:write(json.encode(entry) .. "\n")
    f:close()
  end
end

-------------------------------------------------------------------------------
-- Log an error with context — both persistent and session-local
-------------------------------------------------------------------------------
function memory.log_error(tool_name, args_summary, error_msg)
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
    f:write(json.encode(entry) .. "\n")
    f:close()
  end

  -- Session-local (for fast access); cap to avoid unbounded growth
  session_errors[#session_errors + 1] = entry
  if #session_errors > MAX_SESSION_ERRORS then
    local half = math.floor(MAX_SESSION_ERRORS / 2)
    local trimmed = {}
    for i = #session_errors - half + 1, #session_errors do
      trimmed[#trimmed + 1] = session_errors[i]
    end
    session_errors = trimmed
  end
end

-------------------------------------------------------------------------------
-- Action tracking: record every tool call with result classification
-- This is the core fix for "model repeats the same failed action"
-------------------------------------------------------------------------------
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

function memory.record_action(tool_name, args, result, success)
  local key = action_key(tool_name, args)
  local entry = {
    ts = os.time(),
    sid = session_id,
    tool = tool_name,
    key = key:sub(1, 200),
    success = success,
    result_summary = (result or ""):sub(1, 100),
  }

  -- In-memory index for fast lookup; evict oldest quarter when over limit
  local idx = session_action_index[key]
  if not idx then
    idx = { count = 0, last_result = "", successes = 0, failures = 0 }
    session_action_index[key] = idx
    session_action_key_order[#session_action_key_order + 1] = key
    if #session_action_key_order > MAX_INDEX_KEYS then
      local evict = math.floor(MAX_INDEX_KEYS / 4)
      for i = 1, evict do
        session_action_index[session_action_key_order[i]] = nil
      end
      local new_order = {}
      for i = evict + 1, #session_action_key_order do
        new_order[#new_order + 1] = session_action_key_order[i]
      end
      session_action_key_order = new_order
    end
  end
  idx.count = idx.count + 1
  idx.last_result = (result or ""):sub(1, 200)
  if success then
    idx.successes = idx.successes + 1
  else
    idx.failures = idx.failures + 1
  end

  -- Sequential history (capped to prevent unbounded growth)
  local MAX_SESSION_ACTIONS = 200
  if #session_actions >= MAX_SESSION_ACTIONS then
    local trimmed = {}
    for i = #session_actions - math.floor(MAX_SESSION_ACTIONS / 2) + 1, #session_actions do
      trimmed[#trimmed + 1] = session_actions[i]
    end
    session_actions = trimmed
  end
  session_actions[#session_actions + 1] = entry

  -- Persistent (for cross-session pattern detection)
  local f = io.open(ACTION_FILE, "a")
  if f then
    f:write(json.encode(entry) .. "\n")
    f:close()
  end
end

function memory.was_action_tried(tool_name, args)
  local key = action_key(tool_name, args)
  return session_action_index[key]
end

function memory.get_action_count(tool_name, args)
  local key = action_key(tool_name, args)
  local idx = session_action_index[key]
  return idx and idx.count or 0
end

-------------------------------------------------------------------------------
-- Format action history for the model — concise summary of what was tried
-- Only includes THIS session's actions relevant to the current turn
-- Optimized: O(n) deduplication using hash table instead of O(n²)
-------------------------------------------------------------------------------
function memory.format_action_history(max_entries)
  max_entries = max_entries or 8
  if #session_actions == 0 then return "" end

  local parts = { "\nActions tried this session (avoid repeating failures):" }
  local start = math.max(1, #session_actions - max_entries + 1)

  -- Deduplicate by key, keep last result - O(n) using hash table
  local seen_index = {}  -- key -> index in unique array
  local unique = {}
  for i = start, #session_actions do
    local a = session_actions[i]
    local existing_idx = seen_index[a.key]
    if not existing_idx then
      unique[#unique + 1] = a
      seen_index[a.key] = #unique
    else
      unique[existing_idx] = a
    end
  end

  for _, a in ipairs(unique) do
    local status = a.success and "OK" or "FAILED"
    parts[#parts + 1] = string.format("- [%s] %s: %s", status, a.tool, a.result_summary:sub(1, 60))
  end

  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- Plan/checklist: track multi-step task progress
-------------------------------------------------------------------------------
function memory.set_plan(steps)
  session_plan = {}
  for i, step in ipairs(steps) do
    session_plan[i] = { step = step, status = "pending", detail = "" }
  end
end

function memory.update_plan_step(index, status, detail)
  if session_plan[index] then
    session_plan[index].status = status
    session_plan[index].detail = detail or ""
  end
end

function memory.advance_plan()
  for i, step in ipairs(session_plan) do
    if step.status == "pending" then
      step.status = "active"
      return i, step.step
    end
  end
  return nil, nil
end

function memory.get_plan()
  return session_plan
end

function memory.format_plan()
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

-------------------------------------------------------------------------------
-- Get recent errors — session-local first, then persistent
-------------------------------------------------------------------------------
function memory.get_errors(n)
  n = n or 5

  -- Session errors are fast
  if #session_errors >= n then
    local result = {}
    for i = math.max(1, #session_errors - n + 1), #session_errors do
      result[#result + 1] = session_errors[i]
    end
    return result
  end

  -- Fall back to persistent
  local lines = {}
  local f = io.open(ERROR_FILE, "r")
  if not f then return session_errors end
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  local result = {}
  local start = math.max(1, #lines - n + 1)
  for i = start, #lines do
    local ok, entry = pcall(json.decode, lines[i])
    if ok then
      result[#result + 1] = entry
    end
  end
  return result
end

-------------------------------------------------------------------------------
-- Format errors for prompt — ONLY from this session, deduplicated
-- This prevents old stale errors from poisoning the context
-------------------------------------------------------------------------------
function memory.format_errors_for_prompt(n)
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

-------------------------------------------------------------------------------
-- Persistent learning: Record successful patterns (with TTL)
-------------------------------------------------------------------------------
function memory.learn_from_turn(user_query, total_actions, edit_fails)
  local fail_count = 0
  for _, c in pairs(edit_fails or {}) do
    fail_count = fail_count + c
  end

  if total_actions > 0 and fail_count <= 1 then
    local entry = {
      ts = os.time(),
      sid = session_id,
      query_type = memory.categorize_query(user_query),
      query_summary = user_query:sub(1, 80),
      actions = total_actions,
      edit_failures = fail_count,
      success = true,
    }
    local f = io.open(LEARN_FILE, "a")
    if f then
      f:write(json.encode(entry) .. "\n")
      f:close()
    end
  end
end

function memory.categorize_query(query)
  local q = query:lower()
  if q:match("fix") or q:match("error") or q:match("bug") or q:match("broken") then return "fix" end
  if q:match("create") or q:match("write") or q:match("new") or q:match("add") then return "create" end
  if q:match("update") or q:match("change") or q:match("modify") or q:match("edit") then return "modify" end
  if q:match("install") or q:match("setup") or q:match("configure") then return "setup" end
  if q:match("build") or q:match("compile") or q:match("make") then return "build" end
  if q:match("test") or q:match("check") or q:match("verify") then return "test" end
  if q:match("explain") or q:match("how") or q:match("what") or q:match("why") then return "explain" end
  if q:match("analyse") or q:match("analyze") or q:match("improve") then return "analyze" end
  return "general"
end

-------------------------------------------------------------------------------
-- Get learned patterns — compact summary, not raw data dump
-- Only inject if relevant to the current query type
-------------------------------------------------------------------------------
function memory.get_learned_patterns(n, current_query_type)
  n = n or 3
  local f = io.open(LEARN_FILE, "r")
  if not f then return "" end

  local now = os.time()
  local type_counts = {}
  local type_actions = {}
  local total_success = 0

  for line in f:lines() do
    local ok, entry = pcall(json.decode, line)
    if ok and entry.success and entry.ts and (now - entry.ts) < LEARN_TTL then
      total_success = total_success + 1
      local qt = entry.query_type or "general"
      type_counts[qt] = (type_counts[qt] or 0) + 1
      type_actions[qt] = (type_actions[qt] or 0) + (entry.actions or 0)
    end
  end
  f:close()

  if total_success < 3 then return "" end

  -- Only return info relevant to current query type
  local parts = {}
  if current_query_type and type_counts[current_query_type] then
    local count = type_counts[current_query_type]
    local avg = math.floor((type_actions[current_query_type] or 0) / count + 0.5)
    parts[#parts + 1] = string.format("\nSimilar %s tasks: %d completed before, avg %d actions.", current_query_type, count, avg)
  end

  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- User preferences: persistent key-value store
-------------------------------------------------------------------------------
local prefs_cache = nil

local function load_prefs()
  if prefs_cache then return prefs_cache end
  local f = io.open(PREFS_FILE, "r")
  if not f then prefs_cache = {}; return prefs_cache end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(json.decode, content)
  prefs_cache = (ok and type(data) == "table") and data or {}
  return prefs_cache
end

function memory.set_preference(key, value)
  local prefs = load_prefs()
  prefs[key] = value
  local f = io.open(PREFS_FILE, "w")
  if f then
    f:write(json.encode(prefs))
    f:close()
  end
  prefs_cache = prefs
end

function memory.get_preference(key, default)
  local prefs = load_prefs()
  local v = prefs[key]
  if v == nil then return default end
  return v
end

function memory.get_preferences()
  local prefs = load_prefs()
  if not next(prefs) then return "" end
  local parts = {}
  for k, v in pairs(prefs) do
    parts[#parts + 1] = string.format("- %s: %s", tostring(k), tostring(v))
  end
  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- Project tree (cached per session)
-------------------------------------------------------------------------------
local cached_tree = nil

function memory.get_project_tree(root, max_depth)
  if cached_tree then return cached_tree end
  root = root or "."
  max_depth = max_depth or 3
  local cmd = string.format(
    "find %s -maxdepth %d -type f -not -path '*/.git/*' -not -path '*/.jenova/*' -not -path '*/.crush/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/build/*' -not -path '*/backups/*' -not -path '*/llama.cpp/*' -not -name '*.gguf' -not -name '*.bin' -not -name '*.o' -not -name '*.so' 2>/dev/null | head -100 | sort",
    shell_quote(root), max_depth
  )
  local p = io.popen(cmd)
  if not p then cached_tree = ""; return cached_tree end
  local ok, output = pcall(p.read, p, "*a")
  p:close()
  if not ok then cached_tree = ""; return cached_tree end
  cached_tree = output or ""
  return cached_tree
end

function memory.invalidate_tree_cache()
  cached_tree = nil
end

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
function memory.get_notes()
  local f = io.open(NOTES_FILE, "r")
  if not f then return "" end
  local content = f:read("*a")
  f:close()
  return content
end

function memory.save_notes(content)
  local f = io.open(NOTES_FILE, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

-------------------------------------------------------------------------------
-- Session info
-------------------------------------------------------------------------------
function memory.get_session_id()
  return session_id
end

function memory.get_session_duration()
  return os.time() - session_start
end

function memory.get_session_action_count()
  return #session_actions
end

-------------------------------------------------------------------------------
-- Reset session-local state (for /clear)
-------------------------------------------------------------------------------
function memory.clear_session()
  session_actions = {}
  session_plan = {}
  session_errors = {}
  session_action_index = {}
  session_action_key_order = {}
end

-------------------------------------------------------------------------------
-- Build compact context for system prompt
-- Only includes data relevant to the current query
-------------------------------------------------------------------------------
function memory.build_context(current_query)
  local parts = {}

  local query_type = current_query and memory.categorize_query(current_query) or nil

  -- Session errors (most critical — prevents loops)
  local errors_str = memory.format_errors_for_prompt(3)
  if errors_str ~= "" then
    parts[#parts + 1] = errors_str
  end

  -- Action history (prevents repetition)
  local actions_str = memory.format_action_history(6)
  if actions_str ~= "" then
    parts[#parts + 1] = actions_str
  end

  -- Active plan
  local plan_str = memory.format_plan()
  if plan_str ~= "" then
    parts[#parts + 1] = plan_str
  end

  -- Learned patterns (only relevant type)
  local learned = memory.get_learned_patterns(2, query_type)
  if learned ~= "" then
    parts[#parts + 1] = learned
  end

  -- User preferences
  local prefs = memory.get_preferences()
  if prefs ~= "" then
    parts[#parts + 1] = "\nPreferences: " .. prefs
  end

  return table.concat(parts, "\n")
end

return memory
