-- providers/gemini.lua — Google Gemini API provider
-- Supports Gemini 2.0 and other Google models

local json_fallback = require("utils.json_fallback")
local json = json_fallback  -- Always use fallback for table→string encoding
local http = jenova and jenova.http or nil

local GeminiProvider = {
    name = "gemini",
    api_key = nil,
    base_url = nil,
}

--- Model pricing (USD per 1M tokens)
GeminiProvider.models = {
    ["gemini-2.0-flash-exp"] = { context = 1000000, input_price = 0.0, output_price = 0.0 }, -- Free tier
    ["gemini-1.5-pro"] = { context = 2000000, input_price = 1.25, output_price = 5.0 },
    ["gemini-1.5-flash"] = { context = 1000000, input_price = 0.075, output_price = 0.3 },
}

function GeminiProvider:is_available()
    local key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if key and key ~= "" then
        return true
    end

    if jenova.auth and jenova.auth.resolve_key then
        key = jenova.auth.resolve_key("gemini")
        return key ~= nil and key ~= ""
    end

    return false
end

function GeminiProvider:initialize()
    self.api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    self.base_url = os.getenv("GEMINI_BASE_URL") or "https://generativelanguage.googleapis.com/v1beta"

    if not self.api_key or self.api_key == "" then
        if jenova.auth and jenova.auth.resolve_key then
            self.api_key = jenova.auth.resolve_key("gemini")
        end
    end

    if not self.api_key or self.api_key == "" then
        error("GEMINI_API_KEY or GOOGLE_API_KEY not set")
    end
end

function GeminiProvider:shutdown() end

function GeminiProvider:supports_streaming() return true end
function GeminiProvider:supports_tools() return true end

function GeminiProvider:get_models()
    local models = {}
    for model_name, _ in pairs(self.models) do
        table.insert(models, model_name)
    end
    table.sort(models)
    return models
end

function GeminiProvider:generate(messages, options)
    options = options or {}

    local model = options.model or "gemini-2.0-flash-exp"

    -- Convert messages to Gemini format
    local contents = {}
    for _, msg in ipairs(messages) do
        if msg.role ~= "system" then
            table.insert(contents, {
                role = msg.role == "assistant" and "model" or "user",
                parts = {{ text = msg.content }}
            })
        end
    end

    local body = {
        contents = contents,
        generationConfig = {
            maxOutputTokens = options.max_tokens or 8192,
        }
    }

    if options.temperature then
        body.generationConfig.temperature = options.temperature
    end

    local url = string.format("%s/models/%s:generateContent?key=%s",
        self.base_url, model, self.api_key)

    local headers = {
        ["Content-Type"] = "application/json",
    }

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

    if parsed.candidates and #parsed.candidates > 0 then
        local candidate = parsed.candidates[1]
        if candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
            return candidate.content.parts[1].text
        end
    end

    return nil, "No content in response"
end

function GeminiProvider:count_tokens(text)
    return math.ceil(#text / 4)
end

function GeminiProvider:get_pricing(model)
    return self.models[model] or {
        context = 1000000,
        input_price = 0.075,
        output_price = 0.3,
    }
end

return GeminiProvider
