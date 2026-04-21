-- providers/base.lua — Base provider interface for LLM backends
-- Defines the common interface that all providers (llama.cpp, Anthropic, etc.) must implement.
--
-- llama.cpp is the PRIMARY provider for local, private, zero-cost inference.
-- Cloud providers (Anthropic, OpenAI, Gemini, OpenRouter) are SECONDARY fallback.

local M = {}

--- Provider interface (all providers must implement these methods)
--- @class Provider
--- @field name string Provider name (e.g., "llamacpp", "anthropic", "openai")
--- @field initialize function() Initialize the provider
--- @field shutdown function() Cleanup provider resources
--- @field is_available function() Check if provider is available
--- @field supports_streaming function() Whether provider supports streaming
--- @field supports_tools function() Whether provider supports tool calling
--- @field generate function(messages, options) Generate a completion
--- @field count_tokens function(text) Count tokens in text
--- @field get_models function() List available models
--- @field get_pricing function(model) Get pricing info for model

--- Provider registry
local providers = {}

--- Global manager state
local primary_provider_name = "jenova_backend"
local fallback_enabled = true
local default_manager = nil

--- Register a provider
--- @param name string Provider name
--- @param provider table Provider implementation
function M.register(name, provider)
    -- Validate provider implements required methods
    local required = {
        "initialize",
        "is_available",
        "generate",
    }

    for _, method in ipairs(required) do
        if type(provider[method]) ~= "function" then
            error(string.format("Provider '%s' missing required method: %s", name, method))
        end
    end

    providers[name] = provider
end

--- Get a provider by name
--- @param name string Provider name
--- @return table|nil provider Provider implementation or nil
function M.get(name)
    return providers[name]
end

--- List all registered providers
--- @return table providers List of provider names
function M.list()
    local list = {}
    for name, _ in pairs(providers) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

--- Set the primary provider
--- @param name string Provider name
function M.set_primary(name)
    primary_provider_name = name
    -- Reset default manager so it re-initializes with new primary
    default_manager = nil
end

--- Set whether fallback is enabled
--- @param enabled boolean Whether fallback should be used
function M.set_fallback_enabled(enabled)
    fallback_enabled = enabled
end

--- Find the best available provider
--- Tries providers in priority order: llamacpp (primary), then cloud providers
--- @return string|nil provider_name Name of available provider or nil
function M.find_available()
    -- Build priority list with the primary provider always first
    local base_priority = {"jenova_backend", "llamacpp"}
    local priority = {}
    local seen = {}

    -- Primary first
    priority[1] = primary_provider_name
    seen[primary_provider_name] = true

    -- Then the rest in default order, skipping the primary
    for _, name in ipairs(base_priority) do
        if not seen[name] then
            table.insert(priority, name)
            seen[name] = true
        end
    end

    for _, name in ipairs(priority) do
        local provider = providers[name]
        if provider and provider:is_available() then
            return name
        end
    end

    return nil
end

