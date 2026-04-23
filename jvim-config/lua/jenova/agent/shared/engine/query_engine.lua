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
local paths = require("utils.paths")
local mem_ok, memory = pcall(require, "services.memory.manager")

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

    -- File read cache: stores the content of files read during this session.
    -- Key: resolved absolute path. Value: { text, ts, num_lines }
    -- Used to:
    --   1. Detect redundant re-reads (same path, no intervening write) and skip the I/O.
    --   2. Inject cached content as a hint when an Edit/MultiEdit fails with "not found".
    self._file_cache = {}

    -- Git-like file state tracker — records mtime+size+hash on every read/write
    -- so the cache knows reliably when disk content has changed.
    local ft_ok, ft = pcall(require, "context.file_tracker")
    self._file_tracker = ft_ok and ft or nil

    -- Load verifier once — it holds per-session attempt counters.
    local v_ok, verifier = pcall(require, "services.tool_verifier")
    self._verifier = (v_ok and verifier) or nil

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
    -- OpenAI-native shape: role="tool", tool_call_id, content=string.
    -- is_error is signalled by prefixing the content with [ERROR] so the
    -- model can see the failure status without needing a sidecar field.
    local content = tostring(result or "")
    if is_error then content = "[ERROR] " .. content end
    table.insert(self.messages, {
        role = "tool",
        tool_call_id = tool_use_id,
        content = content,
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

function QueryEngine:_cache_file_read(path, text, num_lines, truncated)
    self._file_cache[path] = { text = text, num_lines = num_lines, ts = os.time(), truncated = truncated }
    if self._file_tracker then
        self._file_tracker.record_read(path, text)
    end
end

function QueryEngine:_invalidate_cache(path)
    self._file_cache[path] = nil
    if self._file_tracker then
        self._file_tracker.invalidate(path)
    end
end

function QueryEngine:execute_tool(tool_name, tool_use_id, input)
    self.on_tool_use(tool_name, input, summarise_input(tool_name, input))

    -- Build context for the tool (cwd, session info, etc.)
    local app_state_ok, app_state = pcall(require, "state.app_state")
    local tool_context = {
        cwd = app_state_ok and app_state.get_cwd() or nil,
    }

    -- ── File-read deduplication ────────────────────────────────────────
    -- If the model is calling Read on a file it already read with no
    -- intervening write/edit, return the cached result instantly.
    -- This breaks the "read the same file 4 times" loop without any prompt
    -- changes, and ensures the model always has current content.
    if tool_name == "Read" and type(input) == "table" and input.file_path then
        local resolved = paths.resolve(input.file_path, tool_context.cwd)
        local cached = self._file_cache[resolved]
        -- Return from cache ONLY when:
        --   1. We have a cached entry for this path.
        --   2. Not a partial read (no offset).
        --   3. The file has NOT changed on disk since we last read it
        --      (checked via file_tracker mtime+size; if tracker unavailable,
        --       fall through to a fresh read so we never serve stale content).
        local disk_stale = not self._file_tracker or self._file_tracker.is_stale(resolved)
        if cached and not cached.truncated and not (input.offset and input.offset > 0) and not disk_stale then
            self.on_tool_result(tool_name, { type = "text", text = cached.text,
                num_lines = cached.num_lines })
            return { type = "text", text = cached.text,
                     num_lines = cached.num_lines, _from_cache = true }, nil
        end
    end

    -- Get tool implementation (verify it exists before execute)
    local tool = tool_registry.get_tool(tool_name)
    if not tool then
        return nil, "Unknown tool: " .. tool_name
    end

    -- Execute tool via the registry's execute() helper, which handles
    -- permission checks via tool.check_permissions() — single enforcement point.
    local ok, result, exec_err = pcall(tool_registry.execute, tool_name, input, tool_context)

    -- ── Post-execution cache maintenance ──────────────────────────────
    if ok and not exec_err and type(result) == "table" then
        if tool_name == "Read" and result.text and type(input) == "table" and input.file_path
               and not (input.offset and input.offset > 0) then
            local resolved = paths.resolve(input.file_path, tool_context.cwd)
            -- Cache even truncated reads so partial content can be used as an
            -- Edit hint, but mark truncated so full reads are not suppressed.
            self:_cache_file_read(resolved, result.text, result.num_lines, result.truncated)
            -- Surface truncation notice to the model as an embed warning, not in text
            if result.truncation_hint then
                if not self._pending_embed_warnings then self._pending_embed_warnings = {} end
                table.insert(self._pending_embed_warnings, result.truncation_hint)
            end
        elseif (tool_name == "Edit" or tool_name == "MultiEdit" or tool_name == "Write")
               and type(input) == "table" and input.file_path then
            -- Invalidate cache after any successful write so the next Read is fresh.
            local resolved = paths.resolve(input.file_path, tool_context.cwd)
            self:_invalidate_cache(resolved)
        end
    end

    -- Record action in memory manager
    local input_summary
    if type(input) == "table" then
        input_summary = input.file_path or input.command or input.path
            or input.query or input.pattern or "(table)"
    else
        input_summary = tostring(input or "")
    end

    if mem_ok then
        if ok and not exec_err then
            memory.record_action(tool_name, input, result, true)
        else
            local err_msg = ok and exec_err or tostring(result)
            memory.record_action(tool_name, input, err_msg, false)
            if memory.log_error then
                memory.log_error(tool_name, input_summary, err_msg)
            end

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
        -- ── Verifier: decide retry vs fail ─────────────────────────────
        if self._verifier then
            local _verdict, hint = self._verifier.verify(tool_name, input, nil, tostring(result))
            if hint and hint ~= "" then
                if not self._pending_embed_warnings then self._pending_embed_warnings = {} end
                table.insert(self._pending_embed_warnings, hint)
            end
        end
        return nil, tostring(result)
    end

    if exec_err then
        self.on_error("Tool error: " .. exec_err)
        self.on_tool_result(tool_name, {type="error", error=exec_err})
        if self._verifier then
            local _verdict, hint = self._verifier.verify(tool_name, input, nil, exec_err)
            if hint and hint ~= "" then
                if not self._pending_embed_warnings then self._pending_embed_warnings = {} end
                table.insert(self._pending_embed_warnings, hint)
            end
        end
        return nil, exec_err
    end

    -- ── Verifier: handle tool-level errors returned as {type="error"} ──
    if self._verifier and type(result) == "table" and result.type == "error" then
        local verdict, hint = self._verifier.verify(tool_name, input, result, nil)
        if hint and hint ~= "" then
            if not self._pending_embed_warnings then self._pending_embed_warnings = {} end
            table.insert(self._pending_embed_warnings, hint)
        end
        -- If verdict is "retry" and this is an Edit/MultiEdit, inject the cached
        -- file content as a direct hint so the model can see the actual text.
        if (tool_name == "Edit" or tool_name == "MultiEdit")
           and verdict == "retry"
           and type(input) == "table" and input.file_path then
            local resolved = paths.resolve(input.file_path, tool_context.cwd)
            local cached = self._file_cache[resolved]
            if cached and cached.text then
                if not self._pending_embed_warnings then self._pending_embed_warnings = {} end
                local suffix = #cached.text > 3000 and "\n...[truncated]" or ""
                table.insert(self._pending_embed_warnings,
                    "[System: Current content of " .. input.file_path .. " (from last Read):\n"
                    .. cached.text:sub(1, 3000) .. suffix
                    .. "\nCopy old_string verbatim from this content.]")
            end
        end
    elseif self._verifier and (type(result) ~= "table" or result.type ~= "error") then
        self._verifier.verify(tool_name, input, result, nil)  -- reset attempt counter on success
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

        -- Per-turn lookup of tool-dispatch policy. Both knobs are runtime
        -- mutable via config.set/app_state.set so the user can flip behaviour
        -- between turns (e.g. from the chat slash commands /tools and
        -- /permissions) without restarting the engine.
        local cfg_ok, cfg_mod = pcall(require, "config.loader")
        local state_ok, state_mod = pcall(require, "state.app_state")

        local tools_enabled = true
        if state_ok and state_mod and state_mod.get then
            local v = state_mod.get("tools_enabled")
            if v ~= nil then tools_enabled = v and true or false end
        end
        if tools_enabled and cfg_ok and cfg_mod and cfg_mod.get then
            local v = cfg_mod.get("tools_enabled")
            if v == false then tools_enabled = false end
        end

        local has_tools = tools_enabled and self.tools and #self.tools > 0
        local request_tools = has_tools and self.tools or nil

        -- tool_choice precedence: app_state → config → "auto" (when tools
        -- are present). "required" is still available for users who want
        -- the old aggressive behaviour, but it's no longer the default.
        local tool_choice_val = nil
        if has_tools then
            local choice = nil
            if state_ok and state_mod and state_mod.get then
                choice = state_mod.get("tool_choice")
            end
            if not choice and cfg_ok and cfg_mod and cfg_mod.get then
                choice = cfg_mod.get("tool_choice")
            end
            tool_choice_val = choice or "auto"
        end

        -- Prepare API request
        local request = {
            model = self.model,
            max_tokens = self.max_tokens,
            temperature = self.temperature,
            system = self.system_prompt,
            messages = self.messages,
            tools = request_tools,
            stream = true,
            tool_choice = tool_choice_val,
        }

        -- Enrich system prompt with memory context (errors, actions, plan)
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

                -- ── Narration guard ───────────────────────────────────────
                -- Detect when the model uses Brief to announce intent instead of
                -- acting. Patterns: "I will", "I'll", "Let me", "I am going to",
                -- "Running", "Proceeding", "I'm going to", "I would", "I need to".
                -- If detected, redirect by injecting a nudge and continuing the loop.
                local is_narration = false
                if br and #br > 0 then
                    local lower = br:lower():match("^%s*(.-)%s*$") or ""
                    local narration_patterns = {
                        "^i will ", "^i'll ", "^let me ", "^i am going to ",
                        "^i'm going to ", "^running ", "^proceeding",
                        "^i would ", "^i need to ",
                        "^now i ", "^first ", "^to do this", "^i should ",
                    }
                    for _, pat in ipairs(narration_patterns) do
                        if lower:find(pat) then
                            is_narration = true
                            break
                        end
                    end
                end

                if is_narration then
                    -- Reject the Brief and force the model to actually act.
                    -- IMPORTANT: every Brief tool_use MUST get a matching
                    -- tool_result before we either continue or terminate, or
                    -- the OpenAI API will reject the next request because the
                    -- assistant message added below contains an orphan tool_call.
                    local nudge =
                        "[System: You called Brief with an announcement ('" ..
                        (br or ""):sub(1, 80) ..
                        "'). This is FORBIDDEN. DO NOT announce what you will do. " ..
                        "IMMEDIATELY call the appropriate action tool (Shell, Read, Edit, etc.) " ..
                        "and perform the work. Do not call Brief until the task is fully complete.]"
                    table.insert(tool_results_content, {
                        tool_use_id = tool_use.id,
                        content = nudge,
                        is_error = true,
                    })
                    -- Don't terminate the loop — continue so the nudge is sent
                    -- and the model gets another turn to act.
                else
                    -- Brief is terminating: emit a paired tool_result FIRST so the
                    -- transcript stays valid, then surface text and break.
                    local final_text = (br and #br > 0) and br or "(no response)"
                    table.insert(tool_results_content, {
                        tool_use_id = tool_use.id,
                        content = "OK",
                        is_error = false,
                    })
                    if br and #br > 0 then
                        self.on_text(br)
                        brief_response = br
                    else
                        brief_response = final_text
                    end
                end
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
                tool_use_id = tool_use.id,
                content = result_text,
                is_error = is_err,
            })
        end

        ::continue_loop::

        -- Always emit one assistant message per turn carrying ALL tool_calls
        -- (and any text), then emit one role="tool" message per call. This
        -- keeps the role alternation valid for OpenAI even when Brief
        -- terminates the loop.
        local oai_tool_calls = {}
        for _, tool_use in ipairs(response.tool_uses) do
            table.insert(oai_tool_calls, {
                id   = tool_use.id,
                type = "function",
                ["function"] = {
                    name      = tool_use.name,
                    arguments = (type(tool_use.input) == "table")
                        and json_codec.stringify(tool_use.input)
                        or tostring(tool_use.input or "{}"),
                },
            })
        end
        local assistant_msg = { role = "assistant" }
        if response.text and #response.text > 0 then
            assistant_msg.content = response.text
        end
        if #oai_tool_calls > 0 then
            assistant_msg.tool_calls = oai_tool_calls
        end
        table.insert(self.messages, assistant_msg)

        for _, tr in ipairs(tool_results_content) do
            self:add_tool_result(tr.tool_use_id, tr.content, tr.is_error)
        end

        -- If Brief was called, end here — the model has given its final response.
        if brief_response then
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

        -- Flush any embed-based self-correction warnings generated during this
        -- turn. With the OpenAI-native shape, the LAST message is a role="tool"
        -- with a string content, so we simply append to it.
        if self._pending_embed_warnings and #self._pending_embed_warnings > 0 then
            local warning_text = table.concat(self._pending_embed_warnings, "\n\n")
            local attached = false
            for i = #self.messages, 1, -1 do
                local m = self.messages[i]
                if m.role == "tool" then
                    m.content = (m.content or "") .. "\n\n" .. warning_text
                    attached = true
                    break
                end
                if m.role == "assistant" then break end
            end
            if not attached then
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
