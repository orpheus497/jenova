-- query_engine.lua — Core LLM conversation loop
-- Equivalent to src/QueryEngine.ts in the TypeScript codebase
-- Handles:
-- 1. Message streaming via provider system (llama.cpp primary, cloud fallback)
-- 2. Tool execution loop
-- 3. Thinking mode
-- 4. Token counting and cost tracking
-- 5. Retry logic and error handling

-- jenova.json is a validator (string→validated string); use json_fallback
-- whenever we need real Lua table ↔ JSON conversion.
local json_codec = require("utils.json_fallback")
local tool_registry = require("tools.registry")
local array = require("utils.array")

-- Try to load provider system
local provider_base
do
    local ok, mod = pcall(require, "providers.base")
    if ok then
        provider_base = mod
    end
end

-- ── Text Tool Call Parser ─────────────────────────────────────────────
-- Stage 2 fallback: extracts tool calls embedded in plain text.
-- Used when local models (Qwen2.5-Coder, etc.) emit JSON in content
-- rather than structured tool_use blocks.

-- Monotonic process-scoped counter guarantees every synthesized tool-use
-- id is unique, with no reliance on os.time() resolution or RNG seeding.
local txt_tool_counter = 0

local function make_tool_use(data)
    local name = data.tool or data.tool_name or data.name or data.function_name
    if type(name) ~= "string" or not tool_registry.get_tool(name) then
        return nil
    end
    local input = data.parameters or data.arguments or data.input or data.params or {}
    txt_tool_counter = txt_tool_counter + 1
    return {
        id = string.format("txt-%d", txt_tool_counter),
        name = name,
        input = input,
    }
end

local function parse_text_tool_calls(text)
    local tool_uses = {}

    -- Stage 2a: JSON code fences  ```json\n{...}\n```
    for json_str in text:gmatch("```json%s*\n?(.-)\n?```") do
        local data = json_codec.parse(json_str)
        if type(data) == "table" then
            local entry = make_tool_use(data)
            if entry then table.insert(tool_uses, entry) end
        end
    end
    if #tool_uses > 0 then return tool_uses end

    -- Stage 2b: bare JSON objects, allowing nested braces via %b{}
    for json_str in text:gmatch("%b{}") do
        local data = json_codec.parse(json_str)
        if type(data) == "table" then
            local entry = make_tool_use(data)
            if entry then table.insert(tool_uses, entry) end
        end
    end

    return tool_uses
end

local QueryEngine = {}
QueryEngine.__index = QueryEngine

-- ── Constructor ───────────────────────────────────────────────────────

function QueryEngine.new(options)
    local self = setmetatable({}, QueryEngine)

    -- Provider selection: llama.cpp is primary, cloud APIs are fallback
    self.provider = options.provider or nil  -- nil = auto-detect via provider system
    self.model = options.model or nil        -- nil = use provider default

    -- If no model specified, try to resolve from config
    if not self.model then
        local ok, config = pcall(require, "config.loader")
        if ok then
            local provider_name = config.get("provider") or "jenova_backend"
            if provider_name == "llamacpp" then
                self.model = config.get("llamacpp_model") or "auto"
            else
                self.model = "auto"
            end
        else
            self.model = "auto"
        end
    end

    self.max_tokens = options.max_tokens or 8192
    self.thinking_enabled = options.thinking_enabled or false
    self.temperature = options.temperature or 1.0
    self.system_prompt = options.system_prompt or ""
    self.tools = options.tools or tool_registry.build_api_tools()
    self.can_use_tool = options.can_use_tool or function() return true end

    -- Default callbacks use agent.ui if available for polished terminal output
    local _ui = nil
    do
        local _ok, _mod = pcall(require, "agent.ui")
        if _ok then _ui = _mod end
    end

    self.on_text = options.on_text or function(text)
        if _ui then _ui.stream_text(text) else io.write(text); io.flush() end
    end
    self.on_thinking = options.on_thinking or function(text)
        if _ui and _ui.thinking_inline then
            self._thinking_count = (self._thinking_count or 0) + 1
            _ui.thinking_inline(self._thinking_count)
        end
    end
    self.on_tool_use = options.on_tool_use or function(tool_name, _input)
        if _ui and _ui.tool_badge then _ui.tool_badge(tool_name, "running")
        elseif _ui then _ui.status_info(tool_name .. " running") end
    end
    self.on_tool_result = options.on_tool_result or function(tool_name, _result)
        if _ui and _ui.tool_badge then _ui.tool_badge(tool_name, "done") end
    end
    self.on_error = options.on_error or function(err)
        if _ui and _ui.status_err then _ui.status_err(tostring(err))
        else io.stderr:write("Error: " .. tostring(err) .. "\n") end
    end

    self.messages = {}
    self.total_input_tokens = 0
    self.total_output_tokens = 0
    self.total_cost_usd = 0
    self.abort_controller = nil

    return self
