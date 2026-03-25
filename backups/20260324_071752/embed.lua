-- embed.lua: Embedding interface using llama-embedding CLI + nomic-embed-text-v1.5
-- Pure LuaJIT, calls llama-embedding as subprocess, returns float vectors

local json = require("json")

local embed = {}

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local EMBED_BIN = nil   -- resolved in init()
local MODEL_PATH = nil  -- resolved in init()
local DIMS = 768        -- nomic-embed-text-v1.5 dimension
local CTX_SIZE = 512    -- nomic context window (512 tokens max)
local POOLING = "mean"

local initialized = false

-------------------------------------------------------------------------------
-- Initialize: locate binary and model
-------------------------------------------------------------------------------
function embed.init(opts)
  opts = opts or {}
  local script_dir = opts.script_dir or "."

  EMBED_BIN = opts.embed_bin or (script_dir .. "/llama.cpp/build/bin/llama-embedding")
  MODEL_PATH = opts.model_path or (script_dir .. "/models/nomic-embed-text-v1.5.Q8_0.gguf")

  local f = io.open(EMBED_BIN, "r")
  if not f then
    io.write("[embed] WARNING: llama-embedding not found at " .. EMBED_BIN .. "\n")
    return false
  end
  f:close()

  f = io.open(MODEL_PATH, "r")
  if not f then
    io.write("[embed] WARNING: embedding model not found at " .. MODEL_PATH .. "\n")
    return false
  end
  f:close()

  initialized = true
  return true
end

function embed.is_available()
  return initialized
end

function embed.dimensions()
  return DIMS
end

-------------------------------------------------------------------------------
-- Encode a single text string -> vector (table of floats)
-- nomic-embed-text uses task prefixes:
--   "search_document: " for indexing documents
--   "search_query: " for queries
--   "clustering: " for clustering
--   "classification: " for classification
-------------------------------------------------------------------------------
function embed.encode(text, task)
  if not initialized then return nil, "not initialized" end
  if not text or text == "" then return nil, "empty text" end

  task = task or "search_document"
  local prefixed = task .. ": " .. text

  -- Write text to temp file to avoid shell escaping issues
  local tmpfile_in = os.tmpname()
  local tmpfile_out = os.tmpname()

  local f = io.open(tmpfile_in, "w")
  if not f then return nil, "cannot write temp file" end
  f:write(prefixed)
  f:close()

  local cmd = string.format(
    '%s -m %s --embd-output-format json --pooling %s -c %d -f %s >%s 2>/dev/null',
    EMBED_BIN, MODEL_PATH, POOLING, CTX_SIZE, tmpfile_in, tmpfile_out
  )

  os.execute(cmd)

  local rf = io.open(tmpfile_out, "r")
  if not rf then
    os.remove(tmpfile_in)
    return nil, "no output from llama-embedding"
  end
  local output = rf:read("*a")
  rf:close()
  os.remove(tmpfile_in)
  os.remove(tmpfile_out)

  if output == "" then return nil, "empty output from llama-embedding" end

  local ok, data = pcall(json.decode, output)
  if not ok or not data then return nil, "JSON decode failed" end
  if not data.data or #data.data == 0 then return nil, "no embeddings in response" end

  local vec = data.data[1].embedding
  if not vec or #vec == 0 then return nil, "empty embedding vector" end

  DIMS = #vec
  return vec, nil
end

-------------------------------------------------------------------------------
-- Encode multiple texts in one CLI call (batch mode via separator)
-- Returns list of vectors in same order as input texts
-------------------------------------------------------------------------------
function embed.batch_encode(texts, task)
  if not initialized then return nil, "not initialized" end
  if not texts or #texts == 0 then return nil, "empty text list" end

  task = task or "search_document"

  -- llama-embedding supports multiple prompts via -p with separator
  -- But safest approach: write each as a separate line with -f and separator
  local tmpfile_in = os.tmpname()
  local tmpfile_out = os.tmpname()
  local separator = "<#sep#>"

  local f = io.open(tmpfile_in, "w")
  if not f then return nil, "cannot write temp file" end
  local parts = {}
  for _, text in ipairs(texts) do
    -- Remove newlines within each text (llama-embedding treats newlines as separators)
    local clean = text:gsub("\n", " "):gsub("\r", "")
    parts[#parts + 1] = task .. ": " .. clean
  end
  f:write(table.concat(parts, separator))
  f:close()

  local cmd = string.format(
    '%s -m %s --embd-output-format json --pooling %s -c %d -f %s --embd-separator "%s" >%s 2>/dev/null',
    EMBED_BIN, MODEL_PATH, POOLING, CTX_SIZE, tmpfile_in, separator, tmpfile_out
  )

  os.execute(cmd)

  local rf = io.open(tmpfile_out, "r")
  if not rf then
    os.remove(tmpfile_in)
    return nil, "no output from llama-embedding"
  end
  local output = rf:read("*a")
  rf:close()
  os.remove(tmpfile_in)
  os.remove(tmpfile_out)

  if output == "" then return nil, "empty output from llama-embedding" end

  local ok, data = pcall(json.decode, output)
  if not ok or not data then return nil, "JSON decode failed" end
  if not data.data then return nil, "no data in response" end

  local vectors = {}
  for i, item in ipairs(data.data) do
    vectors[i] = item.embedding
  end

  if #vectors ~= #texts then
    return nil, string.format("expected %d vectors, got %d", #texts, #vectors)
  end

  return vectors, nil
end

-------------------------------------------------------------------------------
-- Cosine similarity between two vectors
-------------------------------------------------------------------------------
function embed.cosine(a, b)
  if not a or not b then return 0 end
  local n = math.min(#a, #b)
  if n == 0 then return 0 end

  local dot = 0
  local norm_a = 0
  local norm_b = 0
  for i = 1, n do
    dot = dot + a[i] * b[i]
    norm_a = norm_a + a[i] * a[i]
    norm_b = norm_b + b[i] * b[i]
  end

  local denom = math.sqrt(norm_a) * math.sqrt(norm_b)
  if denom < 1e-12 then return 0 end
  return dot / denom
end

-------------------------------------------------------------------------------
-- Dot product (for pre-normalized vectors)
-------------------------------------------------------------------------------
function embed.dot(a, b)
  if not a or not b then return 0 end
  local n = math.min(#a, #b)
  local sum = 0
  for i = 1, n do
    sum = sum + a[i] * b[i]
  end
  return sum
end

-------------------------------------------------------------------------------
-- L2 normalize a vector in-place
-------------------------------------------------------------------------------
function embed.normalize(vec)
  if not vec or #vec == 0 then return vec end
  local norm = 0
  for i = 1, #vec do
    norm = norm + vec[i] * vec[i]
  end
  norm = math.sqrt(norm)
  if norm < 1e-12 then return vec end
  for i = 1, #vec do
    vec[i] = vec[i] / norm
  end
  return vec
end

return embed
