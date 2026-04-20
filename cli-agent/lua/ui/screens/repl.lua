-- ui/screens/repl.lua — Interactive REPL screen
-- Equivalent to src/screens/replScreen.tsx
-- Uses the full agent/ui.lua terminal UI system.

local query_engine_module = require("engine.query_engine")
local config = require("config.loader")
local app_state = require("state.app_state")
local command_registry = require("cli.commands.registry")

local ui
do
    local ok, mod = pcall(require, "agent.ui")
    if ok then ui = mod end
end

local REPL = {}

-- ── REPL State ────────────────────────────────────────────────────────

local repl_state = {
    running = false,
    query_engine = nil,
    input_buffer = "",
    cursor_pos = 0,
    history_index = 0,
    thinking_buf = "",
    thinking_tokens = 0,
}

-- ── REPL Initialization ───────────────────────────────────────────────

function REPL.init(opts)
    opts = opts or {}

    -- Load config
    config.load()

    -- Initialize session (rehydrating from disk if resuming)
    if opts.resume and opts.session_id then
        app_state.init_session(opts.session_id)
        local loaded, err = app_state.load_session(opts.session_id)
        if not loaded then
            if ui then
                ui.status_warn("could not load session " .. tostring(opts.session_id) .. ": " .. tostring(err))
            else
                io.stderr:write(string.format(
                    "Warning: could not load session %s: %s\n",
                    opts.session_id, tostring(err)
                ))
            end
        end
    else
        app_state.init_session()
    end

    -- Set working directory
    app_state.set_cwd(os.getenv("PWD") or ".")

    -- Create query engine with UI-aware callbacks
    local query_opts = {
        model = opts.model or config.get("model"),
        thinking_enabled = config.get("thinking_enabled"),
        max_tokens = config.get("max_tokens"),
        temperature = config.get("temperature"),
        system_prompt = REPL.build_system_prompt(),
        can_use_tool = REPL.can_use_tool,
        on_text = REPL.on_text,
        on_thinking = REPL.on_thinking,
        on_tool_use = REPL.on_tool_use,
        on_tool_result = REPL.on_tool_result,
        on_error = REPL.on_error,
    }

    repl_state.query_engine = query_engine_module.new(query_opts)

    return repl_state
end

-- ── System Prompt Builder ─────────────────────────────────────────────

function REPL.build_system_prompt(opts)
    opts = opts or {}
    local ok, prompts = pcall(require, "constants.prompts")
    if ok and prompts then
        return prompts.get_system_prompt({
            is_non_interactive = opts.is_non_interactive or false,
            has_append_system_prompt = opts.append_system_prompt ~= nil,
            append_system_prompt = opts.append_system_prompt,
            custom_system_prompt = opts.custom_system_prompt,
            override_system_prompt = opts.override_system_prompt,
            coordinator_mode = opts.coordinator_mode or (os.getenv("CLAUDE_CODE_COORDINATOR_MODE") == "1"),
            plan_mode = opts.plan_mode or (config.get("permission_mode") == "plan"),
        })
    end

    -- Fallback if the constants module isn't available.
    return "You are Jenova CLI, an AI coding assistant. Be concise and helpful."
end

-- ── Callbacks (UI-aware) ────────────────────────────────────────────────

function REPL.on_text(text)
    if ui then
        ui.stream_text(text)
    else
        io.write(text)
        io.flush()
    end
end

function REPL.on_thinking(text)
    if not config.get("thinking_enabled") then return end

    repl_state.thinking_buf = (repl_state.thinking_buf or "") .. text
    repl_state.thinking_tokens = (repl_state.thinking_tokens or 0) + 1

    if ui and ui.thinking_inline then
        ui.thinking_inline(repl_state.thinking_tokens)
    end
end

function REPL.on_tool_use(tool_name, input)
    if ui and ui.tool_badge then
        ui.tool_badge(tool_name, "running")
    elseif ui then
        ui.status_info(tool_name .. " running")
    else
        io.write(string.format("\n[Tool: %s]\n", tool_name))
    end
end

function REPL.on_tool_result(tool_name, result)
    if ui and ui.tool_badge then
        ui.tool_badge(tool_name, "done")
    end
end

function REPL.on_error(err)
    if ui and ui.status_err then
        ui.status_err(tostring(err))
    else
        io.stderr:write(string.format("\x1b[31mError: %s\x1b[0m\n", tostring(err)))
    end
end

-- ── Permission Check ──────────────────────────────────────────────────

function REPL.can_use_tool(tool_name, input)
    local ok, permissions = pcall(require, "permissions.manager")
    if ok then
        local allowed, err = permissions.can_use_tool(tool_name, input)
        return allowed
    end
    return true
end

-- ── Command Handling ──────────────────────────────────────────────────

