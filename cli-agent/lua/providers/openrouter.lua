-- providers/openrouter.lua — OpenRouter API provider
-- Unified API for multiple LLM providers

local json_fallback = require("utils.json_fallback")
local json = json_fallback  -- Always use fallback for table→string encoding
local http = jenova and jenova.http or nil

local OpenRouterProvider = {
    name = "openrouter",
    api_key = nil,
    base_url = "https://openrouter.ai/api/v1",
}

--- Popular models available via OpenRouter
OpenRouterProvider.models = {
    ["anthropic/claude-3.5-sonnet"] = { context = 200000, input_price = 3.0, output_price = 15.0 },
    ["openai/gpt-4o"] = { context = 128000, input_price = 2.5, output_price = 10.0 },
    ["google/gemini-2.0-flash-exp"] = { context = 1000000, input_price = 0.0, output_price = 0.0 },
    ["meta-llama/llama-3.3-70b-instruct"] = { context = 131072, input_price = 0.59, output_price = 0.79 },
    ["deepseek/deepseek-chat"] = { context = 64000, input_price = 0.14, output_price = 0.28 },
}

function OpenRouterProvider:is_available()
    local key = os.getenv("OPENROUTER_API_KEY")
    if key and key ~= "" then
        return true
    end

    if jenova.auth and jenova.auth.resolve_key then
        key = jenova.auth.resolve_key("openrouter")
        return key ~= nil and key ~= ""
    end

    return false
end

function OpenRouterProvider:initialize()
    self.api_key = os.getenv("OPENROUTER_API_KEY")

    if not self.api_key or self.api_key == "" then
        if jenova.auth and jenova.auth.resolve_key then
            self.api_key = jenova.auth.resolve_key("openrouter")
        end
    end

    if not self.api_key or self.api_key == "" then
        error("OPENROUTER_API_KEY not set")
    end
end

function OpenRouterProvider:shutdown() end

function OpenRouterProvider:supports_streaming() return true end
function OpenRouterProvider:supports_tools() return true end

function OpenRouterProvider:get_models()
    local models = {}
    for model_name, _ in pairs(self.models) do
        table.insert(models, model_name)
    end
    table.sort(models)
    return models
end

function OpenRouterProvider:generate(messages, options)
    options = options or {}

    local body = {
        model = options.model or "anthropic/claude-3.5-sonnet",
        messages = messages,
        max_tokens = options.max_tokens or 4096,
    }

    if options.temperature then
        body.temperature = options.temperature
    end

    if options.tools and #options.tools > 0 then
        -- Convert to OpenAI-compatible format
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
        ["HTTP-Referer"] = "https://github.com/orpheus497/cli-agent",
        ["X-Title"] = "Jenova CLI",
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

function OpenRouterProvider:count_tokens(text)
    return math.ceil(#text / 4)
end

function OpenRouterProvider:get_pricing(model)
    return self.models[model] or {
        context = 128000,
        input_price = 1.0,
        output_price = 3.0,
    }
end

return OpenRouterProvider
