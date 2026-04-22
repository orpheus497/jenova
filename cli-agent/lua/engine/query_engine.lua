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
        local ok_json, data = pcall(json_codec.parse, json_str)
        if ok_json and type(data) == "table" then
            local entry = make_tool_use(data)
            if entry then table.insert(tool_uses, entry) end
        end
    end
    if #tool_uses > 0 then return tool_uses end

    -- Stage 2b: bare JSON objects, allowing nested braces via %b{}
    for json_str in text:gmatch("%b{}") do
        local ok_json, data = pcall(json_codec.parse, json_str)
        if ok_json and type(data) == "table" then
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

    self.max_tokens = options.max_tokens or 16384
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
        if _ui and _ui.spinner_stop then _ui.spinner_stop() end
        if _ui then _ui.stream_text(text) else io.write(text); io.flush() end
    end
    self.on_thinking = options.on_thinking or function(text)
        if _ui and _ui.thinking_inline then
            self._thinking_count = (self._thinking_count or 0) + 1
            _ui.thinking_inline(self._thinking_count)
        end
    end
    self.on_tool_use = options.on_tool_use or function(tool_name, _input)
        if _ui and _ui.spinner_stop then _ui.spinner_stop() end
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

-- Converts an OpenAI-style structured result { content, tool_calls, finish_reason }
-- into the internal { text, thinking, tool_uses, stop_reason } shape used by the query loop.
function QueryEngine:handle_response(result)
    local current_text = result.content or ""
    local stop_reason = result.finish_reason or "end_turn"
    local tool_uses = {}

    if current_text and #current_text > 0 then
        self.on_text(current_text)
    end

    local tool_calls = result.tool_calls
    if tool_calls and #tool_calls > 0 then
        for idx, tc in ipairs(tool_calls) do
            local fn = tc["function"] or tc
            local name = fn.name or ""
            local args_raw = fn.arguments or fn.parameters or "{}"
            local input = type(args_raw) == "table" and args_raw
                or (json_codec.parse(args_raw) or {})
            local id = tc.id or string.format("tc-%d", idx)
            table.insert(tool_uses, { id = id, name = name, input = input })
        end
    end

    -- Stage 2 fallback: parse tool calls embedded in text content.
    -- Handles local models that emit JSON in content rather than structured tool_calls.
    if #tool_uses == 0 and current_text and #current_text > 0 then
        local extracted = parse_text_tool_calls(current_text)
        if #extracted > 0 then
            tool_uses = extracted
            current_text = ""
        end
    end

    return {
        text = current_text,
        thinking = "",
        tool_uses = tool_uses,
        stop_reason = stop_reason
    }
end

-- ── Tool Execution ────────────────────────────────────────────────────

-- Summarise tool input for display (max ~60 chars, human-readable).
local function summarise_input(tool_name, input)
    if type(input) ~= "table" then return tool_name end
    -- Pick the most meaningful field in priority order
    local keys = { "path", "file_path", "command", "query", "url", "pattern", "text", "response" }
    for _, k in ipairs(keys) do
        local v = input[k]
        if type(v) == "string" and #v > 0 then
            local short = v:sub(1, 55)
            if #v > 55 then short = short .. "…" end
            return short
        end
    end
    return tool_name
end

