-- providers/anthropic.lua — Anthropic Claude API provider
-- Uses the Messages API with streaming support

local json_fallback = require("utils.json_fallback")
local json = json_fallback  -- Always use fallback for table→string encoding
local http = jenova and jenova.http or nil

local AnthropicProvider = {
    name = "anthropic",
    api_key = nil,
    base_url = nil,
}

--- Model pricing (USD per 1M tokens)
AnthropicProvider.models = {
    ["claude-sonnet-4-20250514"] = { context = 200000, input_price = 3.0, output_price = 15.0 },
    ["claude-opus-4-20250514"]   = { context = 200000, input_price = 15.0, output_price = 75.0 },
    ["claude-haiku-3-20250307"]  = { context = 200000, input_price = 0.25, output_price = 1.25 },
    ["claude-sonnet-4-5-20250929"] = { context = 200000, input_price = 3.0, output_price = 15.0 },
    ["claude-opus-4-5-20251101"]   = { context = 200000, input_price = 15.0, output_price = 75.0 },
}

--- Check if provider is available
--- @return boolean available
function AnthropicProvider:is_available()
    -- Check for API key
    local key = os.getenv("ANTHROPIC_API_KEY")
    if key and key ~= "" then
        return true
    end

    -- Check if auth system has stored key
    if jenova.auth and jenova.auth.resolve_key then
        key = jenova.auth.resolve_key("anthropic")
        return key ~= nil and key ~= ""
    end

    return false
end

--- Initialize provider
function AnthropicProvider:initialize()
    self.api_key = os.getenv("ANTHROPIC_API_KEY")
    self.base_url = os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"

    if not self.api_key or self.api_key == "" then
        -- Try auth system
        if jenova.auth and jenova.auth.resolve_key then
            self.api_key = jenova.auth.resolve_key("anthropic")
        end
    end

    if not self.api_key or self.api_key == "" then
        error("ANTHROPIC_API_KEY not set")
    end
end

--- Shutdown provider
function AnthropicProvider:shutdown()
    -- Nothing to clean up
end

--- Check if streaming is supported
--- @return boolean supported
function AnthropicProvider:supports_streaming()
    return true
end

--- Check if tool calling is supported
--- @return boolean supported
function AnthropicProvider:supports_tools()
    return true
end

--- Get list of available models
--- @return table models List of model names
function AnthropicProvider:get_models()
    local models = {}
    for model_name, _ in pairs(self.models) do
        table.insert(models, model_name)
    end
    table.sort(models)
    return models
end

--- Generate completion (non-streaming for now)
--- @param messages table Array of message objects
--- @param options table Generation options
--- @return string|nil response
function AnthropicProvider:generate(messages, options)
    options = options or {}

    local model = options.model or "claude-sonnet-4-5-20250929"
    local max_tokens = options.max_tokens or 8192

    -- Build request body
    local body = {
        model = model,
        max_tokens = max_tokens,
        messages = messages,
    }

    if options.system then
        body.system = options.system
    end

    if options.temperature then
        body.temperature = options.temperature
    end

    if options.tools and #options.tools > 0 then
        body.tools = options.tools
    end

    if options.thinking_enabled then
        body.thinking = {
            type = "enabled",
            budget_tokens = options.thinking_budget or 2000,
        }
    end

    -- Build headers
    local headers = {
        ["x-api-key"] = self.api_key,
        ["anthropic-version"] = "2023-06-01",
        ["content-type"] = "application/json",
    }

    if options.thinking_enabled then
        headers["anthropic-beta"] = "interleaved-thinking-2025-04-14"
    end

    -- Make API call
    local url = self.base_url .. "/v1/messages"
    local headers_json = json.stringify(headers)
    local body_json = json.stringify(body)

    local response = http.post_json(url, headers_json, body_json)
    if not response then
        return nil, "API request failed"
    end

    -- Parse response
    local parsed = json.parse(response)
    if not parsed then
        return nil, "Failed to parse API response"
    end

    if parsed.error then
        return nil, string.format("API error: %s", parsed.error.message or "unknown")
    end

    -- Extract text content
    if parsed.content then
        local text_parts = {}
        for _, block in ipairs(parsed.content) do
            if block.type == "text" then
                table.insert(text_parts, block.text)
            end
        end
        return table.concat(text_parts)
    end

    return nil, "No content in response"
end

--- Count tokens (estimate)
--- @param text string Text to tokenize
--- @return number count Token count (estimated)
function AnthropicProvider:count_tokens(text)
    -- Rough estimate: ~4 chars per token for English
    return math.ceil(#text / 4)
end

--- Get pricing for a model
--- @param model string Model name
--- @return table pricing Pricing information
function AnthropicProvider:get_pricing(model)
    return self.models[model] or {
        context = 200000,
        input_price = 3.0,
        output_price = 15.0,
    }
end

return AnthropicProvider
