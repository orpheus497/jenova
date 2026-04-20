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

-- Lazy-loaded pure-Lua HTTP fallback (no C binding required)
local _lua_http = nil
local function get_lua_http()
    if _lua_http == nil then
        local ok, mod = pcall(require, "utils.http")
        _lua_http = ok and mod or false
    end
    return _lua_http or nil
end

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
    -- Prefer C binding when available (zero subprocess overhead)
    local _j = rawget(_G, "jenova")
    if type(_j) == "table" and _j.http then
        return _j.http
    end
    -- Fall back to pure-Lua curl wrapper
    return get_lua_http()
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
    -- Both the C binding and utils.http expose get() as plain functions.
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

function M:supports_streaming()
    local _j = rawget(_G, "jenova")
    return type(_j) == "table" and type(_j.http) == "table"
        and type(_j.http.post_stream) == "function"
end
function M:supports_tools() return true end

-- Convert a messages array into the OpenAI-compatible body proxy.lua expects.
local function to_chat_body(messages, options)
    options = options or {}
    local body = {
        model = options.model or os.getenv("JENOVA_DEFAULT_MODEL") or "qwen2.5-coder-7b-instruct",
        messages = messages,
        stream = options.stream or false,
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
        -- Tell llama-server it may call tools; without this it silently ignores them.
        body.tool_choice = "auto"
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

-- Convert Anthropic-style multi-turn messages to OpenAI format.
-- query_engine stores turns as:
--   assistant: content array with {type="tool_use", id, name, input}
--   user:      content array with {type="tool_result", tool_use_id, content}
-- llama-server / OpenAI expect:
--   assistant: content=text, tool_calls=[{id, type="function", function={name, arguments}}]
--   tool:      role="tool", tool_call_id=id, content=string
local function anthropic_to_openai_messages(messages)
    local out = {}
    for _, msg in ipairs(messages) do
        if type(msg.content) ~= "table" then
            -- plain string content — pass through unchanged
            table.insert(out, msg)
        elseif msg.role == "assistant" then
            -- Split into text + tool_calls
            local text_parts = {}
            local tool_calls = {}
            for _, block in ipairs(msg.content) do
                if block.type == "text" then
                    table.insert(text_parts, block.text or "")
                elseif block.type == "tool_use" then
                    table.insert(tool_calls, {
                        id   = block.id or ("call_" .. #tool_calls),
                        type = "function",
                        ["function"] = {
                            name      = block.name,
                            arguments = type(block.input) == "table"
                                and json.stringify(block.input)
                                or tostring(block.input or "{}"),
                        },
                    })
                end
            end
            local oai_msg = { role = "assistant" }
            oai_msg.content = #text_parts > 0 and table.concat(text_parts, "") or nil
            if #tool_calls > 0 then oai_msg.tool_calls = tool_calls end
            table.insert(out, oai_msg)
        elseif msg.role == "user" then
            -- Check if this is a tool-result message
            local has_tool_result = false
            for _, block in ipairs(msg.content) do
                if block.type == "tool_result" then
                    has_tool_result = true
                    table.insert(out, {
                        role         = "tool",
                        tool_call_id = block.tool_use_id,
                        content      = type(block.content) == "string"
                            and block.content
                            or json.stringify(block.content),
                    })
                end
            end
            if not has_tool_result then
                -- Regular user message with array content (e.g. image blocks) — pass through
                table.insert(out, msg)
            end
        else
            table.insert(out, msg)
        end
    end
    return out
end

local function normalize_messages(messages)
    if type(messages) == "string" then
        return { { role = "user", content = messages } }
    end
    return anthropic_to_openai_messages(messages)
end

-- Parse an SSE stream body (multi-line string of "data: {...}" lines)
-- and call on_chunk(delta_text) for each token.  Returns the final
-- accumulated text and finish_reason.
local function parse_sse_stream(body, on_chunk)
    local content = ""
    local finish_reason = "stop"
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line:sub(1, 6) == "data: " then
            local payload = line:sub(7)
            if payload == "[DONE]" then break end
            local ok, chunk = pcall(json.parse, payload)
            if ok and type(chunk) == "table" then
                local choices = chunk.choices
                if type(choices) == "table" and choices[1] then
                    local delta = choices[1].delta or {}
                    local piece = delta.content or ""
                    if piece ~= "" then
                        content = content .. piece
                        if on_chunk then on_chunk(piece) end
                    end
                    if choices[1].finish_reason then
                        finish_reason = choices[1].finish_reason
                    end
                end
            end
        end
    end
    return content, finish_reason
end

function M:generate_stream(messages, options, on_chunk)
    if not self._initialized then self:initialize() end
    local _j = rawget(_G, "jenova")
    if not (type(_j) == "table" and _j.http and _j.http.post_stream) then
        -- Fall back to non-streaming generate, deliver whole response as one chunk.
        local resp, err = self:generate(messages, options)
        if not resp then return nil, err end
        local text = type(resp) == "table" and (resp.content or "") or tostring(resp)
        if on_chunk then on_chunk(text) end
        return resp
    end

    local opts_stream = setmetatable({ stream = true }, { __index = options or {} })
    local body = to_chat_body(normalize_messages(messages), opts_stream)
    local body_str = json.stringify(body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Jenova-Client"] = "cli-agent/0.1",
    }
    local headers_str = json.stringify(headers)

    local raw, err = _j.http.post_stream(
        self._base_url .. "/v1/chat/completions", headers_str, body_str)
    if not raw then return nil, err or "stream request failed" end

    local content, finish_reason = parse_sse_stream(raw, on_chunk)
    return {
        content       = content,
        tool_calls    = nil,
        finish_reason = finish_reason,
    }
end

function M:generate(messages, options)
    if not self._initialized then self:initialize() end
    local http = get_http()
    if not http then
        return nil, "no HTTP client available (install curl or build with C bindings)"
    end

    local body = to_chat_body(normalize_messages(messages), options)
    local body_str = json.stringify(body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Jenova-Client"] = "cli-agent/0.1",
    }
    local headers_str = json.stringify(headers)

    local resp, err = http.post_json(self._base_url .. "/v1/chat/completions", headers_str, body_str)
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
            -- (plain function call — works for both C binding and utils.http)
        if resp then
            local parsed = json.parse(resp)
            if type(parsed) == "table" and type(parsed.count) == "number" then
                return parsed.count
            end
        end
    end
    -- Try in-process llama tokenizer (accurate when a model is loaded).
    local _j2 = rawget(_G, "jenova")
    if _j2 and _j2.llama and _j2.llama.count_tokens then
        local ok, count = pcall(_j2.llama.count_tokens, 1, text)
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
    -- (plain function call — works for both C binding and utils.http)
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
