-- providers/openai.lua — OpenAI API provider
-- Supports GPT-4, GPT-3.5, and other OpenAI models

local json_fallback = require("utils.json_fallback")
local json = json_fallback  -- Always use fallback for table→string encoding
local http = jenova and jenova.http or nil

local OpenAIProvider = {
    name = "openai",
    api_key = nil,
    base_url = nil,
}

--- Model pricing (USD per 1M tokens)
OpenAIProvider.models = {
    ["gpt-4o"] = { context = 128000, input_price = 2.5, output_price = 10.0 },
    ["gpt-4o-mini"] = { context = 128000, input_price = 0.15, output_price = 0.6 },
    ["gpt-4-turbo"] = { context = 128000, input_price = 10.0, output_price = 30.0 },
    ["gpt-3.5-turbo"] = { context = 16385, input_price = 0.5, output_price = 1.5 },
}

function OpenAIProvider:is_available()
    local key = os.getenv("OPENAI_API_KEY")
    if key and key ~= "" then
        return true
    end

    if jenova.auth and jenova.auth.resolve_key then
        key = jenova.auth.resolve_key("openai")
        return key ~= nil and key ~= ""
    end

    return false
end

function OpenAIProvider:initialize()
    self.api_key = os.getenv("OPENAI_API_KEY")
    self.base_url = os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1"

    if not self.api_key or self.api_key == "" then
        if jenova.auth and jenova.auth.resolve_key then
            self.api_key = jenova.auth.resolve_key("openai")
        end
    end

    if not self.api_key or self.api_key == "" then
        error("OPENAI_API_KEY not set")
    end
end

function OpenAIProvider:shutdown() end

function OpenAIProvider:supports_streaming() return true end
function OpenAIProvider:supports_tools() return true end

function OpenAIProvider:get_models()
    local models = {}
    for model_name, _ in pairs(self.models) do
        table.insert(models, model_name)
    end
    table.sort(models)
    return models
end

function OpenAIProvider:generate(messages, options)
    options = options or {}

    if not http then
        return nil, "HTTP bindings not available (jenova.http not loaded)"
    end

    local body = {
        model = options.model or "gpt-4o-mini",
        messages = messages,
        max_tokens = options.max_tokens or 4096,
    }

    if options.temperature then
        body.temperature = options.temperature
    end

    if options.tools and #options.tools > 0 then
        -- Convert to OpenAI format
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

    local headers = {
        ["Authorization"] = "Bearer " .. self.api_key,
        ["Content-Type"] = "application/json",
    }

    local url = self.base_url .. "/chat/completions"
    local response = http.post_json(url, json.stringify(headers), json.stringify(body))

    if not response then
        return nil, "API request failed"
    end

    local parsed = json.parse(response)
    if not parsed then
        return nil, "Failed to parse response"
    end

    if parsed.error then
        return nil, string.format("API error: %s", parsed.error.message or "unknown")
    end

    if parsed.choices and #parsed.choices > 0 then
        local choice = parsed.choices[1]
        if choice.message and choice.message.content then
            return choice.message.content
        end
    end

    return nil, "No content in response"
end

function OpenAIProvider:count_tokens(text)
    return math.ceil(#text / 4)
end

function OpenAIProvider:get_pricing(model)
    return self.models[model] or {
        context = 128000,
        input_price = 2.5,
        output_price = 10.0,
    }
end

return OpenAIProvider
