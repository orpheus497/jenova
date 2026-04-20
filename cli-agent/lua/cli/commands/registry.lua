-- cli/commands/registry.lua — Slash command registry
-- Equivalent to src/commands.ts

local CommandRegistry = {}

-- Command storage
local commands = {}

-- ── Command Registration ──────────────────────────────────────────────

function CommandRegistry.register(name, handler, options)
    options = options or {}

    commands[name] = {
        name = name,
        handler = handler,
        description = options.description or "",
        usage = options.usage or "",
        aliases = options.aliases or {},
        hidden = options.hidden or false,
    }

    -- Register aliases
    if options.aliases then
        for _, alias in ipairs(options.aliases) do
            commands[alias] = commands[name]
        end
    end
end

function CommandRegistry.get_command(name)
    local cmd = commands[name]
    return cmd and cmd.handler or nil
end

function CommandRegistry.list_commands()
    local result = {}
    local seen = {}

    for name, cmd in pairs(commands) do
        if not cmd.hidden and not seen[cmd.name] then
            table.insert(result, {
                name = cmd.name,
                description = cmd.description,
                usage = cmd.usage,
                aliases = cmd.aliases,
            })
            seen[cmd.name] = true
        end
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- ── Built-in Commands ─────────────────────────────────────────────────

-- /help
CommandRegistry.register("help", function(args)
    print("Available commands:\n")
    local cmds = CommandRegistry.list_commands()
    for _, cmd in ipairs(cmds) do
        local aliases_str = #cmd.aliases > 0 and " (" .. table.concat(cmd.aliases, ", ") .. ")" or ""
        print(string.format("  /%s%s", cmd.name, aliases_str))
        if cmd.description and #cmd.description > 0 then
            print(string.format("    %s", cmd.description))
        end
    end
    print("")
end, {
    description = "Show available commands",
    aliases = {"h", "?"}
})

-- /config
CommandRegistry.register("config", function(args)
    local config = require("config.loader")

    if not args or #args == 0 then
        -- Show all config
        print("Current configuration:\n")
        local cfg = config.get()
        for k, v in pairs(cfg) do
            print(string.format("  %s = %s", k, tostring(v)))
        end
    else
        -- Parse key=value or just key
        local key, value = args:match("([^=]+)=(.+)")
        if key and value then
            -- Set config
            config.set(key, value)
            print(string.format("Set %s = %s", key, value))
        else
            -- Get config
            local val = config.get(args)
            print(string.format("%s = %s", args, tostring(val)))
        end
    end
end, {
    description = "View or modify configuration",
    usage = "/config [key] or /config key=value"
})

-- /model
CommandRegistry.register("model", function(args)
    local config = require("config.loader")

    if not args or #args == 0 then
        local current = config.get("model")
        print(string.format("Current model: %s", current))
        print("\nAvailable models:")
        print("  claude-sonnet-4-5-20250929")
        print("  claude-opus-4-5-20251101")
        print("  claude-3-5-sonnet-20241022")
    else
        config.set("model", args)
        print(string.format("Model set to: %s", args))
    end
end, {
    description = "View or change the model",
    usage = "/model [model-name]"
})

-- /cost
CommandRegistry.register("cost", function(args)
    local app_state = require("state.app_state")
    local usage = app_state.get_usage()

    print(string.format("Token usage:"))
    print(string.format("  Input:  %d tokens", usage.input_tokens))
    print(string.format("  Output: %d tokens", usage.output_tokens))
    print(string.format("  Total cost: $%.4f", usage.total_cost_usd))
end, {
    description = "Show token usage and cost",
})

-- /clear
CommandRegistry.register("clear", function(args)
    local app_state = require("state.app_state")

    app_state.clear_messages()
    app_state.reset_usage()

    -- Clear screen
    os.execute("clear || cls")

    print("Conversation cleared")
end, {
    description = "Clear conversation history",
})

