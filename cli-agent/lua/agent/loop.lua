-- agent/loop.lua — Unified REPL loop
--
-- The REPL (prompt, slash command dispatch, history, interrupt handling)
-- lives here. All LLM generation and tool execution is delegated to
-- engine/query_engine.lua — the single agentic loop implementation.
--
-- This eliminates the previous duplication where agent/loop.lua had its own
-- inline generate → parse-tool-calls → single-follow-up path that was inferior
-- to QueryEngine's multi-turn tool loop.

local M = {}

local function try_require(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

function M.run(opts)
    local QueryEngine = try_require("engine.query_engine")
    local memory = try_require("agent.memory")
    local ui = try_require("agent.ui")
    local json = try_require("utils.json_fallback")
    local app_state = try_require("state.app_state")

    if not QueryEngine then
        io.stderr:write("Error: query engine not available\n")
        return 1
    end

    if ui and ui.show_header then
        ui.show_header()
    else
        print("cli-agent 0.2.0 (C + Lua + llama.cpp)")
        print("Type your message or /help. Ctrl+D to exit.\n")
    end

    if memory and memory.init then
        memory.init()
    end

    -- Create the query engine instance — this is the single agentic loop
    local engine = QueryEngine.new({
        model = opts.model,
        system_prompt = opts.system_prompt or "",
        max_tokens = opts.max_tokens,
        temperature = opts.temperature,
        thinking_enabled = opts.thinking_enabled,
        on_text = function(text)
            io.write(text)
            io.flush()
        end,
        on_thinking = function(text)
            if ui and ui.show_thinking then
                ui.show_thinking(text)
            end
        end,
        on_tool_use = function(tool_name, input)
            if ui and ui.status_info then
                ui.status_info(tool_name, "running")
            end
        end,
        on_tool_result = function(tool_name, result)
            if ui and ui.status_info then
                ui.status_info(tool_name, "ok")
            end
        end,
        on_error = function(err)
            io.stderr:write("Error: " .. tostring(err) .. "\n")
        end,
    })

    local turn_count = 0
    local max_turns = opts.max_turns or 100

    local cmd_registry = nil
    local function get_cmd_registry()
        if cmd_registry == nil then
            local ok_reg, reg = pcall(require, "cli.commands.registry")
            cmd_registry = ok_reg and reg or false
        end
        return cmd_registry
    end

    local function agent_turn(user_input)
        turn_count = turn_count + 1
        if turn_count > max_turns then
            return "Max turns reached. Use /clear to reset."
        end

        if ui and ui.status_turn then
            ui.status_turn(turn_count)
        end

        -- Inject memory context into system prompt for this turn
        local system_prompt = opts.system_prompt or ""
        if memory and memory.build_context then
            local ctx = memory.build_context()
            if ctx and #ctx > 0 then
                system_prompt = system_prompt .. "\n\n" .. ctx
            end
        end
        engine.system_prompt = system_prompt

        if ui and ui.thinking then ui.thinking() end

        local result, err = engine:query(user_input, {
            max_turns = opts.agent_max_turns or 25,
        })

        if ui and ui.thinking_done then ui.thinking_done() end

        if not result then
            return "Error: " .. tostring(err)
        end

        -- Update cost tracking in app_state
        if app_state then
            local usage = engine:get_usage()
            app_state.update_usage(
                usage.input_tokens - (app_state.get("_last_input_tokens") or 0),
                usage.output_tokens - (app_state.get("_last_output_tokens") or 0),
                usage.total_cost_usd - (app_state.get("_last_cost") or 0)
            )
            app_state.set("_last_input_tokens", usage.input_tokens)
            app_state.set("_last_output_tokens", usage.output_tokens)
            app_state.set("_last_cost", usage.total_cost_usd)
        end

        return result.text or ""
    end

    -- Check for interrupt: the C host may expose a global, or we no-op
    local function check_interrupted()
        if type(is_interrupted) == "function" then
            return is_interrupted()
        end
        return false
    end

    while true do
        if check_interrupted() then
            print("\nInterrupted.")
            break
        end

        if ui and ui.prompt then
            io.write(ui.prompt())
        else
            io.write("> ")
        end
        io.flush()

        local line = io.read("*l")
        if not line then
            print("\nGoodbye!")
            break
        end

        if line == "/exit" or line == "/quit" then
            print("Goodbye!")
            break
        elseif line == "/clear" then
            engine.messages = {}
            turn_count = 0
            if memory and memory.clear then memory.clear() end
            if app_state then
                app_state.clear_messages()
                app_state.reset_usage()
            end
            print("Session cleared.")
        elseif line == "/history" then
            print(string.format("Turns: %d, Messages: %d", turn_count, #engine.messages))
        elseif line == "/debug" then
            if json then
                print(json.stringify({
                    turns = turn_count,
                    messages = #engine.messages,
                    usage = engine:get_usage(),
                }))
            end
        elseif line == "/context" then
            if memory and memory.build_context then
                print(memory.build_context())
            end
        elseif line:sub(1, 1) == "/" then
            local cmd_name = line:match("^/(%S+)")
            local cmd_args = line:match("^/%S+%s+(.*)") or ""
            local reg = get_cmd_registry()
            local handler = reg and reg.get_command(cmd_name) or nil
            if handler then
                pcall(handler, cmd_args)
            else
                print("Unknown command: " .. line)
            end
        elseif #line > 0 then
            local response = agent_turn(line)
            if response and #response > 0 then
                print(response)
            end
        end
    end

    if memory and memory.save then
        memory.save()
    end

    -- Save session state
    if app_state and app_state.save_session then
        pcall(app_state.save_session)
    end

    if jenova and jenova.agent and jenova.agent.shutdown then
        jenova.agent.shutdown()
    end
    return 0
end

return M
