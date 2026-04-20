-- providers/init.lua — Provider registry initialization
-- Registers all available LLM providers.
--
-- Provider priority:
--   jenova_backend (Jenova cognitive architecture, proxy.lua :8080)
--     → llamacpp (local in-process llama.cpp)
--     → anthropic → openai → gemini → openrouter
--
-- When the Jenova backend is running on the workstation, cli-agent prefers
-- routing through `proxy.lua` to get hybrid BM25 + semantic RAG and shared
-- session memory. If the proxy is not reachable, it falls back to the local
-- in-process llamacpp provider, and finally to cloud providers.

local base = require("providers.base")

local M = {}

-- Load and register all providers
local function init_providers()
    -- Load each provider with graceful degradation
    local providers_to_load = {
        { name = "jenova_backend", module = "providers.jenova_backend" },
        { name = "llamacpp",       module = "providers.llamacpp" },
        { name = "anthropic",      module = "providers.anthropic" },
        { name = "openai",         module = "providers.openai" },
        { name = "gemini",         module = "providers.gemini" },
        { name = "openrouter",     module = "providers.openrouter" },
    }

    for _, p in ipairs(providers_to_load) do
        local ok, provider = pcall(require, p.module)
        if ok then
            base.register(p.name, provider)
        end
    end
end

function M.init()
    init_providers()

    -- Initialize the provider manager with config
    local ok, config = pcall(require, "config.loader")
    if ok then
        local provider_name = config.get("provider") or "jenova_backend"
        base.set_primary(provider_name)
        base.set_fallback_enabled(config.get("fallback_enabled") ~= false)
    end
end

-- Re-export base functions for convenience
M.generate = base.generate
M.count_tokens = base.count_tokens
M.get_provider = base.get
M.list_providers = base.list
M.set_primary = base.set_primary

return M
