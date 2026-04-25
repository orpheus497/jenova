-- jenova/agent/learning.lua
-- Tool-usage learning database.
--
-- Records every tool invocation (success / failure, error signature, duration)
-- and detects pathological repetition: when the model issues the same call
-- with the same arguments and it has just failed in this session, the engine
-- short-circuits the call with a feedback message instead of re-running it.
--
-- Two scopes:
--   • In-memory session cache (per jvim run) — used for fast repetition
--     guards. Keeps the last 32 calls per tool plus a small dedup set.
--   • Persistent JSON store at stdpath("state")/jenova/tool_learning.json —
--     long-term aggregate stats: success/failure counters, top error keys,
--     and the timestamp of the most recent failure pattern. Survives across
--     editor restarts so the agent learns over time.

local M = {}

local STATE_DIR  = vim.fn.stdpath("state") .. "/jenova"
local STORE_PATH = STATE_DIR .. "/tool_learning.json"

local SESSION_HISTORY_LIMIT = 32   -- per-tool ring buffer
local REPETITION_WINDOW     = 3    -- how many recent failures count as a loop
local PERSIST_DEBOUNCE_MS   = 500  -- batch writes

-- ── State ────────────────────────────────────────────────────────────────────

-- Persisted aggregate stats:
--   { tools = { [name] = { success, failure, last_seen, errors = {key=count} } } }
local _store = nil

-- In-memory session: { [tool_name] = { { sig, ok, err_key, ts }, ... } }
local _session = {}

-- Debounced flush timer
local _flush_timer = nil

-- ── Persistence ──────────────────────────────────────────────────────────────

local function ensure_dir()
  if vim.fn.isdirectory(STATE_DIR) == 0 then
    vim.fn.mkdir(STATE_DIR, "p")
  end
end

local function load_store()
  if _store then return _store end
  _store = { tools = {} }
  if vim.fn.filereadable(STORE_PATH) ~= 1 then return _store end
  local ok, lines = pcall(vim.fn.readfile, STORE_PATH)
  if not ok or type(lines) ~= "table" or #lines == 0 then return _store end
  local raw = table.concat(lines, "\n")
  local ok2, decoded = pcall(vim.json.decode, raw)
  if ok2 and type(decoded) == "table" and type(decoded.tools) == "table" then
    _store = decoded
  end
  return _store
end

local function flush_now()
  if not _store then return end
  ensure_dir()
  local ok, encoded = pcall(vim.json.encode, _store)
  if not ok then return end
  -- 's' flag → atomic-style replace via temp file + rename, so a crash
  -- mid-write can't truncate the persistent learning database.
  pcall(vim.fn.writefile, { encoded }, STORE_PATH, "s")
end

local function schedule_flush()
  if _flush_timer then
    pcall(function() _flush_timer:stop(); _flush_timer:close() end)
    _flush_timer = nil
  end
  _flush_timer = (vim.uv or vim.loop).new_timer()
  if not _flush_timer then flush_now(); return end
  _flush_timer:start(PERSIST_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    flush_now()
    if _flush_timer then
      pcall(function() _flush_timer:close() end)
      _flush_timer = nil
    end
  end))
end

-- ── Signature & error classification ─────────────────────────────────────────

-- Stable canonical JSON of the args table so identical calls map to the same
-- signature. Field order matters in vim.json.encode, so sort keys first.
--
-- Use vim.islist (Neovim 0.10+) / vim.tbl_islist as a robust array check —
-- the previous `#value > 0` heuristic gave the wrong answer for tables with
-- holes or mixed key types, producing unstable signatures that defeated the
-- repetition guard.
local function is_list_like(value)
  if vim.islist then return vim.islist(value) end
  if vim.tbl_islist then return vim.tbl_islist(value) end
  -- Fallback (very old nvim): require contiguous 1..n integer keys.
  local n = 0
  for _ in pairs(value) do n = n + 1 end
  for i = 1, n do if value[i] == nil then return false end end
  return n > 0
end

-- Build a sortable, type-distinguishing representation of a key so that
-- a numeric key 1 and a string key "1" don't collide. Without the type
-- prefix `tostring(1) == tostring("1") == "1"` and the dedup-by-key
-- logic in canonical() would drop one of them, producing two different
-- input tables that both hash to the same signature — and breaking the
-- repetition guard for any tool whose arguments contain mixed-type keys.
local function key_repr(k)
  return type(k) .. "\0" .. tostring(k)
end

