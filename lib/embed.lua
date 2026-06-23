-- embed.lua: Persistent embedding interface using llama-server --embedding
-- Pure LuaJIT, communicates with llama-server via HTTP/JSON
-- Optimized for: Jenova Cognitive Architecture | Vulkan context persistence

local _dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
if not package.path:find(_dir, 1, true) then
  package.path = _dir .. "?.lua;" .. package.path
end

local json = require("json")
local http = require("http")
local ffi = require("ffi")

local embed = {}

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local EMBED_URL = os.getenv("JENOVA_LLAMA_EMBED_URL") or "http://127.0.0.1:8082"
local DIMS = 1024        -- Qwen3-Embedding-0.6B dimension
local CTX_SIZE = 4096   -- context window (max tokens) — must match -c in jenova-ca

local initialized = false

-------------------------------------------------------------------------------
-- Initialize: check if server is reachable
-------------------------------------------------------------------------------
function embed.init(opts)
  opts = opts or {}
  initialized = false
  EMBED_URL = opts.embed_url or os.getenv("JENOVA_LLAMA_EMBED_URL") or "http://127.0.0.1:8082"
  local embed_bin = opts.embed_bin or os.getenv("JENOVA_LLAMA_SERVER") or (opts.script_dir and (opts.script_dir .. "/external/llama.cpp/build/bin/llama-server"))
  local model_path = opts.model_path or os.getenv("JENOVA_EMBED_MODEL") or (opts.script_dir and (opts.script_dir .. "/models/Qwen3-Embedding-0.6B-Q8_0.gguf"))

  -- Quick check if already running
  local status = http.get(EMBED_URL .. "/health", 1)
  if status == 200 then
    initialized = true
    return true
  end

  -- Start in background and return immediately.
  if embed_bin and model_path then
    local port = EMBED_URL:match(":(%d+)") or "8082"
    local host = EMBED_URL:match("//([^:]+)") or "127.0.0.1"

    local f = io.open(embed_bin, "r")
    if f then
      f:close()
      local daemon = require('daemon')
      local args = { embed_bin, '-m', model_path, '--embedding', '--port', port, '--host', host,
                      '-ngl', '0', '-c', '4096', '-b', '512', '--offline' }

      local home = os.getenv("HOME") or "/tmp"
      local jca_home = os.getenv("JCA_HOME") or (home .. "/Jenova")
      local state_dir = os.getenv("JENOVA_STATE") or ((opts.script_dir and opts.script_dir ~= '') and (opts.script_dir .. "/.system") or (jca_home .. "/.system"))
      os.execute(string.format('mkdir -p %q', state_dir))
      
      local ok, pid_or_err = daemon.start_background(args, state_dir .. '/llama-embed.log', opts.script_dir or '.', state_dir .. '/llama-embed.pid', {GGML_VULKAN_DISABLE="1", GGML_VK_DEVICE=""})
      if ok then
        return true
      end
    end
  end

  initialized = false
  return false
end

function embed.is_available()
  if initialized then return true end
  -- Lazy check if it's ready now
  local status = http.get(EMBED_URL .. "/health", 1)
  if status == 200 then
    initialized = true
    return true
  end
  return false
end

function embed.dimensions()
  return DIMS
end

-------------------------------------------------------------------------------
-- Encode a single text string -> vector (table of floats)
-- Uses the /embedding endpoint of llama-server
-------------------------------------------------------------------------------
function embed.encode(text, task)
  if not initialized then return nil, "not initialized" end
  if not text or text == "" then return nil, "empty text" end

  task = task or "search_document"
  local prefixed = task .. ": " .. text

  local payload = json.encode({
    content = prefixed
  })

  local status, body = http.post(EMBED_URL .. "/embedding", payload, 30)
  if status ~= 200 then
    return nil, "embedding request failed: status " .. tostring(status) .. " - " .. tostring(body)
  end

  local ok, data = pcall(json.decode, body)
  if not ok or not data then return nil, "JSON decode failed" end
  
  -- llama-server returns { "embedding": [...] }
  local vec = data.embedding
  if not vec or #vec == 0 then return nil, "empty embedding vector in response" end

  if not DIMS or DIMS == 0 then DIMS = #vec end
  return vec, nil
end

-------------------------------------------------------------------------------
-- Encode multiple texts in one call
-------------------------------------------------------------------------------
function embed.batch_encode(texts, task)
  if not initialized then return nil, "not initialized" end
  if not texts or #texts == 0 then return nil, "empty text list" end

  task = task or "search_document"
  local vectors = {}

  -- llama-server supports batch embedding in some versions, but to be safe 
  -- and maintain compatibility with the standard /embedding endpoint,
  -- we'll process them efficiently. 
  -- NOTE: llama-server typically handles one prompt per /embedding call.
  -- Some versions support arrays, but let's stick to reliable sequential or concurrent-like logic.
  
  -- Optimization: If the server is truly persistent, sequential POSTs are fast
  -- because we skip the 800ms Vulkan init.
  for i, text in ipairs(texts) do
    local vec, err = embed.encode(text, task)
    if not vec then
      return nil, "batch error at index " .. i .. ": " .. tostring(err)
    end
    vectors[i] = vec
  end

  return vectors, nil
end

-------------------------------------------------------------------------------
-- Vector math utilities
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

function embed.dot(a, b)
  if not a or not b then return 0 end
  local n = math.min(#a, #b)
  local sum = 0
  for i = 1, n do
    sum = sum + a[i] * b[i]
  end
  return sum
end

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
