-- jenova/agent/memory.lua
-- Semantic memory: persistent fact store with keyword + tag retrieval.
--
-- The memory store is the lever for *natural context compression*:
-- instead of letting the agent re-Read a file or re-Run a command every
-- session to learn the same things, we extract durable facts from each
-- successful tool outcome and inject the most relevant ones into the
-- system prompt as a "Known about this project" section.
--
-- A fact is just a string of human language ("the build command is `make`",
-- "file foo.lua is 412 lines and exports M.setup") with metadata:
--   { id, text, tags, scope, source, confidence, created, last_used,
--     use_count, tokens }
--
-- Retrieval:
--   recall(query, n)            ranks all facts by overlap with the query
--   recall_for_context(opts)    convenience wrapper: pulls facts relevant
--                               to the active file, cwd, and recent prompt.
--
-- Storage:
--   stdpath("state")/jenova/memory.json — atomic write, debounced.
--   Capped at MAX_FACTS; eviction drops the lowest-scoring items.
--
-- Deduplication:
--   record() checks for an existing fact with the same canonical text;
--   if found, bumps use_count and recency instead of inserting a duplicate.

local M = {}

local STATE_DIR  = vim.fn.stdpath("state") .. "/jenova"
local STORE_PATH = STATE_DIR .. "/memory.json"

local MAX_FACTS         = 500       -- hard ceiling, eviction by score
local PERSIST_DEBOUNCE  = 750       -- ms
local DEFAULT_RECALL_N  = 8

-- ── Tokenisation ─────────────────────────────────────────────────────────────

local STOPWORDS = {
  ["a"]=true,["an"]=true,["the"]=true,["of"]=true,["in"]=true,["on"]=true,
  ["at"]=true,["to"]=true,["for"]=true,["with"]=true,["by"]=true,["is"]=true,
  ["are"]=true,["was"]=true,["be"]=true,["been"]=true,["this"]=true,
  ["that"]=true,["it"]=true,["its"]=true,["and"]=true,["or"]=true,["but"]=true,
  ["not"]=true,["as"]=true,["from"]=true,["into"]=true,["if"]=true,["so"]=true,
  ["do"]=true,["does"]=true,["did"]=true,["has"]=true,["have"]=true,["had"]=true,
  ["i"]=true,["you"]=true,["we"]=true,["my"]=true,["your"]=true,["our"]=true,
}