function REPL.handle_command(input)
    local cmd_name = input:match("^/(%S+)")
    if not cmd_name then
        if ui then ui.status_err("invalid command format")
        else io.stderr:write("Invalid command format\n") end
        return
    end

    local args = input:match("^/%S+%s+(.*)")  or ""

    local handler = command_registry.get_command(cmd_name)
    if not handler then
        if ui then
            ui.status_err("unknown command: /" .. cmd_name .. " — try /help")
        else
            io.stderr:write(string.format("Unknown command: /%s\n", cmd_name))
            io.stderr:write("Type /help for available commands\n")
        end
        return
    end

    local ok, result = pcall(handler, args)
    if not ok then
        if ui then ui.status_err("command error: " .. tostring(result))
        else io.stderr:write(string.format("Command error: %s\n", tostring(result))) end
    end
end

-- ── Main REPL Loop ────────────────────────────────────────────────────

function REPL.run(opts)
    REPL.init(opts)

    -- ── Full startup UI ─────────────────────────────────────────────
    if ui and ui.draw_header then
        io.write("\n")
        ui.draw_header()

        local info_opts = {
            cwd = app_state.get_cwd(),
            provider = config.get("provider") or "llamacpp",
            model = config.get("model") or opts.model or "auto",
            session = app_state.get("session_id"),
        }

        local ok_tools, tool_registry = pcall(require, "tools.registry")
        if ok_tools and tool_registry and tool_registry.list_tools then
            info_opts.tools = tostring(#tool_registry.list_tools())
        end

        ui.draw_info(info_opts)
        ui.separator("session")
        ui.draw_commands({
            "/clear", "/history", "/context", "/files", "/sessions",
            "/plan", "/stats", "/diag", "/model",
            "/provider", "/tools", "/help", "/quit",
        })
    else
        print("Jenova CLI v0.2.0 (Lua/C)")
        print(string.format("Session: %s", app_state.get("session_id")))
        print("Type your message or /help for commands. Ctrl+D to exit.\n")
    end

    repl_state.running = true

    while repl_state.running do
        -- Prompt
        if ui and ui.write_prompt then
            ui.write_prompt()
        else
            io.write("\x1b[1;34m>\x1b[0m ")
            io.flush()
        end

        -- Read input
        local line = io.read("*l")

        if not line then
            -- Ctrl+D
            if ui and ui.goodbye then ui.goodbye()
            else print("\nGoodbye!") end
            REPL._persist_on_exit()
            break
        end

        -- Trim whitespace
        line = line:match("^%s*(.-)%s*$")

        -- Handle empty input
        if #line == 0 then
            goto continue
        end

        -- Multi-line input
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

        -- Handle commands
        if line:sub(1, 1) == "/" then
            if line == "/exit" or line == "/quit" or line == "/q" then
                if ui and ui.goodbye then ui.goodbye()
                else print("Goodbye!") end
                REPL._persist_on_exit()
                break
            else
                REPL.handle_command(line)
                goto continue
            end
        end

        -- Add to history
        app_state.add_history_item(line)

        -- Reset thinking state
        repl_state.thinking_buf = ""
        repl_state.thinking_tokens = 0

        -- Query the model
        app_state.set("is_querying", true)

        -- Show agent label before streaming response
        if ui and ui.agent_label then
            ui.agent_label()
        else
            print("")
        end

        local response, err = repl_state.query_engine:query(line, {
            max_turns = config.get("max_turns") or 25
        })

        app_state.set("is_querying", false)

        -- Clear thinking indicator
        if ui and ui.thinking_inline_done and repl_state.thinking_tokens > 0 then
            ui.thinking_inline_done()
            if #repl_state.thinking_buf > 100 and ui.think_status then
                ui.think_status(#repl_state.thinking_buf)
            end
        end

        if err then
            if ui and ui.status_err then
                ui.status_err("query failed: " .. err)
                ui.diagnostic("Try /clear to reduce context or /diag for diagnostics")
            else
                io.stderr:write(string.format("\x1b[31mQuery failed: %s\x1b[0m\n", err))
            end
        else
            -- End streaming output
            if ui and ui.stream_end then
                ui.stream_end()
            else
                print("")
            end

            -- Show cost if enabled
            if config.get("show_cost") then
                local usage = response.usage
                if ui and ui.token_usage then
                    ui.token_usage(usage.input_tokens, usage.output_tokens, usage.total_cost_usd)
                else
                    print(string.format(
                        "\n\x1b[2m[Tokens: %d in, %d out | Cost: $%.4f]\x1b[0m",
                        usage.input_tokens,
                        usage.output_tokens,
                        usage.total_cost_usd
                    ))
                end
            end
        end

        ::continue::
    end

    return 0
end

-- ── Stop REPL ─────────────────────────────────────────────────────────

function REPL.stop()
    repl_state.running = false
    if repl_state.query_engine then
        repl_state.query_engine:abort()
    end
    REPL._persist_on_exit()
end

function REPL._persist_on_exit()
    if not config.get("auto_save") then return end
    local ok, err = app_state.save_session()
    if not ok then
        if ui then
            ui.status_warn("failed to save session: " .. tostring(err))
        else
            io.stderr:write(string.format("Warning: failed to save session: %s\n", tostring(err)))
        end
    end
end

return REPL
