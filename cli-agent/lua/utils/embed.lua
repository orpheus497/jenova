-- lua/utils/embed.lua: Minimal embedding interface for Jenova CLI
-- Ported from jenova/lib/embed.lua

local json = require("utils.json_fallback")
local trio = require("utils.trio")
local shell = require("utils.shell")

local M = {}

local initialized = false
local EMBED_URL = nil

function M.init()
    if initialized then return true end
    
    local endpoints = trio.get_endpoints()
    EMBED_URL = string.format("http://%s:%d", endpoints.host, endpoints.embed_port)
    
    -- Quick health check — prefer argv-based spawn (no shell, cross-platform)
    local health_url = EMBED_URL .. "/health"
    local res
    if jenova and jenova.process and jenova.process.spawn_json then
        local config = json.stringify({
            command = "curl",
            args = { "-sf", "--max-time", "1", health_url },
            timeout_ms = 5000,
            capture_stdout = true,
            capture_stderr = false,
        })
        local result = jenova.process.spawn_json(config)
        if result and type(result) == "table" then
            res = result.stdout or ""
        end
    else
        local cmd = string.format("curl -sf --max-time 1 %s 2>/dev/null", shell.quote(health_url))
        local p = io.popen(cmd)
        if p then
            res = p:read("*a")
            p:close()
        end
    end

    if res and res ~= "" then
        initialized = true
        return true
    end
    
    return false
end

function M.is_available()
    return initialized
end

function M.encode(text, task)
    if not initialized and not M.init() then return nil, "not available" end

    task = task or "search_document"
    local prefixed = task .. ": " .. text

    local payload = json.stringify({ content = prefixed })

    local tmp_base = os.getenv("TMP") or os.getenv("TEMP") or "/tmp"
    tmp_base = tmp_base:gsub("[/\\]$", "")
    local tmp_file = string.format("%s/jenova-embed-%d-%04x.json", tmp_base, os.time(), math.random(0, 0xffff))

    local f = io.open(tmp_file, "w")
    if f then
        f:write(payload)
        f:close()
    end

    local embed_url = EMBED_URL .. "/embedding"
    local body

    -- Prefer argv-based spawn (no shell, cross-platform)
    if jenova and jenova.process and jenova.process.spawn_json then
        local config = json.stringify({
            command = "curl",
            args = { "-sf", "-X", "POST",
                     "-H", "Content-Type: application/json",
                     "-d", "@" .. tmp_file,
                     embed_url },
            timeout_ms = 30000,
            capture_stdout = true,
            capture_stderr = false,
        })
        local result = jenova.process.spawn_json(config)
        if result and type(result) == "table" then
            body = result.stdout or ""
        end
    else
        local cmd = string.format("curl -sf -X POST -H 'Content-Type: application/json' -d @%s %s 2>/dev/null",
            shell.quote(tmp_file), shell.quote(embed_url))
        local p = io.popen(cmd)
        if p then
            body = p:read("*a")
            p:close()
        end
    end

    os.remove(tmp_file)

    if not body or body == "" then return nil, "request failed" end

    local ok, data = pcall(json.parse, body)
    if not ok or not data or not data.embedding then return nil, "parse failed" end

    return data.embedding
end

-- Encode a list of texts sequentially.  The llama-server /embedding endpoint
-- does not support multi-document batching in a single HTTP request, so this
-- is O(N) HTTP calls.  Callers should pass only as many texts as necessary;
-- local_search caps this at the number of candidate files (≤ 300).
function M.encode_batch(texts, task)
    if not texts or #texts == 0 then return {}, nil end
    local vectors = {}
    for i, text in ipairs(texts) do
        local vec, err = M.encode(text, task)
        if not vec then
            vectors[i] = nil
        else
            vectors[i] = vec
        end
    end
    return vectors, nil
end

function M.cosine(a, b)
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

function M.normalize(vec)
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

return M
