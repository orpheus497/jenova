-- config/pricing.lua — Model pricing data (USD per million tokens)
-- Extracted from query_engine.lua for maintainability.
-- Update this file when providers change pricing or add new models.

local M = {}

M.models = {
    -- Local (free)
    ["local"] = { input = 0, output = 0 },
    ["llamacpp"] = { input = 0, output = 0 },
    -- Anthropic
    ["claude-sonnet-4-5-20250929"] = { input = 3.00, output = 15.00 },
    ["claude-opus-4-5-20251101"] = { input = 15.00, output = 75.00 },
    ["claude-3-5-sonnet-20241022"] = { input = 3.00, output = 15.00 },
    ["claude-sonnet-4-20250514"] = { input = 3.00, output = 15.00 },
    ["claude-opus-4-20250514"] = { input = 15.00, output = 75.00 },
    ["claude-haiku-3-20250307"] = { input = 0.25, output = 1.25 },
    -- OpenAI
    ["gpt-4o"] = { input = 2.50, output = 10.00 },
    ["gpt-4o-mini"] = { input = 0.15, output = 0.60 },
    ["gpt-4-turbo"] = { input = 10.00, output = 30.00 },
    -- Gemini
    ["gemini-2.0-flash-exp"] = { input = 0.075, output = 0.30 },
    ["gemini-1.5-pro"] = { input = 1.25, output = 5.00 },
    -- OpenRouter (pass-through pricing varies)
    ["openrouter/auto"] = { input = 1.00, output = 3.00 },
}

function M.get(model)
    if not model then return M.models["llamacpp"] end
    if M.models[model] then return M.models[model] end
    if model:sub(1, 1) == "/" or model == "auto" then
        return M.models["local"]
    end
    return M.models["llamacpp"]
end

return M