--- Create a unified provider manager
--- @param preferred_provider string|nil Preferred provider name (optional)
--- @return table manager Provider manager instance
function M.create_manager(preferred_provider)
    local manager = {
        current_provider = nil,
        fallback_enabled = fallback_enabled,
    }

    --- Initialize manager with a provider
    --- @param name string Provider name
    --- @return boolean success Whether initialization succeeded
    function manager:initialize(name)
        local provider = M.get(name)
        if not provider then
            return false, string.format("Provider not found: %s", name)
        end

        if not provider:is_available() then
            return false, string.format("Provider not available: %s", name)
        end

        local ok, err = pcall(function() provider:initialize() end)
        if not ok then
            return false, string.format("Provider initialization failed: %s", err)
        end

        self.current_provider = provider
        return true
    end

    --- Get current provider name
    --- @return string|nil name Provider name or nil
    function manager:get_provider_name()
        if not self.current_provider then
            return nil
        end

        return self.current_provider.name
    end

    --- Generate completion using current or fallback provider
    --- @param messages table Messages array or string prompt
    --- @param options table Generation options
    --- @return string|nil response Generated response
    function manager:generate(messages, options)
        if not self.current_provider then
            -- Auto-initialize with best available provider
            local provider_name = preferred_provider or primary_provider_name or M.find_available()
            if not provider_name then
                return nil, "No providers available"
            end

            local ok, err = self:initialize(provider_name)
            if not ok then
                if not self.fallback_enabled then
                    return nil, err
                end

                -- Try fallback providers
                local tried = { [provider_name] = true }
                local priority = {"jenova_backend", "llamacpp"}
                for _, name in ipairs(priority) do
                    if not tried[name] then
                        ok, err = self:initialize(name)
                        if ok then
                            break
                        end
                        tried[name] = true
                    end
                end

                if not ok then
                    return nil, "All providers failed to initialize"
                end
            end
        end

        -- Try generation with current provider
        local ok, result, gen_err = pcall(function()
            return self.current_provider:generate(messages, options)
        end)

        if ok and result then
            return result
        end

        local error_msg = (not ok) and tostring(result) or gen_err

        -- If generation failed and fallback is enabled, try other providers
        if self.fallback_enabled then
            local current_name = self.current_provider.name
            local priority = {"jenova_backend", "llamacpp"}
            for _, name in ipairs(priority) do
                if name ~= current_name then
                    local ok_init, _ = self:initialize(name)
                    if ok_init then
                        local fb_ok, fb_result = pcall(function()
                            return self.current_provider:generate(messages, options)
                        end)
                        if fb_ok and fb_result then
                            io.stderr:write(string.format("Note: Using fallback provider '%s'\n", name))
                            return fb_result
                        end
                    end
                end
            end
        end

        return nil, string.format("Generation failed: %s", tostring(error_msg or result))
    end

    --- Count tokens
    --- @param text string Text to tokenize
    --- @return number|nil count Token count or nil
    function manager:count_tokens(text)
        if not self.current_provider then
            return nil, "No provider initialized"
        end

        if type(self.current_provider.count_tokens) ~= "function" then
            -- Fallback: estimate ~4 chars per token
            return math.ceil(#text / 4)
        end

        return self.current_provider:count_tokens(text)
    end

    --- Shutdown manager and current provider
    function manager:shutdown()
        if self.current_provider and type(self.current_provider.shutdown) == "function" then
            pcall(function() self.current_provider:shutdown() end)
        end
        self.current_provider = nil
    end

    return manager
end

--- Get or create the default manager singleton
local function get_default_manager()
    if not default_manager then
        default_manager = M.create_manager(primary_provider_name)
    end
    return default_manager
end

--- Module-level generate (uses default manager)
--- @param prompt string|table Prompt string or messages array
--- @param options table|nil Generation options
--- @return string|nil response Generated text
--- @return string|nil error Error message if failed
function M.generate(prompt, options)
    local mgr = get_default_manager()
    return mgr:generate(prompt, options)
end

--- Module-level count_tokens (uses default manager)
--- @param text string Text to tokenize
--- @return number|nil count Token count
function M.count_tokens(text)
    local mgr = get_default_manager()
    return mgr:count_tokens(text)
end

--- Generate a completion and return structured result directly (no event bus).
--- Returns { content, tool_calls, finish_reason } or raises on error.
--- tool_calls is an OpenAI-format array: [{id, type, function={name, arguments}}]
--- @param request table Full API request (messages, model, tools, tool_choice, etc.)
--- @return table result Structured result with content/tool_calls/finish_reason
function M.generate_request(request)
    local mgr = get_default_manager()
    local result, err = mgr:generate(request.messages, {
        model = request.model,
        max_tokens = request.max_tokens,
        temperature = request.temperature,
        system_prompt = request.system,
        tools = request.tools,
        tool_choice = request.tool_choice,
    })

    if not result then
        error(err or "Generation failed")
    end

    if type(result) == "table" then
        return result
    end

    return { content = tostring(result), tool_calls = nil, finish_reason = "end_turn" }
end

return M
