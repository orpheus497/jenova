-- cli/commands/registry.lua — Slash command registry

local CommandRegistry = {}

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

CommandRegistry.register("help", function(_)
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

CommandRegistry.register("config", function(args)
    local config = require("config.loader")

    if not args or #args == 0 then
        print("Current configuration:\n")
        local cfg = config.get()
        for k, v in pairs(cfg) do
            print(string.format("  %s = %s", k, tostring(v)))
        end
    else
        local key, value = args:match("([^=]+)=(.+)")
        if key and value then
            config.set(key, value)
            print(string.format("Set %s = %s", key, value))
        else
            local val = config.get(args)
            print(string.format("%s = %s", args, tostring(val)))
        end
    end
end, {
    description = "View or modify configuration",
    usage = "/config [key] or /config key=value"
})

CommandRegistry.register("clear", function(_)
    local app_state = require("state.app_state")
    app_state.clear_messages()
    app_state.reset_usage()
    os.execute("clear")
    print("Conversation cleared")
end, {
    description = "Clear conversation history and screen",
})

CommandRegistry.register("compact", function(_)
    local config = require("config.loader")
    local current = config.get("compact_mode")
    config.set("compact_mode", not current)
    print(string.format("Compact mode: %s", not current and "enabled" or "disabled"))
end, {
    description = "Toggle compact output mode",
})

CommandRegistry.register("thinking", function(_)
    local config = require("config.loader")
    local current = config.get("thinking_enabled")
    config.set("thinking_enabled", not current)
    print(string.format("Thinking mode: %s", not current and "enabled" or "disabled"))
end, {
    description = "Toggle reasoning/thinking display",
})

CommandRegistry.register("version", function(_)
    print("Jenova CLI v0.2.0 (C + Lua + llama.cpp)")
    print("Backend: jenova proxy + llama-server")
end, {
    description = "Show version",
    aliases = {"v"}
})

CommandRegistry.register("session", function(_)
    local app_state = require("state.app_state")
    print(string.format("Session ID: %s", app_state.get("session_id") or "none"))
    print(string.format("Session dir: %s", app_state.get("session_dir") or "none"))
    print(string.format("Working dir: %s", app_state.get_cwd()))
    local tag = app_state.get("session_tag")
    if tag then print(string.format("Tag: #%s", tag)) end
end, {
    description = "Show current session information",
})

CommandRegistry.register("cwd", function(args)
    local app_state = require("state.app_state")

    if args and #args > 0 then
        local fs = require("utils.fs_fallback")
        local target = args
        if not args:match("^/") then
            target = app_state.get_cwd() .. "/" .. args
        end
        if fs.is_directory(target) then
            app_state.set_cwd(target)
            print(string.format("Changed directory to: %s", target))
        else
            print(string.format("Not a directory: %s", args))
        end
    else
        print(string.format("Current directory: %s", app_state.get_cwd()))
    end
end, {
    description = "Show or change working directory",
    usage = "/cwd [path]",
    aliases = {"cd"}
})

-- /doctor — consolidated diagnostics (replaces /diag and old /doctor)
CommandRegistry.register("doctor", function(_)
    print("Jenova diagnostics\n")

    local _jenova = rawget(_G, "jenova")

    local bindings = { "http", "json", "fs", "llama", "system", "process", "mcp", "crypto", "sandbox" }
    print("  FFI bindings:")
    for _, name in ipairs(bindings) do
        local available = type(_jenova) == "table" and _jenova[name] ~= nil
        print(string.format("    %s jenova.%s", available and "✓" or "✗", name))
    end
    print("")

    local ok_cfg, config = pcall(require, "config.loader")
    print(ok_cfg and "✓ Configuration loaded" or "✗ Configuration failed to load")

    local ok_prov = pcall(require, "providers.base")
    print(ok_prov and "✓ Provider system loaded" or "✗ Provider system failed to load")

    local ok_tr, tool_registry = pcall(require, "tools.registry")
    if ok_tr then
        print(string.format("✓ %d tools registered", #tool_registry.get_names()))
    else
        print("✗ Tool registry failed to load")
    end

    if ok_cfg then
        local provider = config.get("provider") or "jenova_backend"
        local endpoint = config.get("api_url") or "http://127.0.0.1:8080"
        print(string.format("  Provider: %s  Endpoint: %s", provider, endpoint))
    end

    local ok_mem, memory = pcall(require, "services.memory.manager")
    if ok_mem then
        local errs = memory.format_errors_for_prompt(5)
        if errs and #errs > 0 then
            print("\n  Recent session errors:")
            print(errs)
        else
            print("✓ No session errors recorded")
        end
    end

    print("\nDiagnostics complete.")
end, {
    description = "Run full environment diagnostics",
    aliases = { "diag", "diagnostics" },
})

CommandRegistry.register("mcp", function(args)
    local subcommand = args and args:match("^(%S+)")

    if subcommand == "list" then
        print("MCP servers:")
        local config = require("config.loader")
        local servers = config.get("mcp_servers") or {}
        if type(servers) ~= "table" or not next(servers) then
            print("  (none configured)")
        else
            for _, server in ipairs(servers) do
                print(string.format("  - %s", server.name or tostring(server)))
            end
        end
    else
        print("MCP commands:")
        print("  /mcp list    List configured MCP servers")
    end
end, {
    description = "Manage MCP servers",
    usage = "/mcp [list]"
})

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
        print("Usage: /history [list [count] | search <query> | clear]")
    end
end, {
    description = "Manage conversation history",
    usage = "/history [list|search|clear]",
})

CommandRegistry.register("context", function(_)
    local context = require("context.manager")
    print(context.build_context_string())
    local user_ctx = context.get_user_context()
    if user_ctx then
        print(string.format("  User: %s  Home: %s  Shell: %s",
            user_ctx.username or "?", user_ctx.home_directory or "?", user_ctx.shell or "?"))
    end
end, {
    description = "Show system and user context",
})

CommandRegistry.register("files", function(args)
    local app_state = require("state.app_state")
    local cwd = app_state.get_cwd()
    local pattern = (args and #args > 0) and args or "**/*"
    local _jenova = rawget(_G, "jenova")

    if type(_jenova) == "table" and _jenova.fs and _jenova.fs.glob then
        local json = require("utils.json_fallback")
        local result = _jenova.fs.glob(pattern, cwd, 50)
        if result then
            local ok, files = pcall(json.parse, result)
            if ok and type(files) == "table" and #files > 0 then
                print(string.format("Files matching '%s' (%d):\n", pattern, #files))
                for _, f in ipairs(files) do print("  " .. tostring(f)) end
                return
            end
        end
        print("No files found.")
    else
        local shell = require("utils.shell")
        local out = io.popen("ls -1 " .. shell.quote(cwd) .. " 2>/dev/null")
        if out then
            print(string.format("Files in %s:\n", cwd))
            for line in out:lines() do print("  " .. line) end
            out:close()
        end
    end
end, {
    description = "List files in working directory",
    usage = "/files [glob-pattern]",
})

CommandRegistry.register("search", function(args)
    if not args or #args == 0 then
        print("Usage: /search <query>")
        return
    end
    local history = require("history.manager")
    local results = history.search(args)
    if #results == 0 then
        print(string.format("No results for: %s", args))
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

CommandRegistry.register("errors", function(_)
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

CommandRegistry.register("plan", function(args)
    local config = require("config.loader")
    local current = config.get("permission_mode")

    if not args or #args == 0 then
        if current == "plan" then
            config.set("permission_mode", "default")
            print("Plan mode: disabled")
        else
            config.set("permission_mode", "plan")
            print("Plan mode: enabled (read-only tools auto-approved)")
        end
    elseif args == "on" then
        config.set("permission_mode", "plan")
        print("Plan mode: enabled")
    elseif args == "off" then
        config.set("permission_mode", "default")
        print("Plan mode: disabled")
    else
        print(string.format("Plan mode: %s", current == "plan" and "enabled" or "disabled"))
        print("Usage: /plan [on|off]")
    end
end, {
    description = "Toggle plan mode (read-only tools auto-approved)",
    usage = "/plan [on|off]",
})

-- /stats — consolidated session stats (replaces /summary and /insights)
CommandRegistry.register("stats", function(_)
    local app_state = require("state.app_state")
    local config = require("config.loader")
    local tool_registry = require("tools.registry")

    local messages = app_state.get_messages() or {}
    local usage = app_state.get_usage()

    local user_msgs, assistant_msgs, tool_uses = 0, 0, 0
    local total_chars = 0
    for _, m in ipairs(messages) do
        if m.role == "user" then user_msgs = user_msgs + 1 end
        if m.role == "assistant" then assistant_msgs = assistant_msgs + 1 end
        if type(m.content) == "table" then
            for _, b in ipairs(m.content) do
                if type(b) == "table" and b.type == "tool_use" then tool_uses = tool_uses + 1 end
                if type(b) == "table" and b.type == "text" and b.text then
                    total_chars = total_chars + #b.text
                end
            end
        elseif type(m.content) == "string" then
            total_chars = total_chars + #m.content
        end
    end

    print("Session stats:")
    print(string.format("  Session:          %s", app_state.get("session_id") or "none"))
    local tag = app_state.get("session_tag")
    if tag then print(string.format("  Tag:              #%s", tag)) end
    print(string.format("  Working dir:      %s", app_state.get_cwd()))
    print(string.format("  Provider:         %s", config.get("provider") or "jenova_backend"))
    print(string.format("  Tools registered: %d", #tool_registry.get_names()))
    print(string.format("  User turns:       %d", user_msgs))
    print(string.format("  Assistant turns:  %d", assistant_msgs))
    print(string.format("  Tool uses:        %d", tool_uses))
    print(string.format("  Input tokens:     %d", usage.input_tokens))
    print(string.format("  Output tokens:    %d", usage.output_tokens))
    if user_msgs > 0 then
        print(string.format("  Avg tokens/turn:  %.1f",
            (usage.input_tokens + usage.output_tokens) / user_msgs))
    end
end, {
    description = "Show session statistics",
    aliases = { "summary", "insights" },
})

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
            print(string.format("  %-22s %s", tool.name, desc))
        end
    elseif subcommand == "info" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then print("Usage: /tools info <name>"); return end
        local tool = tool_registry.get(name)
        if tool then
            local desc = type(tool.description) == "function"
                and tool.description({}) or (tool.description or "")
            print(string.format("Tool: %s\nDescription: %s", tool.name, desc))
            if tool.input_schema then
                local json = require("utils.json_fallback")
                local ok2, schema_str = pcall(json.stringify, tool.input_schema, { pretty = true })
                if ok2 then print("Input schema:\n" .. schema_str) end
            end
        else
            print(string.format("Tool not found: %s", name))
        end
    else
        print("Usage: /tools [list | info <name>]")
    end
end, {
    description = "List and inspect registered tools",
    usage = "/tools [list|info] [name]",
})

CommandRegistry.register("quit", function(_)
    print("Goodbye!")
    os.exit(0)
end, {
    description = "Exit the CLI",
    aliases = { "exit", "q" },
})

return CommandRegistry
