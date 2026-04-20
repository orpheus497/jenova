-- agent/loop.lua — Unified agentic loop (integrated from legacy-agent)
--
-- Plan → Execute → Reflect loop with:
--   - Tool calling via the full tool registry
--   - Action deduplication from memory
--   - Context window management
--   - Narration detection + nudging
--   - FreeBSD-aware shell command rewriting
--
-- This replaces the standalone legacy-agent/agent.lua by integrating it
-- with the full cli-agent tool ecosystem and provider system.

local M = {}

local function try_require(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

function M.run(opts)
    local providers = try_require("providers.base")
    local tool_registry = try_require("tools.registry")
    local memory = try_require("agent.memory")
    local ui = try_require("agent.ui")
    local json = try_require("utils.json_fallback")

    if not providers then
        io.stderr:write("Error: provider system not available\n")
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

    local conversation = {}
    local max_turns = opts.max_turns or 100
    local turn_count = 0

    local function add_message(role, content)
        table.insert(conversation, { role = role, content = content })
    end

    local function execute_tool(name, arguments)
        if not tool_registry then
            return nil, "tool registry not available"
        end

        if memory and memory.was_action_tried then
            local action_key = name .. ":" .. (json and json.stringify(arguments) or tostring(arguments))
            if memory.was_action_tried(action_key) then
                return nil, "action already tried and failed"
            end
        end

        local result, err = tool_registry.execute(name, arguments)

        if memory and memory.record_action then
            local action_key = name .. ":" .. tostring(arguments)
            memory.record_action(action_key, err == nil)
        end

        return result, err
    end

    local function process_tool_calls(response_text)
        if not response_text then return nil end

        local tool_calls = {}

        for tag_content in response_text:gmatch("<tool_call>(.-)</tool_call>") do
            local parsed = json and json.parse(tag_content)
            if parsed and parsed.name then
                table.insert(tool_calls, parsed)
            end
        end

        if #tool_calls == 0 then
            local parsed = json and json.parse(response_text)
            if parsed and parsed.name and parsed.arguments then
                table.insert(tool_calls, parsed)
            end
        end

        return #tool_calls > 0 and tool_calls or nil
    end

    local function agent_turn(user_input)
        turn_count = turn_count + 1
        if turn_count > max_turns then
            return "Max turns reached. Use /clear to reset."
        end

        add_message("user", user_input)

        local context_injection = ""
        if memory and memory.build_context then
            context_injection = memory.build_context()
        end

        local system_prompt = opts.system_prompt or ""
        if #context_injection > 0 then
            system_prompt = system_prompt .. "\n\n" .. context_injection
        end

        local response, err = providers.generate(conversation, {
            model = opts.model,
            system_prompt = system_prompt,
            tools = tool_registry and tool_registry.build_api_tools() or nil,
        })

        if not response then
            return "Error: " .. tostring(err)
        end

        local tool_calls = process_tool_calls(response)
        if tool_calls then
            local results = {}
            for _, tc in ipairs(tool_calls) do
                local result, tool_err = execute_tool(tc.name, tc.arguments or {})
                if tool_err then
                    table.insert(results, string.format("[%s] Error: %s", tc.name, tool_err))
                else
                    local text = type(result) == "string" and result
                        or (json and json.stringify(result) or tostring(result))
                    table.insert(results, string.format("[%s] %s", tc.name, text))
                end

                if ui and ui.status_info then
                    ui.status_info(tc.name, tool_err and "failed" or "ok")
                end
            end

            add_message("assistant", response)
            add_message("tool", table.concat(results, "\n"))

            local follow_up, fu_err = providers.generate(conversation, {
                model = opts.model,
                system_prompt = system_prompt,
            })

            if follow_up then
                add_message("assistant", follow_up)
                return follow_up
            end
            return table.concat(results, "\n")
        end

        add_message("assistant", response)
        return response
    end

    while true do
        if is_interrupted and is_interrupted() then
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
            conversation = {}
            turn_count = 0
            if memory and memory.clear then memory.clear() end
            print("Session cleared.")
        elseif line == "/history" then
            print(string.format("Turns: %d, Messages: %d", turn_count, #conversation))
        elseif line == "/debug" then
            if json then
                print(json.stringify({ turns = turn_count, messages = #conversation }))
            end
        elseif line == "/context" then
            if memory and memory.build_context then
                print(memory.build_context())
            end
        elseif line:sub(1, 1) == "/" then
            local cmd_name = line:match("^/(%S+)")
            local cmd_args = line:match("^/%S+%s+(.*)") or ""
            local ok_reg, cmd_registry = pcall(require, "cli.commands.registry")
            local handler = ok_reg and cmd_registry.get_command(cmd_name) or nil
            if handler then
                pcall(handler, cmd_args)
            else
                print("Unknown command: " .. line)
            end
        elseif #line > 0 then
            local response = agent_turn(line)
            if response then
                print(response)
            end
        end
    end

    if memory and memory.save then
        memory.save()
    end

    jenova.agent.shutdown()
    return 0
end

return M
