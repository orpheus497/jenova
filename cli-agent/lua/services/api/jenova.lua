-- services/api/jenova.lua — Jenova CLI API client
-- Communicates with the Anthropic Messages API via streaming SSE.

local M = {}

local DEFAULT_MODEL = "claude-sonnet-4-20250514"
local API_VERSION = "2023-06-01"
local DEFAULT_MAX_TOKENS = 16384

-- Model context windows and pricing (input/output per 1M tokens)
M.models = {
    ["claude-sonnet-4-20250514"] = { context = 200000, input_price = 3.0, output_price = 15.0 },
    ["claude-opus-4-20250514"]   = { context = 200000, input_price = 15.0, output_price = 75.0 },
    ["claude-haiku-3-20250307"]  = { context = 200000, input_price = 0.25, output_price = 1.25 },
}

--- Get the API base URL
function M.get_base_url()
    return os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
end

--- Get the API key
function M.get_api_key()
    local key = os.getenv("ANTHROPIC_API_KEY")
    if not key or key == "" then
        return nil, "ANTHROPIC_API_KEY not set"
    end
    return key
end

--- Build request headers
function M.build_headers(api_key)
    return {
        ["x-api-key"] = api_key,
        ["anthropic-version"] = API_VERSION,
        ["content-type"] = "application/json",
        ["anthropic-beta"] = "interleaved-thinking-2025-04-14",
    }
end

--- Send a message and return the response (blocking, non-streaming)
--- @param prompt string The user message
--- @param opts table Options: model, system_prompt, output_format, tools, messages
--- @return string|nil response The assistant's text response
function M.send_message(prompt, opts)
    opts = opts or {}
    local api_key, err = M.get_api_key()
    if not api_key then
        return nil, err
    end

    local model = opts.model or os.getenv("JENOVA_MODEL") or DEFAULT_MODEL
    local max_tokens = opts.max_tokens or DEFAULT_MAX_TOKENS

    -- Build messages array
    local messages = opts.messages or {}
    if prompt then
        table.insert(messages, {
            role = "user",
            content = prompt,
        })
    end

    -- Build request body
    local body = {
        model = model,
        max_tokens = max_tokens,
        messages = messages,
    }

    if opts.system_prompt then
        body.system = opts.system_prompt
    end

    if opts.tools then
        body.tools = opts.tools
    end

    -- Use jenova.http C bindings for HTTP requests, json_fallback for encoding.
    -- Note: http.post_json accepts pre-serialized JSON strings (URL, headers, body)
    -- because the FFI layer works with C strings, not Lua tables.
    local json_ok, json_mod = pcall(require, "utils.json_fallback")
    local http = jenova and jenova.http or nil

    if json_ok and http then
        local body_str = json_mod.stringify(body)
        local url = M.get_base_url() .. "/v1/messages"
        local headers = json_mod.stringify(M.build_headers(api_key))
        local response = http.post_json(url, headers, body_str)
        if response then
            local parsed = json_mod.parse(response)
            if parsed and parsed.content then
                local text_parts = {}
                for _, block in ipairs(parsed.content) do
                    if block.type == "text" then
                        table.insert(text_parts, block.text)
                    end
                end
                return table.concat(text_parts)
            end
            return response
        end
        return nil, "API request failed"
    end

    return nil, "HTTP client not available"
end

--- Calculate cost for a request
--- @param model string Model name
--- @param input_tokens number Input token count
--- @param output_tokens number Output token count
--- @return number cost Cost in USD
function M.calculate_cost(model, input_tokens, output_tokens)
    local info = M.models[model]
    if not info then return 0 end
    return (input_tokens * info.input_price / 1000000) +
           (output_tokens * info.output_price / 1000000)
end

return M