local function tokenize(text)
  if not text or text == "" then return {} end
  local out = {}
  for tok in text:lower():gmatch("[%w_%-%.%/]+") do
    if #tok > 1 and not STOPWORDS[tok] then
      out[#out + 1] = tok
    end
  end
  return out
end

local function token_set(tokens)
  local s = {}
  for _, t in ipairs(tokens) do s[t] = true end
  return s
end

-- ── State ────────────────────────────────────────────────────────────────────

local _store        = nil
local _flush_timer  = nil

local function ensure_dir()
  if vim.fn.isdirectory(STATE_DIR) == 0 then
    vim.fn.mkdir(STATE_DIR, "p")
  end
end

local function load_store()
  if _store then return _store end
  _store = { facts = {}, next_id = 1 }
  if vim.fn.filereadable(STORE_PATH) ~= 1 then return _store end
  local ok, lines = pcall(vim.fn.readfile, STORE_PATH)
  if not ok or type(lines) ~= "table" or #lines == 0 then return _store end
  local raw = table.concat(lines, "\n")
  local ok2, decoded = pcall(vim.json.decode, raw)
  if ok2 and type(decoded) == "table" and type(decoded.facts) == "table" then
    _store = decoded
    if not _store.next_id then _store.next_id = #_store.facts + 1 end
  end
  -- Re-tokenise on load if missing (forward compatibility).
  for _, f in ipairs(_store.facts) do
    if not f.tokens then f.tokens = tokenize(f.text or "") end
  end
  return _store
end

local function flush_now()
  if not _store then return end
  ensure_dir()
  local ok, encoded = pcall(vim.json.encode, _store)
  if not ok then return end
  pcall(vim.fn.writefile, { encoded }, STORE_PATH)
end

local function schedule_flush()
  if _flush_timer then
    pcall(function() _flush_timer:stop(); _flush_timer:close() end)
    _flush_timer = nil
  end
  _flush_timer = (vim.uv or vim.loop).new_timer()
  if not _flush_timer then flush_now(); return end
  _flush_timer:start(PERSIST_DEBOUNCE, 0, vim.schedule_wrap(function()
    flush_now()
    if _flush_timer then
      pcall(function() _flush_timer:close() end)
      _flush_timer = nil
    end
  end))
end

-- ── Workspace scope ──────────────────────────────────────────────────────────

local function workspace_scope()
  return "workspace:" .. (vim.fn.getcwd() or "?")
end

-- ── Scoring ──────────────────────────────────────────────────────────────────

local function jaccard(set_a, set_b, len_a, len_b)
  if len_a == 0 or len_b == 0 then return 0 end
  local inter = 0
  for k, _ in pairs(set_a) do
    if set_b[k] then inter = inter + 1 end
  end
  if inter == 0 then return 0 end
  local union = len_a + len_b - inter
  return inter / union
end

local function recency_factor(last_used)
  if not last_used or last_used == 0 then return 0.5 end
  local age_days = (os.time() - last_used) / 86400
  -- Half-life ≈ 30 days. Floor at 0.1 so old facts aren't completely buried.
  return math.max(0.1, math.exp(-age_days / 30))
end

local function score_fact(fact, query_set, query_len, query_tags)
  if not fact.tokens then return 0 end
  local fact_set = token_set(fact.tokens)
  local sim = jaccard(query_set, fact_set, query_len, #fact.tokens)
  -- Tag boost: any direct tag overlap multiplies score by 1.5×.
  if query_tags and fact.tags then
    for _, qt in ipairs(query_tags) do
      for _, ft in ipairs(fact.tags) do
        if qt == ft then sim = sim * 1.5; break end
      end
    end
  end
  -- Use-count log bonus.
  local use_bonus = math.log((fact.use_count or 0) + 1) * 0.05
  local conf = fact.confidence or 0.5
  return (sim + use_bonus) * recency_factor(fact.last_used) * conf
end

-- ── Public: record / dedup ───────────────────────────────────────────────────

local function canonical_text(s)
  return (s or ""):lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.record(text, opts)
  if type(text) ~= "string" or text == "" then return nil end
  opts = opts or {}
  load_store()

  local canon = canonical_text(text)
  -- Dedup: same canonical text in same scope → bump use_count + recency.
  local scope = opts.scope or workspace_scope()
  for _, f in ipairs(_store.facts) do
    if canonical_text(f.text) == canon and (f.scope or "") == scope then
      f.use_count = (f.use_count or 0) + 1
      f.last_used = os.time()
      if opts.confidence and opts.confidence > (f.confidence or 0) then
        f.confidence = opts.confidence
      end
      schedule_flush()
      return f.id
    end
  end

  local id = "f" .. tostring(_store.next_id or 1)
  _store.next_id = (_store.next_id or 1) + 1
  local fact = {
    id         = id,
    text       = text,
    tags       = opts.tags or {},
    scope      = scope,
    source     = opts.source or "manual",
    confidence = opts.confidence or 0.7,
    created    = os.time(),
    last_used  = os.time(),
    use_count  = 0,
    tokens     = tokenize(text),
  }
  table.insert(_store.facts, fact)

  -- Eviction: when we go over MAX_FACTS, drop the bottom 10% by passive
  -- score (no query) so the next record has headroom.
  if #_store.facts > MAX_FACTS then
    local empty_set, empty_len = {}, 0
    table.sort(_store.facts, function(a, b)
      return score_fact(a, empty_set, empty_len, nil)
           > score_fact(b, empty_set, empty_len, nil)
    end)
    local keep = math.floor(MAX_FACTS * 0.9)
    while #_store.facts > keep do table.remove(_store.facts) end
  end

  schedule_flush()
  return id
end

-- ── Public: recall ───────────────────────────────────────────────────────────

function M.recall(query, n, query_tags)
  load_store()
  n = n or DEFAULT_RECALL_N
  local q_tokens = tokenize(query or "")
  local q_set    = token_set(q_tokens)
  local q_len    = #q_tokens

  local scope = workspace_scope()
  local scored = {}
  for _, f in ipairs(_store.facts) do
    -- Workspace facts stay local; "global" facts always considered.
    if f.scope == scope or f.scope == "global" then
      local s = score_fact(f, q_set, q_len, query_tags)
      if s > 0 then
        table.insert(scored, { fact = f, score = s })
      end
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)

  local out = {}
  for i = 1, math.min(n, #scored) do
    local entry = scored[i]
    -- Reading a fact bumps its recency a little (gentle warmth).
    entry.fact.last_used = os.time()
    entry.fact.use_count = (entry.fact.use_count or 0) + 1
    table.insert(out, entry.fact)
  end
  if #out > 0 then schedule_flush() end
  return out
end

-- Convenience: pull facts relevant to the current editor context.
-- opts = { user_message = "...", active_file = "/abs/path", cwd = "...",
--          n = 8, extra_tags = {...} }
function M.recall_for_context(opts)
  opts = opts or {}
  local query_parts = {}
  if opts.user_message then table.insert(query_parts, opts.user_message) end
  if opts.active_file  then table.insert(query_parts, opts.active_file) end
  if opts.cwd          then table.insert(query_parts, opts.cwd) end
  local query = table.concat(query_parts, " ")

  local tags = {}
  if opts.active_file then
    table.insert(tags, "file:" .. opts.active_file)
    local rel = vim.fn.fnamemodify(opts.active_file, ":~:.")
    table.insert(tags, "file:" .. rel)
    local ext = vim.fn.fnamemodify(opts.active_file, ":e")
    if ext and ext ~= "" then table.insert(tags, "lang:" .. ext) end
  end
  if opts.extra_tags then
    for _, t in ipairs(opts.extra_tags) do table.insert(tags, t) end
  end

  return M.recall(query, opts.n or DEFAULT_RECALL_N, tags)
end

-- Format a recall result as a compact prompt section. Returns a string the
-- engine can paste into the system prompt under "## Known about this project".
function M.format_facts_for_prompt(facts)
  if not facts or #facts == 0 then return nil end
  local lines = {}
  for _, f in ipairs(facts) do
    -- One line per fact with a short tag suffix. Keep it tight: this
    -- runs every turn so brevity = throughput.
    local tag_str = ""
    if f.tags and #f.tags > 0 then
      local kept = {}
      for i = 1, math.min(3, #f.tags) do kept[i] = f.tags[i] end
      tag_str = "  [" .. table.concat(kept, ",") .. "]"
    end
    table.insert(lines, "- " .. f.text .. tag_str)
  end
  return table.concat(lines, "\n")
end

-- ── Public: management ───────────────────────────────────────────────────────

function M.forget(id)
  load_store()
  for i, f in ipairs(_store.facts) do
    if f.id == id then
      table.remove(_store.facts, i)
      schedule_flush()
      return true
    end
  end
  return false
end

function M.clear(scope_only)
  load_store()
  if scope_only then
    local scope = workspace_scope()
    local kept = {}
    for _, f in ipairs(_store.facts) do
      if f.scope ~= scope then table.insert(kept, f) end
    end
    _store.facts = kept
  else
    _store.facts = {}
    _store.next_id = 1
  end
  schedule_flush()
end

function M.stats()
  load_store()
  local scope = workspace_scope()
  local total, in_scope, global = 0, 0, 0
  for _, f in ipairs(_store.facts) do
    total = total + 1
    if f.scope == scope then in_scope = in_scope + 1
    elseif f.scope == "global" then global = global + 1 end
  end
  return { total = total, workspace = in_scope, global = global, scope = scope }
end

function M.list(n)
  load_store()
  n = n or 50
  local scope = workspace_scope()
  local out = {}
  for _, f in ipairs(_store.facts) do
    if f.scope == scope or f.scope == "global" then
      table.insert(out, f)
    end
  end
  table.sort(out, function(a, b)
    return (a.last_used or 0) > (b.last_used or 0)
  end)
  while #out > n do table.remove(out) end
  return out
end

function M.flush()
  flush_now()
end

return M
