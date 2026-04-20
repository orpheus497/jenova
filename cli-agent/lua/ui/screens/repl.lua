-- ui/screens/repl.lua — Interactive REPL screen
-- Equivalent to src/screens/replScreen.tsx

local query_engine_module = require("engine.query_engine")
local config = require("config.loader")
local app_state = require("state.app_state")
local command_registry = require("cli.commands.registry")

local REPL = {}

-- ── REPL State ────────────────────────────────────────────────────────

local repl_state = {
    running = false,
    query_engine = nil,
    input_buffer = "",
    cursor_pos = 0,
    history_index = 0,
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
            io.stderr:write(string.format(
                "Warning: could not load session %s: %s\n",
                opts.session_id, tostring(err)
            ))
        end
    else
        app_state.init_session()
    end

    -- Set working directory
    app_state.set_cwd(os.getenv("PWD") or ".")

    -- Create query engine
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

-- ── Callbacks ─────────────────────────────────────────────────────────

function REPL.on_text(text)
    io.write(text)
    io.flush()
end

function REPL.on_thinking(text)
    if config.get("thinking_enabled") then
        io.write("\x1b[2m") -- Dim
        io.write(text)
        io.write("\x1b[0m") -- Reset
        io.flush()
    end
end

function REPL.on_tool_use(tool_name, input)
    io.write(string.format("\n[Tool: %s]\n", tool_name))
end

function REPL.on_tool_result(tool_name, result)
    -- Silent - tool results are fed back to the model
end

function REPL.on_error(err)
    io.stderr:write(string.format("\x1b[31mError: %s\x1b[0m\n", tostring(err)))
end

-- ── Permission Check ──────────────────────────────────────────────────

function REPL.can_use_tool(tool_name, input)
    -- Delegate to the centralized permissions manager
    local ok, permissions = pcall(require, "permissions.manager")
    if ok then
        local allowed, err = permissions.can_use_tool(tool_name, input)
        return allowed
    end

    -- Fallback: if permissions manager unavailable, allow all
    return true
end

-- ── Command Handling ──────────────────────────────────────────────────

function REPL.handle_command(input)
    local cmd_name = input:match("^/(%S+)")
    if not cmd_name then
        io.stderr:write("Invalid command format\n")
        return
    end

    local args = input:match("^/%S+%s+(.*)")  or ""

    -- Get command handler
    local handler = command_registry.get_command(cmd_name)
    if not handler then
        io.stderr:write(string.format("Unknown command: /%s\n", cmd_name))
        io.stderr:write("Type /help for available commands\n")
        return
    end

    -- Execute command
    local ok, result = pcall(handler, args)
    if not ok then
        io.stderr:write(string.format("Command error: %s\n", tostring(result)))
    end
end

-- ── Main REPL Loop ────────────────────────────────────────────────────

function REPL.run(opts)
    REPL.init(opts)

    -- Print welcome message
    print("Jenova CLI v0.1.0 (Lua/C)")
    print(string.format("Session: %s", app_state.get("session_id")))
    print("Type your message or /help for commands. Ctrl+D to exit.\n")

    repl_state.running = true

    while repl_state.running do
        -- Prompt
        io.write("\x1b[1;34m>\x1b[0m ")
        io.flush()

        -- Read input
        local line = io.read("*l")

        if not line then
            -- Ctrl+D pressed
            print("\nGoodbye!")
            REPL._persist_on_exit()
            break
        end

        -- Trim whitespace
        line = line:match("^%s*(.-)%s*$")

        -- Handle empty input
        if #line == 0 then
            goto continue
        end

        -- Handle commands
        if line:sub(1, 1) == "/" then
            if line == "/exit" or line == "/quit" then
                print("Goodbye!")
                REPL._persist_on_exit()
                break
            else
                REPL.handle_command(line)
                goto continue
            end
        end

        -- Add to history
        app_state.add_history_item(line)

        -- Query the model
        app_state.set("is_querying", true)
        print("") -- Newline before response

        local response, err = repl_state.query_engine:query(line, {
            max_turns = config.get("max_turns") or 25
        })

        app_state.set("is_querying", false)

        if err then
            io.stderr:write(string.format("\x1b[31mQuery failed: %s\x1b[0m\n", err))
        else
            print("") -- Newline after response

            -- Show cost if enabled
            if config.get("show_cost") then
                local usage = response.usage
                print(string.format(
                    "\n\x1b[2m[Tokens: %d in, %d out | Cost: $%.4f]\x1b[0m",
                    usage.input_tokens,
                    usage.output_tokens,
                    usage.total_cost_usd
                ))
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

-- Persist current session state to disk so it can be resumed with
-- `cli-agent --resume <session_id>`.
function REPL._persist_on_exit()
    if not config.get("auto_save") then return end
    local ok, err = app_state.save_session()
    if not ok then
        io.stderr:write(string.format("Warning: failed to save session: %s\n", tostring(err)))
    end
end

return REPL