end

-- ── Message Management ────────────────────────────────────────────────

function QueryEngine:add_user_message(content)
    table.insert(self.messages, {
        role = "user",
        content = content
    })
end

function QueryEngine:add_assistant_message(content)
    table.insert(self.messages, {
        role = "assistant",
        content = content
    })
end

function QueryEngine:add_tool_result(tool_use_id, result, is_error)
    table.insert(self.messages, {
        role = "user",
        content = {
            {
                type = "tool_result",
                tool_use_id = tool_use_id,
                content = result,
                is_error = is_error or false
            }
        }
    })
end

-- ── Streaming Response Handler ────────────────────────────────────────

function QueryEngine:handle_streaming_response(response_stream)
    local current_text = ""
    local current_thinking = ""
    local tool_uses = {}
    local stop_reason = nil

    for event in response_stream do
        if event.type == "message_start" then
            -- Track usage from message start
            if event.message and event.message.usage then
                self.total_input_tokens = self.total_input_tokens + (event.message.usage.input_tokens or 0)
            end

        elseif event.type == "content_block_start" then
            local block = event.content_block
            if block.type == "text" then
                current_text = ""
            elseif block.type == "thinking" then
                current_thinking = ""
            elseif block.type == "tool_use" then
                table.insert(tool_uses, {
                    id = block.id,
                    name = block.name,
                    input = {}
                })
            end

        elseif event.type == "content_block_delta" then
            local delta = event.delta
            if delta.type == "text_delta" then
                current_text = current_text .. delta.text
                self.on_text(delta.text)
            elseif delta.type == "thinking_delta" then
                current_thinking = current_thinking .. delta.thinking
                if self.thinking_enabled then
                    self.on_thinking(delta.thinking)
                end
            elseif delta.type == "input_json_delta" then
                -- Accumulate tool input JSON
                local last_tool = tool_uses[#tool_uses]
                if last_tool then
                    last_tool.input_json = (last_tool.input_json or "") .. delta.partial_json
                end
            end

        elseif event.type == "content_block_stop" then
            -- Finalize the current block
            if #tool_uses > 0 then
                local last_tool = tool_uses[#tool_uses]
                if last_tool.input_json then
                    last_tool.input = json_codec.parse(last_tool.input_json) or {}
                    last_tool.input_json = nil
                end
            end

        elseif event.type == "message_delta" then
            if event.delta and event.delta.stop_reason then
                stop_reason = event.delta.stop_reason
            end
            if event.usage then
                self.total_output_tokens = self.total_output_tokens + (event.usage.output_tokens or 0)
            end

        elseif event.type == "message_stop" then
            -- Final message stop
            break
        end
    end

    -- Stage 2 fallback: parse tool calls embedded in text content.
    -- Handles local models that emit JSON in content rather than tool_use blocks.
    if #tool_uses == 0 and #current_text > 0 then
        local extracted = parse_text_tool_calls(current_text)
        if #extracted > 0 then
            tool_uses = extracted
            current_text = ""
        end
    end

    return {
        text = current_text,
        thinking = current_thinking,
        tool_uses = tool_uses,
        stop_reason = stop_reason
    }
end

-- ── Tool Execution ────────────────────────────────────────────────────

function QueryEngine:execute_tool(tool_name, tool_use_id, input)
    self.on_tool_use(tool_name, input)

    -- Build context for the tool (cwd, session info, etc.)
    local app_state_ok, app_state = pcall(require, "state.app_state")
    local tool_context = {
        cwd = app_state_ok and app_state.get_cwd() or nil,
    }

    -- Get tool implementation (verify it exists before execute)
    local tool = tool_registry.get_tool(tool_name)
    if not tool then
        return nil, "Unknown tool: " .. tool_name
    end

    -- Execute tool via the registry's execute() helper, which handles
    -- permission checks via tool.check_permissions() — single enforcement point.
    local ok, result, exec_err = pcall(tool_registry.execute, tool_name, input, tool_context)

    -- Record action in memory manager
    local mem_ok, memory = pcall(require, "services.memory.manager")
    if mem_ok then
        if ok and not exec_err then
            memory.record_action(tool_name, input, result, true)
        else
            local err_msg = ok and exec_err or tostring(result)
            memory.record_action(tool_name, input, err_msg, false)
            memory.log_error(tool_name, tostring(input), err_msg)
        end
    end

    if not ok then
        self.on_error("Tool execution failed: " .. tostring(result))
        return nil, tostring(result)
    end

    if exec_err then
        self.on_error("Tool error: " .. exec_err)
        return nil, exec_err
    end

    self.on_tool_result(tool_name, result)
    return result, nil
end

-- ── Main Query Loop ───────────────────────────────────────────────────

function QueryEngine:query(user_message, options)
    options = options or {}
    local max_turns = options.max_turns or 25
    local turn_count = 0

    -- Add user message
    self:add_user_message(user_message)

    while turn_count < max_turns do
        turn_count = turn_count + 1

        -- Prepare API request
        local request = {
            model = self.model,
            max_tokens = self.max_tokens,
            temperature = self.temperature,
            system = self.system_prompt,
            messages = self.messages,
            tools = self.tools,
            stream = true
        }

        -- Enrich system prompt with memory context (errors, actions, plan)
        local mem_ok, memory = pcall(require, "services.memory.manager")
        if mem_ok then
            local context = memory.build_context(user_message)
            if context and #context > 0 then
                request.system = (request.system or "") .. "\n" .. context
            end
        end

        if self.thinking_enabled then
            request.thinking = {
                type = "enabled",
                budget_tokens = 2000
            }
        end

        -- Call provider system (llama.cpp primary, jenova_backend)
        local ok = false
        local response_stream
        if provider_base and type(provider_base.create_message_stream) == "function" then
            ok, response_stream = pcall(function()
                return provider_base.create_message_stream(request)
            end)
        end

        if not ok then
            self.on_error("API call failed: " .. tostring(response_stream))
            return nil, tostring(response_stream)
        end

        -- Handle streaming response
        local response = self:handle_streaming_response(response_stream)

        -- Update cost tracking
        self:update_cost()

        -- If no tool uses, we're done
        if #response.tool_uses == 0 then
            if response.text and #response.text > 0 then
                self:add_assistant_message(response.text)
            end
            return {
                text = response.text,
                thinking = response.thinking,
                stop_reason = response.stop_reason,
                turns = turn_count,
                usage = {
                    input_tokens = self.total_input_tokens,
                    output_tokens = self.total_output_tokens,
                    total_cost_usd = self.total_cost_usd
                }
            }
        end

        -- Execute tools
        local tool_results_content = {}
        for _, tool_use in ipairs(response.tool_uses) do
            local result, err = self:execute_tool(tool_use.name, tool_use.id, tool_use.input)

            if err then
                table.insert(tool_results_content, {
                    type = "tool_result",
                    tool_use_id = tool_use.id,
                    content = "Error: " .. err,
                    is_error = true
                })
            else
                table.insert(tool_results_content, {
                    type = "tool_result",
                    tool_use_id = tool_use.id,
                    content = type(result) == "string" and result or json_codec.stringify(result),
                    is_error = false
                })
            end
        end

        -- Add all tool uses from this turn as one assistant message.
        -- Include any text the model emitted before/alongside tool calls.
        local assistant_content = {}
        if response.text and #response.text > 0 then
            table.insert(assistant_content, {
                type = "text",
                text = response.text,
            })
        end
        for _, tool_use in ipairs(response.tool_uses) do
            table.insert(assistant_content, {
                type  = "tool_use",
                id    = tool_use.id,
                name  = tool_use.name,
                input = tool_use.input,
            })
        end
        table.insert(self.messages, { role = "assistant", content = assistant_content })

        -- Add tool results
        for _, tool_result in ipairs(tool_results_content) do
            self:add_tool_result(tool_result.tool_use_id, tool_result.content, tool_result.is_error)
        end

        -- Continue the loop
    end

    return nil, "Max turns exceeded"
end

-- ── Cost Tracking ─────────────────────────────────────────────────────

function QueryEngine:update_cost()
    local ok, pricing_mod = pcall(require, "config.pricing")
    local model_pricing
    if ok and pricing_mod and pricing_mod.get then
        model_pricing = pricing_mod.get(self.model)
    else
        model_pricing = { input = 0, output = 0 }
    end

    local input_cost = (self.total_input_tokens / 1000000) * model_pricing.input
    local output_cost = (self.total_output_tokens / 1000000) * model_pricing.output

    self.total_cost_usd = input_cost + output_cost
end

function QueryEngine:get_usage()
    return {
        input_tokens = self.total_input_tokens,
        output_tokens = self.total_output_tokens,
        total_cost_usd = self.total_cost_usd
    }
end

-- ── Abort Control ─────────────────────────────────────────────────────

function QueryEngine:abort()
    if self.abort_controller then
        self.abort_controller.abort()
    end
end

return QueryEngine
