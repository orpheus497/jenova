-- providers/llamacpp.lua — llama.cpp provider (PRIMARY AI backend)
-- Uses local GGUF models via the jenova_llama FFI

local json = jenova.json or require("utils.json_fallback")

local LlamaCppProvider = {
    name = "llamacpp",
    loaded_model_id = nil,
    current_model_path = nil,
    config = {
        context_size = 8192,
        threads = nil, -- nil = auto-detect
        gpu_layers = 99, -- Offload all layers to GPU if available
        temperature = 0.7,
    },
}

--- Check if llama.cpp bindings are available
--- @return boolean available
function LlamaCppProvider:is_available()
    -- Check if C FFI bindings are available
    local ok, llama = pcall(function() return jenova.llama end)
    if not ok or not llama then
        return false
    end

    -- Check if we have the required functions
    return type(llama.load_model) == "function" and
           type(llama.generate) == "function"
end

--- Initialize the provider
function LlamaCppProvider:initialize()
    if not self:is_available() then
        error("llama.cpp FFI not available")
    end

    -- Nothing to initialize globally for llama.cpp
    -- Models are loaded on-demand
end

--- Shutdown the provider
function LlamaCppProvider:shutdown()
    self:unload_model()
end

--- Check if streaming is supported
--- @return boolean supported
function LlamaCppProvider:supports_streaming()
    -- Streaming is supported via callback mechanism
    return true
end

--- Check if tool calling is supported
--- @return boolean supported
function LlamaCppProvider:supports_tools()
    -- Tool calling supported via prompt engineering
    return true
end

--- Load a model
--- @param model_path string Path to GGUF model file
--- @param config table|nil Optional model configuration
--- @return boolean success
function LlamaCppProvider:load_model(model_path, config)
    -- Unload current model if any
    if self.loaded_model_id then
        self:unload_model()
    end

    -- Merge config with defaults
    local model_config = {}
    for k, v in pairs(self.config) do
        model_config[k] = v
    end
    if config then
        for k, v in pairs(config) do
            model_config[k] = v
        end
    end

    -- Load model via FFI
    local config_json = json.stringify(model_config)
    local model_id = jenova.llama.load_model(model_path, config_json)

    if model_id == 0 then
        return false, string.format("Failed to load model: %s", model_path)
    end

    self.loaded_model_id = model_id
    self.current_model_path = model_path

    return true
end

--- Unload the current model
function LlamaCppProvider:unload_model()
    if self.loaded_model_id then
        jenova.llama.unload_model(self.loaded_model_id)
        self.loaded_model_id = nil
        self.current_model_path = nil
    end
end

--- Find and load a model by name
--- @param model_name string Model name (supports partial matching)
--- @param config table|nil Optional model configuration
--- @return boolean success
function LlamaCppProvider:find_and_load_model(model_name, config)
    local model_path = jenova.llama.find_model(model_name)
    if not model_path then
        return false, string.format("Model not found: %s", model_name)
    end

    return self:load_model(model_path, config)
end

--- Get list of available models
--- @return table models List of model names
function LlamaCppProvider:get_models()
    local models_json = jenova.llama.list_models()
    if not models_json then
        return {}
    end

    local ok, models = pcall(json.parse, models_json)
    if not ok then
        return {}
    end

    return models
end

