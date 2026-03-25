-- search.lua: BM25 file search for coder-agent
-- Pure Lua, no dependencies beyond json.lua

local search = {}

local k1 = 1.5
local b = 0.75

local index = {}    -- { filepath = { terms = {term=count}, len = N } }
local df = {}       -- { term = doc_count }
local total_docs = 0
local avg_dl = 0

-------------------------------------------------------------------------------
-- Tokenize text into lowercase terms
-------------------------------------------------------------------------------
local function tokenize(text)
  local terms = {}
  for word in text:lower():gmatch("[%w_]+") do
    if #word > 1 and #word < 60 then
      terms[#terms + 1] = word
    end
  end
  return terms
end

-------------------------------------------------------------------------------
-- Index a single file
-------------------------------------------------------------------------------
local function index_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if #content > 100000 then return end
  if content:find("%z") then return end

  local terms = tokenize(content)
  if #terms == 0 then return end

  local term_counts = {}
  for _, t in ipairs(terms) do
    term_counts[t] = (term_counts[t] or 0) + 1
  end

  index[filepath] = { terms = term_counts, len = #terms }
  total_docs = total_docs + 1

  local seen = {}
  for _, t in ipairs(terms) do
    if not seen[t] then
      df[t] = (df[t] or 0) + 1
      seen[t] = true
    end
  end
end

-------------------------------------------------------------------------------
-- Index a directory tree
-------------------------------------------------------------------------------
function search.index_dir(root_dir, extensions)
  root_dir = root_dir or "."
  local ext_filter = ""
  if extensions and #extensions > 0 then
    local parts = {}
    for _, ext in ipairs(extensions) do
      parts[#parts + 1] = "-name '*." .. ext .. "'"
    end
    ext_filter = "\\( " .. table.concat(parts, " -o ") .. " \\)"
  end

  local cmd = string.format(
    "find %s -type f %s -not -path '*/.git/*' -not -path '*/.coder/*' -not -name '*.gguf' -not -name '*.bin' -size -100k 2>/dev/null | head -500",
    root_dir, ext_filter
  )
  local p = io.popen(cmd)
  local output = p:read("*a")
  p:close()

  index = {}
  df = {}
  total_docs = 0
  avg_dl = 0

  for filepath in output:gmatch("[^\n]+") do
    index_file(filepath)
  end

  if total_docs > 0 then
    local total_len = 0
    for _, doc in pairs(index) do
      total_len = total_len + doc.len
    end
    avg_dl = total_len / total_docs
  end

  return total_docs
end

-------------------------------------------------------------------------------
-- BM25 score for a single document against query terms
-------------------------------------------------------------------------------
local function bm25_score(doc, query_terms)
  local score = 0
  local dl = doc.len

  for _, qt in ipairs(query_terms) do
    local tf = doc.terms[qt] or 0
    if tf > 0 then
      local doc_freq = df[qt] or 0
      local idf = math.log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5) + 1)
      local tf_norm = (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avg_dl))
      score = score + idf * tf_norm
    end
  end

  return score
end

-------------------------------------------------------------------------------
-- Query: return top-k matching files with scores
-------------------------------------------------------------------------------
function search.query(query_str, top_k)
  top_k = top_k or 5
  if total_docs == 0 then return {} end

  local query_terms = tokenize(query_str)
  if #query_terms == 0 then return {} end

  local results = {}
  for filepath, doc in pairs(index) do
    local score = bm25_score(doc, query_terms)
    if score > 0 then
      results[#results + 1] = { path = filepath, score = score }
    end
  end

  table.sort(results, function(a, b_) return a.score > b_.score end)

  local top = {}
  for i = 1, math.min(top_k, #results) do
    top[i] = results[i]
  end
  return top
end

-------------------------------------------------------------------------------
-- Format results as string for tool output
-------------------------------------------------------------------------------
function search.format_results(results)
  if #results == 0 then return "No matching files found." end
  local parts = {}
  for i, r in ipairs(results) do
    parts[i] = string.format("%d. %s (score: %.2f)", i, r.path, r.score)
  end
  return table.concat(parts, "\n")
end

return search
