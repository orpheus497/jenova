-- agent/loop.lua — Unified REPL loop
--
-- The REPL (prompt, slash command dispatch, history, interrupt handling)
-- lives here. All LLM generation and tool execution is delegated to
-- engine/query_engine.lua — the single agentic loop implementation.
--
-- Full polished terminal UI via agent/ui.lua (restored from legacy-agent).

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
    local config = try_require("config.loader")

    if not QueryEngine then
        io.stderr:write("Error: query engine not available\n")
        return 1
    end

    -- ── Startup: Full UI dashboard ──────────────────────────────────────
    if ui and ui.draw_header then
        io.write("\n")
        ui.draw_header()

        local info_opts = {
            cwd = os.getenv("PWD") or ".",
        }

        if config then
            info_opts.provider = config.get("provider") or "llamacpp"
            info_opts.model = config.get("model") or opts.model or "auto"
        end

        local tool_registry = try_require("tools.registry")
        if tool_registry and tool_registry.list_tools then
            local tools = tool_registry.list_tools()
            info_opts.tools = tostring(#tools)
        end

        info_opts.turns = tostring(opts.max_turns or 100)

        if app_state and app_state.get then
            local sid = app_state.get("session_id")
            if sid then info_opts.session = sid end
        end

        ui.draw_info(info_opts)
        ui.separator("session")
        do
            local ok_reg, reg = pcall(require, "cli.commands.registry")
            local cmd_list
            if ok_reg and reg and reg.list_commands then
                local cmds = reg.list_commands()
                cmd_list = {}
                for _, c in ipairs(cmds) do
                    table.insert(cmd_list, "/" .. c.name)
                end
            else
                cmd_list = {
                    "/clear", "/compact", "/config", "/context", "/cost",
                    "/cwd", "/diag", "/doctor", "/diff", "/files",
                    "/help", "/history", "/mcp", "/model", "/plan",
                    "/provider", "/quit", "/sessions", "/session",
                    "/stats", "/thinking", "/tools", "/version", "/vim",
                }
            end
            ui.draw_commands(cmd_list)
        end
    else
        print("cli-agent 0.2.0 (C + Lua + llama.cpp)")
        print("Type your message or /help. Ctrl+D to exit.\n")
    end

    if memory and memory.init then
        memory.init()
    end

    -- ── Inject startup filesystem snapshot into system prompt ───────────
    -- Gives the model immediate awareness of the working directory tree
    -- so it can answer questions about files without needing tool calls.
    local context_mod = try_require("context.manager")
    local base_system_prompt = opts.system_prompt or ""
    if context_mod then
        local cwd = (app_state and app_state.get_cwd and app_state.get_cwd())
            or os.getenv("PWD") or "."
        local sys_ctx  = context_mod.get_system_context()
        local user_ctx = context_mod.get_user_context()

        local ctx_parts = {
            "## Environment",
            string.format("Platform: %s (%s)", sys_ctx.platform, sys_ctx.os_version or ""),
            string.format("Working directory: %s", cwd),
            string.format("Shell: %s", user_ctx.shell or "unknown"),
            string.format("User: %s", user_ctx.username or "unknown"),
        }

        if sys_ctx.is_git_repo then
            table.insert(ctx_parts, string.format("Git branch: %s", sys_ctx.git_branch or "unknown"))
            if sys_ctx.git_status and sys_ctx.git_status ~= "(clean)" then
                table.insert(ctx_parts, "Git status (short):\n" .. sys_ctx.git_status)
            else
                table.insert(ctx_parts, "Git status: clean")
            end
        end

        local snapshot = context_mod.get_directory_snapshot(cwd, 400)
        if snapshot then
            table.insert(ctx_parts, "\n## Directory tree (cwd)\n" .. snapshot)
        end

        local ctx_block = table.concat(ctx_parts, "\n")
        if #base_system_prompt > 0 then
            base_system_prompt = base_system_prompt .. "\n\n" .. ctx_block
        else
            base_system_prompt = ctx_block
        end
    end
    local thinking_buf = ""
    local thinking_tokens = 0

    local engine = QueryEngine.new({
        model = opts.model,
        system_prompt = base_system_prompt,
        max_tokens = opts.max_tokens,
        temperature = opts.temperature,
        thinking_enabled = opts.thinking_enabled,

        on_text = function(text)
            -- Stop the spinner before the first text token so the cursor is
            -- on a clean line. spinner_stop() is idempotent.
            if ui and ui.spinner_stop then ui.spinner_stop() end
            io.write(text)
            io.flush()
        end,

        on_thinking = function(text)
            thinking_buf = thinking_buf .. text
            thinking_tokens = thinking_tokens + 1
            if ui and ui.thinking_inline then
                ui.thinking_inline(thinking_tokens)
            end
        end,

        on_tool_use = function(tool_name, _input)
            -- Stop the spinner so the badge lands on its own line.
            if ui and ui.spinner_stop then ui.spinner_stop() end
            if ui and ui.tool_badge then
                ui.tool_badge(tool_name, "running")
            elseif ui and ui.status_info then
                ui.status_info(tool_name .. " running")
            end
        end,

        on_tool_result = function(tool_name, _result)
            if ui and ui.tool_badge then
                ui.tool_badge(tool_name, "done")
            elseif ui and ui.status_info then
                ui.status_info(tool_name .. " done")
            end
        end,

        on_error = function(err)
            if ui and ui.status_err then
                ui.status_err(tostring(err))
            else
                io.stderr:write("Error: " .. tostring(err) .. "\n")
            end
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
            if ui then ui.status_warn("max turns reached — use /clear to reset") end
            return "Max turns reached. Use /clear to reset."
        end

        -- Turn indicator
        if ui and ui.status_turn then
            ui.status_turn(turn_count, max_turns, "thinking")
        end

        -- Reset thinking buffer
        thinking_buf = ""
        thinking_tokens = 0

        -- Inject memory context on top of the rich base system prompt
        local system_prompt = base_system_prompt
        if memory and memory.build_context then
            local ctx = memory.build_context()
            if ctx and #ctx > 0 then
                system_prompt = system_prompt .. "\n\n" .. ctx
            end
        end
        engine.system_prompt = system_prompt

        -- Start spinner
        if ui and ui.spinner_start then
            ui.spinner_start("cognizing")
        end

        local result, err = engine:query(user_input, {
            max_turns = opts.agent_max_turns or 25,
        })

        -- Stop spinner and print agent label before response
        if ui and ui.spinner_stop then
            ui.spinner_stop()
        end
        if ui and ui.agent_label then
            ui.agent_label()
        end

        -- Clear inline thinking indicator
        if ui and ui.thinking_inline_done and thinking_tokens > 0 then
            ui.thinking_inline_done()
            -- Show thinking summary if we had substantial thinking
            if #thinking_buf > 100 and ui.think_status then
                ui.think_status(#thinking_buf)
            end
        end

        if not result then
            if ui then
                ui.status_err("query failed: " .. tostring(err))
                ui.diagnostic("Check backend with /diag or /backend status")
            end
            return nil
        end

        -- Update cost tracking
        if app_state and app_state.update_usage then
            local usage = engine:get_usage()
            local prev_in = app_state.get("_last_input_tokens") or 0
            local prev_out = app_state.get("_last_output_tokens") or 0
            local prev_cost = app_state.get("_last_cost") or 0
            app_state.update_usage(
                usage.input_tokens - prev_in,
                usage.output_tokens - prev_out,
                usage.total_cost_usd - prev_cost
            )
            app_state.set("_last_input_tokens", usage.input_tokens)
            app_state.set("_last_output_tokens", usage.output_tokens)
            app_state.set("_last_cost", usage.total_cost_usd)
        end

        -- Show token usage if config says so
        if config and config.get("show_cost") and ui and ui.token_usage then
            local usage = engine:get_usage()
            ui.token_usage(usage.input_tokens, usage.output_tokens, usage.total_cost_usd)
        end

        return result.text or ""
    end

    -- Check for interrupt: the C host may expose a global, or we no-op
    local _is_interrupted = rawget(_G, "is_interrupted")
    local function check_interrupted()
        if type(_is_interrupted) == "function" then
            return _is_interrupted()
        end
        return false
    end

    -- ── Main REPL loop ──────────────────────────────────────────────────
    while true do
        if check_interrupted() then
            if ui and ui.status_warn then
                ui.status_warn("interrupted")
            else
                print("\nInterrupted.")
            end
            break
        end

        -- Write prompt
        if ui and ui.write_prompt then
            ui.write_prompt()
        elseif ui and ui.prompt then
            io.write(ui.prompt())
            io.flush()
        else
            io.write("> ")
            io.flush()
        end

        local line = io.read("*l")
        if not line then
            if ui and ui.goodbye then
                ui.goodbye()
            else
                print("\nGoodbye!")
            end
            break
        end

        -- Trim
        line = line:match("^%s*(.-)%s*$")
        if #line == 0 then goto continue end

        -- Multi-line input (backslash continuation)
        while line:sub(-1) == "\\" do
            line = line:sub(1, -2) .. "\n"
            if ui and ui.continuation_prompt then
                ui.continuation_prompt()
            else
                io.write("... "); io.flush()
            end
            local nl = io.read("*l")
            if not nl then break end
            line = line .. nl
        end

        -- Commands
        if line == "/exit" or line == "/quit" or line == "/q" or line == "\3" then
            if ui and ui.goodbye then ui.goodbye()
            else print("Goodbye!") end
            break
        elseif line == "/clear" then
            engine.messages = {}
            turn_count = 0
            if memory and memory.clear then memory.clear() end
            if app_state then
                if app_state.clear_messages then app_state.clear_messages() end
                if app_state.reset_usage then app_state.reset_usage() end
            end
            if ui then ui.status_ok("cleared (session + history)")
            else print("Session cleared.") end
        elseif line == "/history" then
            if ui and ui.dimtext then
                for i, m in ipairs(engine.messages) do
                    ui.dimtext(string.format("  [%d] %s: %s\n", i, m.role, tostring(m.content):sub(1, 80)))
                end
            else
                print(string.format("Turns: %d, Messages: %d", turn_count, #engine.messages))
            end
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
                if ui and ui.dimtext then
                    ui.dimtext("=== Context ===\n" .. memory.build_context() .. "\n=== End ===\n")
                else
                    print(memory.build_context())
                end
            end
        elseif line:sub(1, 1) == "/" then
            local cmd_name = line:match("^/(%S+)")
            local cmd_args = line:match("^/%S+%s+(.*)") or ""
            local reg = get_cmd_registry()
            local handler = reg and reg.get_command(cmd_name) or nil
            if handler then
                pcall(handler, cmd_args)
            else
                if ui and ui.status_err then
                    ui.status_err("unknown command: " .. line .. " — try /help")
                else
                    print("Unknown command: " .. line)
                end
            end
        else
            -- Agent query
            local response = agent_turn(line)
            if response and #response > 0 then
                -- Response was already streamed via on_text callback
                if ui and ui.stream_end then
                    ui.stream_end()
                else
                    print("")
                end
            else
                print("")
            end
        end

        ::continue::
    end

    -- ── Shutdown ────────────────────────────────────────────────────────
    if memory and memory.save then
        memory.save()
    end

    if app_state and app_state.save_session then
        pcall(app_state.save_session)
    end

    local _jenova = rawget(_G, "jenova")
    if type(_jenova) == "table" and _jenova.agent and _jenova.agent.shutdown then
        _jenova.agent.shutdown()
    end
    return 0
end

return M