function QueryEngine:execute_tool(tool_name, tool_use_id, input)
    self.on_tool_use(tool_name, input, summarise_input(tool_name, input))

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
        -- Summarise input meaningfully so memory entries are human-readable.
        local input_summary
        if type(input) == "table" then
            input_summary = input.file_path or input.command or input.path
                or input.query or input.pattern or "(table)"
        else
            input_summary = tostring(input or "")
        end
        if ok and not exec_err then
            memory.record_action(tool_name, input, result, true)
        else
            local err_msg = ok and exec_err or tostring(result)
            memory.record_action(tool_name, input, err_msg, false)
            memory.log_error(tool_name, input_summary, err_msg)

            -- Embed-based self-correction: query the embedding model for similar
            -- past errors in this session and inject a targeted warning so the
            -- model can correct itself before retrying.
            -- This is non-blocking: if embed is unavailable it returns {} immediately.
            local query = tool_name .. " " .. input_summary .. " " .. err_msg
            local raw_similar = memory.get_similar_errors and memory.get_similar_errors(query, 3) or {}

            -- Filter out the just-logged error: log_error() inserted it into
            -- session_errors immediately above, so the cosine search will
            -- return it as the top hit. Match by tool + truncated args + error
            -- (the same fields formatted in the warning) instead of by `ts`,
            -- which has 1s resolution and could collide on rapid-fire calls.
            local similar = {}
            for _, se in ipairs(raw_similar) do
                local same = (se.tool == tool_name)
                    and (se.args == input_summary)
                    and (se.error == err_msg)
                if not same then
                    table.insert(similar, se)
                    if #similar >= 2 then break end
                end
            end

            if #similar > 0 then
                local parts = {"[System: Similar failures in this session — do not repeat these patterns:]"}
                for _, se in ipairs(similar) do
                    table.insert(parts, string.format(
                        "  - %s(%s): %s",
                        se.tool or "?", (se.args or ""):sub(1,40), (se.error or ""):sub(1,80)))
                end
                -- Injected directly into self.messages via the caller's loop.
                -- Store as a pending pre-action warning on self so execute_tool
                -- callers can append it after the tool_result message.
                if not self._pending_embed_warnings then
                    self._pending_embed_warnings = {}
                end
                table.insert(self._pending_embed_warnings, table.concat(parts, "\n"))
            end
        end
    end

    if not ok then
        self.on_error("Tool execution failed: " .. tostring(result))
        self.on_tool_result(tool_name, {type="error", error=tostring(result)})
        return nil, tostring(result)
    end

    if exec_err then
        self.on_error("Tool error: " .. exec_err)
        self.on_tool_result(tool_name, {type="error", error=exec_err})
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

    -- Dedup: track (tool_name, args_fingerprint) pairs to detect tight repetitive loops.
    -- After MAX_REPEATS identical calls in a row we inject a nudge instead of looping.
    local MAX_REPEATS = 2
    local last_tool_sig = nil
    local repeat_count = 0

    -- Per-file edit failure tracking: nudge the model to Read the file immediately
    -- after the FIRST failure. Waiting for a second failure lets it waste a turn.
    local edit_fail_file = nil
    local edit_fail_count = 0

    while turn_count < max_turns do
        turn_count = turn_count + 1

        -- tool_choice: "required" forces a tool call every turn so the model can't
        -- silently emit plain text. Brief is the designated "I want to reply" tool.
        -- Use "auto" only when there are no tools (avoids a bad-request error).
        local has_tools = self.tools and #self.tools > 0

        -- tool_choice: always "required" so the model must use a tool every turn.
        -- Brief is the designated exit path — the model calls Brief({response="..."})
        -- when it wants to deliver a plain-text reply to the user.
        -- Switching to "auto" lets the model short-circuit by emitting plain text
        -- directly, which causes it to fabricate answers instead of actually
        -- reading files or running shell commands.
        local tool_choice_val = has_tools and "required" or nil

        -- Prepare API request
        local request = {
            model = self.model,
            max_tokens = self.max_tokens,
            temperature = self.temperature,
            system = self.system_prompt,
            messages = self.messages,
            tools = self.tools,
            stream = true,
            tool_choice = tool_choice_val,
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
        local raw_result
        if provider_base and type(provider_base.generate_request) == "function" then
            ok, raw_result = pcall(function()
                return provider_base.generate_request(request)
            end)
        end

        if not ok then
            self.on_error("API call failed: " .. tostring(raw_result))
            return nil, tostring(raw_result)
        end

        -- Convert OpenAI result to internal shape
        local response = self:handle_response(raw_result or {})

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
        local brief_response = nil

        for _, tool_use in ipairs(response.tool_uses) do
            -- Brief is a terminal signal: the model is done and wants to reply.
            if tool_use.name == "Brief" then
                local br = type(tool_use.input) == "table" and tool_use.input.response or nil
                if br and #br > 0 then
                    -- Route through on_text so the agent label fires before the first
                    -- character — Brief responses were previously printed raw, bypassing
                    -- the label-on-first-token logic in loop.lua.
                    self.on_text(br)
                    brief_response = br
                end
                -- Don't add Brief to tool_results — terminate the loop instead.
                goto continue_loop
            end

            -- Dedup guard: detect the model calling the same tool with the same args
            -- repeatedly without making progress (common failure mode on small models).
            local sig = tool_use.name .. ":" .. json_codec.stringify(tool_use.input or {})
            if sig == last_tool_sig then
                repeat_count = repeat_count + 1
                if repeat_count >= MAX_REPEATS then
                    -- Inject a nudge into the conversation instead of running again.
                    table.insert(self.messages, {
                        role = "user",
                        content = "[System: You just called " .. tool_use.name ..
                            " with identical arguments " .. repeat_count ..
                            " times in a row. The result will not change. " ..
                            "Either move on to the next step or call Brief to report what you found.]",
                    })
                    last_tool_sig = nil
                    repeat_count = 0
                    break
                end
            else
                last_tool_sig = sig
                repeat_count = 1
            end

            local result, err = self:execute_tool(tool_use.name, tool_use.id, tool_use.input)

            -- Extract the text content from tool result table.
            -- Tools may return {type="error", error="..."} — surface that as an error
            -- so the model knows the call failed rather than seeing raw JSON.
            local result_text
            local is_err = err ~= nil
            if err then
                result_text = "Error: " .. err
            elseif type(result) == "string" then
                result_text = result
            elseif type(result) == "table" then
                if result.type == "error" then
                    is_err = true
                    result_text = "Error: " .. (result.error or "unknown error")
                else
                    result_text = result.text or result.output or result.content
                        or json_codec.stringify(result)
                end
            else
                result_text = tostring(result or "")
            end

            -- Edit-failure recovery: inject a hard nudge to Read the file on the
            -- FIRST failure so the model cannot waste a second turn guessing.
            if is_err and (tool_use.name == "Edit" or tool_use.name == "MultiEdit") then
                local fp = type(tool_use.input) == "table" and tool_use.input.file_path or ""
                if fp == edit_fail_file then
                    edit_fail_count = edit_fail_count + 1
                else
                    edit_fail_file  = fp
                    edit_fail_count = 1
                end
                if fp ~= "" then
                    -- Queue via _pending_embed_warnings so the nudge is appended
                    -- AFTER the assistant message for this turn, preserving the
                    -- required User→Assistant→User role alternation.
                    if not self._pending_embed_warnings then
                        self._pending_embed_warnings = {}
                    end
                    table.insert(self._pending_embed_warnings, string.format(
                        "[System: Edit on '%s' failed (attempt %d). " ..
                        "You MUST call Read('%s') NOW to get the exact current content. " ..
                        "Do NOT guess old_string — copy it verbatim from the Read output. " ..
                        "Do NOT call Edit again until you have called Read.]",
                        fp, edit_fail_count, fp))
                end
            elseif not is_err and (tool_use.name == "Edit" or tool_use.name == "MultiEdit") then
                -- Reset on success
                edit_fail_file  = nil
                edit_fail_count = 0
            end

            table.insert(tool_results_content, {
                type = "tool_result",
                tool_use_id = tool_use.id,
                content = result_text,
                is_error = is_err,
            })
        end

        ::continue_loop::
        -- If Brief was called, end here — the model has given its final response.
        if brief_response then
            self:add_assistant_message(brief_response)
            return {
                text = brief_response,
                thinking = response.thinking,
                stop_reason = "end_turn",
                turns = turn_count,
                usage = {
                    input_tokens = self.total_input_tokens,
                    output_tokens = self.total_output_tokens,
                    total_cost_usd = self.total_cost_usd
                }
            }
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

        -- Flush any embed-based self-correction warnings generated during this
        -- turn's tool executions. Many LLM providers (Anthropic, OpenAI) reject
        -- requests with consecutive same-role messages, and tool_results are
        -- already user-role. Append warnings to the last user message instead
        -- of inserting a new one to preserve strict role alternation.
        if self._pending_embed_warnings and #self._pending_embed_warnings > 0 then
            local warning_text = table.concat(self._pending_embed_warnings, "\n\n")
            local last_msg = self.messages[#self.messages]
            if last_msg and last_msg.role == "user" then
                if type(last_msg.content) == "string" then
                    last_msg.content = last_msg.content .. "\n\n" .. warning_text
                elseif type(last_msg.content) == "table" then
                    table.insert(last_msg.content, { type = "text", text = warning_text })
                else
                    last_msg.content = warning_text
                end
            else
                table.insert(self.messages, { role = "user", content = warning_text })
            end
            self._pending_embed_warnings = {}
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