local function canonical(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if is_list_like(value) then
    local parts = {}
    for _, v in ipairs(value) do table.insert(parts, canonical(v)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  -- Collect (sort-key, original-key) pairs. The sort key is type-prefixed
  -- so "1" (string) and 1 (number) sort to different positions and
  -- both survive into the output JSON; the original key is what we
  -- actually emit via vim.json.encode (preserving its real type).
  local entries = {}
  for k, _ in pairs(value) do
    table.insert(entries, { sort = key_repr(k), key = k })
  end
  table.sort(entries, function(a, b) return a.sort < b.sort end)
  local parts = {}
  for _, e in ipairs(entries) do
    table.insert(parts, vim.json.encode(e.key) .. ":" .. canonical(value[e.key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.signature(name, args)
  local body = canonical(args or {})
  return name .. ":" .. body
end

-- Reduce a free-form error string to a coarse classifier so we can count
-- recurrences (e.g. "ENOENT", "Permission denied", "no LSP client", …).
local CLASSIFIERS = {
  { pat = "[Pp]ermission denied",            key = "permission_denied" },
  { pat = "[Aa]ccess denied",                key = "access_denied" },
  { pat = "ENOENT",                          key = "not_found" },
  { pat = "[Nn]ot found",                    key = "not_found" },
  { pat = "[Ff]ile not found",               key = "not_found" },
  { pat = "[Rr]estricted path",              key = "restricted_path" },
  { pat = "[Tt]imed? out",                   key = "timeout" },
  { pat = "[Ii]nvalid pattern",              key = "invalid_pattern" },
  { pat = "[Ii]nvalid argument",             key = "invalid_argument" },
  { pat = "[Mm]ust be a number",             key = "invalid_argument" },
  { pat = "is required",                     key = "missing_argument" },
  { pat = "no LSP client",                   key = "no_lsp_client" },
  { pat = "[Uu]nknown tool",                 key = "unknown_tool" },
  { pat = "[Ss]andbox",                      key = "sandbox_block" },
  { pat = "[Bb]eyond the file length",       key = "out_of_range" },
  { pat = "exit %d+",                        key = "nonzero_exit" },
}

function M.classify_error(err)
  if not err then return nil end
  local s = tostring(err)
  for _, c in ipairs(CLASSIFIERS) do
    if s:find(c.pat) then return c.key end
  end
  -- Fallback: first 40 chars, normalised
  local short = s:gsub("%s+", "_"):sub(1, 40)
  return "other:" .. short
end

-- ── Recording ────────────────────────────────────────────────────────────────

local function ensure_tool_stats(name)
  load_store()
  if not _store.tools[name] then
    _store.tools[name] = { success = 0, failure = 0, last_seen = 0, errors = {} }
  end
  return _store.tools[name]
end

local function push_session(name, sig, ok, err_key)
  if not _session[name] then _session[name] = {} end
  local q = _session[name]
  table.insert(q, { sig = sig, ok = ok, err_key = err_key, ts = os.time() })
  while #q > SESSION_HISTORY_LIMIT do table.remove(q, 1) end
end

function M.record(name, args, ok, err)
  local sig     = M.signature(name, args)
  local err_key = (not ok) and M.classify_error(err) or nil

  push_session(name, sig, ok, err_key)

  local stats = ensure_tool_stats(name)
  stats.last_seen = os.time()
  if ok then
    stats.success = (stats.success or 0) + 1
  else
    stats.failure = (stats.failure or 0) + 1
    if err_key then
      stats.errors[err_key] = (stats.errors[err_key] or 0) + 1
    end
  end
  schedule_flush()
end

-- ── Repetition detection ─────────────────────────────────────────────────────

-- Returns (is_repetition, advice_string) when the same tool+args has just
-- failed REPETITION_WINDOW or more times in a row in this session. The advice
-- string is suitable for returning as the tool result so the model is forced
-- to stop and reconsider.
function M.check_repetition(name, args)
  local q = _session[name]
  if not q or #q == 0 then return false, nil end
  local sig = M.signature(name, args)
  local streak = 0
  local last_err = nil
  for i = #q, 1, -1 do
    local entry = q[i]
    if entry.sig == sig and not entry.ok then
      streak = streak + 1
      last_err = entry.err_key or last_err
    else
      break
    end
  end
  if streak >= REPETITION_WINDOW then
    local advice = string.format(
      "[REPETITION_GUARD] You have called %s with these exact arguments %d times in a row and it failed each time (error class: %s). Stop retrying. Investigate the cause: re-Read the file, list the directory, check the path, or pick a different tool. Do NOT call %s with the same arguments again.",
      name, streak, last_err or "unknown", name)
    return true, advice
  end
  return false, nil
end

-- Returns advice text if the model is showing signs of looping but hasn't
-- yet hit the hard repetition guard. Used as a softer hint that the engine
-- can append to the result so the model self-corrects.
function M.soft_hint(name, args)
  local q = _session[name]
  if not q or #q < 2 then return nil end
  local sig = M.signature(name, args)
  local same_sig_failures = 0
  for _, entry in ipairs(q) do
    if entry.sig == sig and not entry.ok then
      same_sig_failures = same_sig_failures + 1
    end
  end
  if same_sig_failures >= 2 then
    return string.format(
      "[HINT] This is failure #%d for %s with these exact arguments. If the next attempt fails the engine will block further retries. Consider a different approach.",
      same_sig_failures, name)
  end
  return nil
end

-- ── Inspection / cleanup ─────────────────────────────────────────────────────

function M.stats(name)
  load_store()
  if name then return _store.tools[name] end
  return _store.tools
end

function M.session_summary()
  local out = {}
  for name, q in pairs(_session) do
    local ok_n, fail_n = 0, 0
    for _, e in ipairs(q) do
      if e.ok then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
    end
    table.insert(out, { name = name, ok = ok_n, fail = fail_n, recent = #q })
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.reset_session()
  _session = {}
end

function M.flush()
  flush_now()
end

return M