--- Format messages into a prompt
--- Uses Llama3/ChatML-style formatting
--- @param messages table Array of message objects
--- @return string prompt Formatted prompt
function LlamaCppProvider:format_prompt(messages, tools)
    local prompt = ""

    -- Add system message with tools if provided
    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            prompt = prompt .. "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
            prompt = prompt .. msg.content

            -- Add tools to system prompt
            if tools and #tools > 0 then
                prompt = prompt .. "\n\nYou have access to the following tools:\n\n"
                for _, tool in ipairs(tools) do
                    prompt = prompt .. string.format("Tool: %s\n", tool.name)
                    prompt = prompt .. string.format("Description: %s\n", tool.description)
                    if tool.input_schema then
                        prompt = prompt .. string.format("Parameters: %s\n\n", json.stringify(tool.input_schema))
                    end
                end
                prompt = prompt .. "\nTo use a tool, respond with a JSON block:\n"
                prompt = prompt .. "```json\n{\"tool\": \"tool_name\", \"parameters\": {...}}\n```\n"
            end

            prompt = prompt .. "<|eot_id|>"
            break
        end
    end

    -- Add conversation messages
    for _, msg in ipairs(messages) do
        if msg.role == "user" then
            prompt = prompt .. "<|start_header_id|>user<|end_header_id|>\n\n"
            prompt = prompt .. msg.content .. "<|eot_id|>"
        elseif msg.role == "assistant" then
            prompt = prompt .. "<|start_header_id|>assistant<|end_header_id|>\n\n"
            prompt = prompt .. (type(msg.content) == "string" and msg.content or "") .. "<|eot_id|>"
        end
    end

    -- Add assistant prefix to trigger response
    prompt = prompt .. "<|start_header_id|>assistant<|end_header_id|>\n\n"

    return prompt
end

--- Generate a completion
--- @param messages table Array of message objects {role, content}
--- @param options table Generation options
--- @return string|nil response Generated text
function LlamaCppProvider:generate(messages, options)
    options = options or {}

    -- Ensure a model is loaded
    if not self.loaded_model_id then
        local override = os.getenv("JENOVA_MODEL")
        if override and override ~= "" then
            local ok, err = self:load_model(override)
            if not ok then return nil, err end
        else
            local models = self:get_models()
            if #models == 0 then
                local dirs = self:get_models_dirs()
                return nil, "No models available. Place a GGUF model in: " .. table.concat(dirs, ", ")
            end
            local ok, err = self:find_and_load_model(models[1])
            if not ok then return nil, err end
        end
    end

    -- Format prompt
    local prompt = self:format_prompt(messages, options.tools)

    -- Build generation parameters
    local params = {
        max_tokens = options.max_tokens or 4096,
        temperature = options.temperature or self.config.temperature,
        top_p = options.top_p or 0.95,
        top_k = options.top_k or 40,
    }

    local params_json = json.stringify(params)

    -- Generate
    local response = jenova.llama.generate(self.loaded_model_id, prompt, params_json)
    if not response then
        return nil, "Generation failed"
    end

    -- Parse tool calls if present
    if options.tools and #options.tools > 0 then
        -- Check if response contains tool call
        local tool_call_start = response:find("```json")
        if tool_call_start then
            -- Extract and return tool call info
            -- This would be handled by the query engine
        end
    end

    return response
end

--- Count tokens in text
--- @param text string Text to tokenize
--- @return number|nil count Token count
function LlamaCppProvider:count_tokens(text)
    if not self.loaded_model_id then
        -- Rough estimate: ~4 chars per token
        return math.ceil(#text / 4)
    end

    return jenova.llama.count_tokens(self.loaded_model_id, text)
end

--- Get pricing (free for local models)
--- @param model string Model name
--- @return table pricing Pricing info
function LlamaCppProvider:get_pricing(model)
    return {
        input_price = 0,
        output_price = 0,
        currency = "USD",
        per_tokens = 1000000,
    }
end

--- Get models directories in priority order
--- @return table paths List of model directory paths to search
function LlamaCppProvider:get_models_dirs()
    local dirs = {}

    local ok, config = pcall(require, "config.loader")
    if ok then
        local cfg_dir = config.get("models_dir")
        if cfg_dir then table.insert(dirs, cfg_dir) end
    end

    local jenova_root = os.getenv("JENOVA_ROOT")
    if jenova_root and jenova_root ~= "" then
        table.insert(dirs, jenova_root .. "/models")
        table.insert(dirs, jenova_root .. "/models/agent")
    end

    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home then
        table.insert(dirs, home .. "/.local/share/cli-agent/models")
    end

    return dirs
end

--- Get primary models directory (for backward compat)
--- @return string path Models directory path
function LlamaCppProvider:get_models_dir()
    local dirs = self:get_models_dirs()
    if #dirs > 0 then return dirs[1] end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    return home .. "/.local/share/cli-agent/models"
end

return LlamaCppProvider
