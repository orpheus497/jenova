-- providers/jenova_backend.lua — Jenova Cognitive Architecture backend provider
--
-- Talks to the persistent `proxy.lua` intelligence layer that runs as part of
-- the Jenova backend (default http://127.0.0.1:8080). That proxy fronts
-- `llama-server` on 8081, injects BM25 + semantic RAG, and routes intent —
-- so when it's running, this provider is the highest-quality local path.
--
-- When the proxy is not detected, cli-agent falls back to the in-process
-- llamacpp provider (see providers/llamacpp.lua).

local trio = require("utils.trio")
local json = require("utils.json_fallback")

local M = {
    name = "jenova_backend",
    _initialized = false,
    _base_url = nil,
    _endpoints = nil,
}

local function resolve_endpoints()
    return trio.get_endpoints()
end

local function get_http()
    return jenova and jenova.http or nil
end

function M:initialize(opts)
    opts = opts or {}
    self._endpoints = resolve_endpoints()
    -- Base URL should be host:port, NOT the full proxy_url path.
    self._base_url = opts.base_url or os.getenv("JENOVA_PROXY_URL") or 
                     string.format("http://%s:%d", self._endpoints.host, self._endpoints.port)
    -- Strip trailing endpoint paths if they exist (like /v1/chat/completions)
    self._base_url = self._base_url:gsub("/v1/chat/completions/?$", "")
    -- Strip trailing slash
    self._base_url = self._base_url:gsub("/$", "")
    self._initialized = true
    return true
end

function M:shutdown()
    self._initialized = false
end

function M:is_available()
    local http = get_http()
    if not http then return false end
    if not self._initialized then self:initialize() end
    local health_url = self._base_url .. "/v1/health"
    -- GET /v1/health is served by proxy.lua's health handler.
    local ok, resp = pcall(http.get, health_url, nil)
    if not ok or not resp then return false end
    -- proxy.lua returns a small JSON object including { "status": "ok" }.
    local parsed_ok, body = pcall(json.parse, resp)
    if not parsed_ok or type(body) ~= "table" then
        -- Plain-text 200 OK is still acceptable.
        return resp:find("ok", 1, true) ~= nil
    end
    return body.status == "ok" or body.ok == true
end

function M:supports_streaming() return true end
function M:supports_tools() return true end

-- Convert a messages array into the OpenAI-compatible body proxy.lua expects.
local function to_chat_body(messages, options)
    options = options or {}
    local body = {
        model = options.model or os.getenv("JENOVA_DEFAULT_MODEL") or "qwen2.5-coder-7b-instruct",
        messages = messages,
        stream = false,
    }
    if options.max_tokens then body.max_tokens = options.max_tokens end
    if options.temperature then body.temperature = options.temperature end
    if options.tools and #options.tools > 0 then
        body.tools = {}
        for _, tool in ipairs(options.tools) do
            table.insert(body.tools, {
                type = "function",
                ["function"] = {
                    name = tool.name,
                    description = tool.description,
                    parameters = tool.input_schema or {},
                }
            })
        end
    end
    if options.system_prompt then
        -- Prepend as a system message if not already present.
        local has_system = false
        for _, m in ipairs(messages) do
            if type(m) == "table" and m.role == "system" then has_system = true; break end
        end
        if not has_system then
            table.insert(body.messages, 1, { role = "system", content = options.system_prompt })
        end
    end
    return body
end

local function normalize_messages(messages)
    if type(messages) == "string" then
        return { { role = "user", content = messages } }
    end
    return messages
end

function M:generate(messages, options)
    if not self._initialized then self:initialize() end
    local http = get_http()
    if not http then
        return nil, "jenova.http binding unavailable"
    end

    local body = to_chat_body(normalize_messages(messages), options)
    local body_str = json.stringify(body)
    local headers = json.stringify({
        ["Content-Type"] = "application/json",
        ["X-Jenova-Client"] = "cli-agent/0.1",
    })

    local resp, err = http.post_json(self._base_url .. "/v1/chat/completions", headers, body_str)
    if not resp then return nil, err or "proxy.lua request failed" end

    local parsed = json.parse(resp)
    if type(parsed) ~= "table" then
        return nil, "invalid JSON from proxy.lua"
    end
    local choices = parsed.choices
    if type(choices) ~= "table" or #choices == 0 then
        return nil, "no choices in proxy.lua response"
    end
    local msg = choices[1].message or {}
    -- Return structured response so tool_calls survive the provider boundary.
    -- create_message_stream in providers/base.lua inspects this table to emit
    -- proper tool_use events. Plain text callers still get msg.content.
    return {
        content    = msg.content or "",
        tool_calls = msg.tool_calls,
        finish_reason = choices[1].finish_reason,
    }
end

function M:count_tokens(text)
    local http = get_http()
    if http and self._base_url then
        local body = json.stringify({ text = text })
        local resp = http.post_json(self._base_url .. "/v1/tokenize",
            json.stringify({ ["Content-Type"] = "application/json" }), body)
        if resp then
            local parsed = json.parse(resp)
            if type(parsed) == "table" and type(parsed.count) == "number" then
                return parsed.count
            end
        end
    end
    -- Try in-process llama tokenizer (accurate when a model is loaded).
    if jenova and jenova.llama and jenova.llama.count_tokens then
        local ok, count = pcall(jenova.llama.count_tokens, 1, text)
        if ok and type(count) == "number" and count > 0 then
            return count
        end
    end
    -- Heuristic fallback: count whitespace-delimited words and multiply by 1.3
    -- (English averages ~1.3 tokens per word; better than raw byte-division).
    local word_count = select(2, text:gsub("%S+", ""))
    return math.max(1, math.ceil(word_count * 1.3))
end

function M:get_models()
    local http = get_http()
    if not (http and self._base_url) then return {} end
    local resp = http.get(self._base_url .. "/v1/models", nil)
    if not resp then return {} end
    local parsed = json.parse(resp)
    if type(parsed) ~= "table" or type(parsed.data) ~= "table" then
        return {}
    end
    local out = {}
    for _, m in ipairs(parsed.data) do
        if type(m) == "table" and m.id then table.insert(out, m.id) end
    end
    return out
end

function M:get_pricing(_model)
    return { input = 0, output = 0, unit = "local" }
end

return M
