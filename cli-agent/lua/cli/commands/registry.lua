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
        print("\nAvailable models (set by local backend):")
        print("  auto  — let the backend select (default)")
        print("  Set JENOVA_MODEL env var to prefer a specific GGUF model")
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

    -- Check local backend
    local jenova_http_ok = jenova and jenova.http ~= nil
    if jenova_http_ok then
        print("✓ jenova.http available (local backend)")
    else
        print("⚠ jenova.http not available")
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

-- /history
CommandRegistry.register("history", function(args)
    local history = require("history.manager")
    local subcommand = args and args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local count = (args and tonumber(args:match("^%S+%s+(%d+)"))) or 20
        local items = history.get_recent(count)
        if #items == 0 then
            print("No history entries.")
            return
        end
        print(string.format("Recent history (%d items):\n", #items))
        for i, item in ipairs(items) do
            local timestamp = os.date("%Y-%m-%d %H:%M:%S", item.timestamp)
            print(string.format("%d. [%s] %s", i, timestamp, item.content))
        end
    elseif subcommand == "search" then
        local query = args:match("^%S+%s+(.+)")
        if not query then print("Usage: /history search <query>"); return end
        local results = history.search(query)
        if #results == 0 then print("No results found."); return end
        print(string.format("Found %d results:\n", #results))
        for i, item in ipairs(results) do
            print(string.format("%d. %s", i, item.content))
        end
    elseif subcommand == "clear" then
        history.clear()
        print("History cleared.")
    else
        print("History commands:")
        print("  /history [list] [count]  List recent history")
        print("  /history search <query>  Search history")
        print("  /history clear           Clear history")
    end
end, {
    description = "Manage conversation history",
    usage = "/history [list|search|clear]",
})

-- /context
CommandRegistry.register("context", function(args)
    local context = require("context.manager")
    print(context.build_context_string())
end, {
    description = "Show system and user context",
})

-- /files
CommandRegistry.register("files", function(args)
    local app_state = require("state.app_state")
    local cwd = app_state.get_cwd()
    local pattern = (args and #args > 0) and args or "**/*"

    if jenova and jenova.fs and jenova.fs.glob then
        local json = require("utils.json_fallback")
        local result = jenova.fs.glob(pattern, cwd, 50)
        if result then
            local ok, files = pcall(json.parse, result)
            if ok and type(files) == "table" and #files > 0 then
                print(string.format("Files matching '%s' (%d results):\n", pattern, #files))
                for _, f in ipairs(files) do
                    print("  " .. tostring(f))
                end
                return
            end
        end
        print("No files found.")
    else
        -- Fallback: shell ls
        local out = io.popen("ls -1 " .. cwd .. " 2>/dev/null")
        if out then
            print(string.format("Files in %s:\n", cwd))
            for line in out:lines() do
                print("  " .. line)
            end
            out:close()
        end
    end
end, {
    description = "List files in working directory",
    usage = "/files [glob-pattern]",
})

-- /search
CommandRegistry.register("search", function(args)
    if not args or #args == 0 then
        print("Usage: /search <query>")
        print("  Searches conversation history and memory for <query>.")
        return
    end

    local history = require("history.manager")
    local results = history.search(args)

    if #results == 0 then
        print(string.format("No results found for: %s", args))
    else
        print(string.format("Found %d result(s) for '%s':\n", #results, args))
        for i, item in ipairs(results) do
            local ts = item.timestamp and os.date("%Y-%m-%d %H:%M", item.timestamp) or ""
            print(string.format("%d. [%s] %s", i, ts, item.content))
        end
    end
end, {
    description = "Search conversation history",
    usage = "/search <query>",
})

-- /errors
CommandRegistry.register("errors", function(args)
    local memory = require("services.memory.manager")
    local formatted = memory.format_errors_for_prompt(20)
    if not formatted or #formatted == 0 then
        print("No errors recorded this session.")
    else
        print(formatted)
    end
end, {
    description = "Show errors from this session",
})

-- /plan
CommandRegistry.register("plan", function(args)
    local config = require("config.loader")
    local current = config.get("permission_mode")

    if not args or #args == 0 then
        if current == "plan" then
            config.set("permission_mode", "default")
            print("Plan mode: disabled (switched to default)")
        else
            config.set("permission_mode", "plan")
            print("Plan mode: enabled")
            print("  Only read-only tools are auto-approved")
            print("  Write tools require explicit permission")
        end
    elseif args == "on" then
        config.set("permission_mode", "plan")
        print("Plan mode: enabled")
    elseif args == "off" then
        config.set("permission_mode", "default")
        print("Plan mode: disabled")
    else
        print("Plan mode: toggle read-only exploration mode")
        print("Usage: /plan [on|off]")
        print(string.format("Current: %s", current == "plan" and "enabled" or "disabled"))
    end
end, {
    description = "Toggle plan/exploration mode (read-only tools auto-approved)",
    usage = "/plan [on|off]",
})

-- /stats
CommandRegistry.register("stats", function(args)
    local app_state = require("state.app_state")
    local config = require("config.loader")
    local tool_registry = require("tools.registry")

    print("Jenova CLI Statistics:\n")
    print(string.format("  Provider:  %s", config.get("provider") or "llamacpp"))
    print(string.format("  Model:     %s", config.get("model") or "auto"))
    print(string.format("  Tools:     %d registered", #tool_registry.get_names()))

    if jenova and jenova.system then
        if jenova.system.platform then
            print(string.format("  Platform:  %s", jenova.system.platform()))
        end
        if jenova.system.version then
            print(string.format("  Version:   %s", jenova.system.version()))
        end
    end

    print("\n  FFI Bindings:")
    local bindings = { "http", "json", "crypto", "fs", "llama", "system", "process", "mcp" }
    for _, name in ipairs(bindings) do
        local available = jenova and jenova[name] ~= nil
        print(string.format("    jenova.%-8s %s", name .. ":", available and "✓" or "✗"))
    end

    local usage = app_state.get_usage()
    print("\n  Session:")
    print(string.format("    Messages:       %d", #(app_state.get_messages() or {})))
    print(string.format("    Input tokens:   %d", usage.input_tokens))
    print(string.format("    Output tokens:  %d", usage.output_tokens))
    print(string.format("    Cost:           $%.4f", usage.total_cost_usd))
end, {
    description = "Show detailed CLI statistics",
})

-- /diag
CommandRegistry.register("diag", function(args)
    print("Running diagnostics...\n")

    -- API keys
    local keys = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY" }
    for _, k in ipairs(keys) do
        if os.getenv(k) then
            print(string.format("✓ %s is set", k))
        else
            print(string.format("✗ %s is not set", k))
        end
    end

    -- Config
    local ok_cfg, config = pcall(require, "config.loader")
    print(ok_cfg and "✓ Configuration loaded" or "✗ Configuration failed to load")

    -- Providers
    local ok_prov, provider_base = pcall(require, "providers.base")
    print(ok_prov and "✓ providers.base loaded" or "✗ providers.base failed to load")

    -- Tools
    local ok_tr, tool_registry = pcall(require, "tools.registry")
    if ok_tr then
        print(string.format("✓ %d tools available", #tool_registry.get_names()))
    else
        print("✗ tools registry failed to load")
    end

    -- FFI
    local bindings = { "http", "json", "fs", "llama", "system", "process", "mcp" }
    print("\n  FFI:")
    for _, name in ipairs(bindings) do
        local available = jenova and jenova[name] ~= nil
        print(string.format("  %s jenova.%s", available and "✓" or "✗", name))
    end

    -- Memory/session errors
    local ok_mem, memory = pcall(require, "services.memory.manager")
    if ok_mem then
        local errs = memory.format_errors_for_prompt(5)
        if errs and #errs > 0 then
            print("\n  Recent errors:")
            print(errs)
        else
            print("\n✓ No session errors recorded")
        end
    end

    print("\nDiagnostics complete.")
end, {
    description = "Run full environment diagnostics",
    aliases = { "diagnostics" },
})

-- /provider
CommandRegistry.register("provider", function(args)
    local config = require("config.loader")
    local subcommand = args and args:match("^(%S+)")

    if not subcommand or subcommand == "show" then
        local current = config.get("provider") or "llamacpp"
        print(string.format("Current provider: %s\n", current))
        print("Available providers:")
        print("  llamacpp      Local llama.cpp inference (default)")
        print("  anthropic     Anthropic Claude API")
        print("  openai        OpenAI API")
        print("  gemini        Google Gemini API")
        print("  openrouter    OpenRouter API")
        print("  jenova        Jenova backend")
    elseif subcommand == "set" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then print("Usage: /provider set <provider-name>"); return end
        local valid = { llamacpp=true, jenova_backend=true }
        if valid[name] then
            config.set("provider", name)
            print(string.format("Provider set to: %s", name))
        else
            print(string.format("Unknown provider: %s", name))
            print("Valid providers: jenova_backend, llamacpp")
        end
    elseif subcommand == "test" then
        local provider_name = args:match("^%S+%s+(%S+)")
            or (config and config.get("provider")) or "llamacpp"
        print(string.format("Testing provider: %s ...", provider_name))
        local ok2, prov = pcall(require, "providers." .. provider_name)
        if ok2 and prov and prov.test then
            local success = pcall(prov.test)
            print(success and "✓ Provider is working" or "✗ Provider test failed")
        else
            print(string.format("⚠ Provider '%s' has no test function or failed to load", provider_name))
        end
    else
        print("Provider commands:")
        print("  /provider              Show current provider")
        print("  /provider set <name>   Switch active provider")
        print("  /provider test [name]  Test a provider connection")
    end
end, {
    description = "Manage LLM providers",
    usage = "/provider [show|set|test] [name]",
})

-- /tools
CommandRegistry.register("tools", function(args)
    local tool_registry = require("tools.registry")
    local subcommand = args and args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local names = tool_registry.get_names()
        print(string.format("Registered tools (%d):\n", #names))
        local all = tool_registry.get_all()
        for _, tool in ipairs(all) do
            local desc = type(tool.description) == "function"
                and tool.description({}) or (tool.description or "")
            if #desc > 60 then desc = desc:sub(1, 57) .. "..." end
            print(string.format("  %-20s %s", tool.name, desc))
        end
    elseif subcommand == "info" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then print("Usage: /tools info <tool-name>"); return end
        local tool = tool_registry.get(name)
        if tool then
            local desc = type(tool.description) == "function"
                and tool.description({}) or (tool.description or "")
            print(string.format("Tool: %s", tool.name))
            print(string.format("Description: %s", desc))
            if tool.input_schema then
                local json = require("utils.json_fallback")
                local ok2, schema_str = pcall(json.stringify, tool.input_schema, { pretty = true })
                if ok2 then print(string.format("Input schema:\n%s", schema_str)) end
            end
        else
            print(string.format("Tool not found: %s", name))
        end
    else
        print("Tool commands:")
        print("  /tools              List all registered tools")
        print("  /tools info <name>  Show tool details and schema")
    end
end, {
    description = "List and inspect registered tools",
    usage = "/tools [list|info] [name]",
})

-- /quit
CommandRegistry.register("quit", function(args)
    print("Goodbye!")
    os.exit(0)
end, {
    description = "Exit the CLI",
    aliases = { "exit", "q" },
})

return CommandRegistry