-- /compact
CommandRegistry.register("compact", function(args)
    local config = require("config.loader")
    local current = config.get("compact_mode")
    config.set("compact_mode", not current)

    print(string.format("Compact mode: %s", not current and "enabled" or "disabled"))
end, {
    description = "Toggle compact output mode",
})

-- /thinking
CommandRegistry.register("thinking", function(args)
    local config = require("config.loader")
    local current = config.get("thinking_enabled")
    config.set("thinking_enabled", not current)

    print(string.format("Thinking mode: %s", not current and "enabled" or "disabled"))
end, {
    description = "Toggle thinking/reasoning display",
})

-- /vim
CommandRegistry.register("vim", function(args)
    local config = require("config.loader")
    local current = config.get("vim_mode")
    config.set("vim_mode", not current)

    print(string.format("Vim mode: %s", not current and "enabled" or "disabled"))
    print("(Note: Full vim mode implementation pending)")
end, {
    description = "Toggle vim keybindings",
})

-- /version
CommandRegistry.register("version", function(args)
    print("Jenova CLI v0.1.0 (Lua/C)")
    print("Build: Lua application layer + C core + Rust FFI")
end, {
    description = "Show version information",
    aliases = {"v"}
})

-- /session
CommandRegistry.register("session", function(args)
    local app_state = require("state.app_state")

    print(string.format("Session ID: %s", app_state.get("session_id") or "none"))
    print(string.format("Session dir: %s", app_state.get("session_dir") or "none"))
    print(string.format("Working dir: %s", app_state.get_cwd()))
end, {
    description = "Show current session information",
})

-- /cwd
CommandRegistry.register("cwd", function(args)
    local app_state = require("state.app_state")

    if args and #args > 0 then
        -- Change directory
        local fs = require("utils.fs_fallback")
        
        -- Resolve relative path against current cwd if needed
        local target = args
        if not args:match("^/") and not args:match("^%a:\\") then
            target = app_state.get_cwd() .. "/" .. args
        end
        
        if fs.is_directory(target) then
            app_state.set_cwd(target)
            print(string.format("Changed directory to: %s", target))
        else
            print(string.format("Failed to change directory to: %s", args))
        end
    else
        print(string.format("Current directory: %s", app_state.get_cwd()))
    end
end, {
    description = "Show or change working directory",
    usage = "/cwd [path]",
    aliases = {"cd"}
})

-- /doctor
CommandRegistry.register("doctor", function(args)
    print("Running diagnostics...\n")

    -- Check API key
    local api_key = os.getenv("ANTHROPIC_API_KEY")
    if api_key then
        print("✓ ANTHROPIC_API_KEY is set")
    else
        print("✗ ANTHROPIC_API_KEY is not set")
    end

    -- Check config
    local config = require("config.loader")
    local cfg = config.get()
    if cfg then
        print("✓ Configuration loaded")
    else
        print("✗ Configuration not loaded")
    end

    -- Check tools
    local tool_registry = require("tools.registry")
    local tools = tool_registry.list_tools()
    print(string.format("✓ %d tools available", #tools))

    -- Check Rust FFI
    if jenova and jenova.http then
        print("✓ Rust FFI available (HTTP)")
    else
        print("⚠ Rust FFI not available (HTTP)")
    end

    if jenova and jenova.json then
        print("✓ Rust FFI available (JSON)")
    else
        print("⚠ Rust FFI not available (JSON)")
    end

    print("\nDiagnostics complete")
end, {
    description = "Run environment diagnostics",
})

-- /mcp
CommandRegistry.register("mcp", function(args)
    local subcommand = args:match("^(%S+)")

    if subcommand == "list" then
        print("MCP servers:")
        local config = require("config.loader")
        local servers = config.get("mcp_servers") or {}
        if #servers == 0 then
            print("  (none configured)")
        else
            for _, server in ipairs(servers) do
                print(string.format("  - %s", server.name))
            end
        end
    else
        print("MCP management:")
        print("  /mcp list          List configured MCP servers")
        print("  (Additional MCP features pending)")
    end
end, {
    description = "Manage MCP servers",
    usage = "/mcp <subcommand>"
})

return CommandRegistry
