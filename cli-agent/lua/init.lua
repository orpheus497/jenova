-- init.lua — cli-agent unified bootstrap entry point
-- Loaded by the C host (src/core/main.c) after Lua VM initialization.
--
-- C service bindings are available via the 'jenova' global table:
--   jenova.http, jenova.json, jenova.crypto, jenova.auth, jenova.sandbox,
--   jenova.process, jenova.fs, jenova.mcp, jenova.llama, jenova.agent, jenova.system
--
-- This is the unified agent: combines the legacy agent loop (plan→execute→reflect),
-- the full tool registry, providers, memory, context, and UI into one cohesive system.

local VERSION = "0.2.0"

-- ── CLI Argument Parsing ────────────────────────────────────────────────

local function parse_args(args)
    local opts = {
        print_mode = false,
        prompt = nil,
        output_format = "text",
        model = nil,
        provider = nil,
        verbose = false,
        no_input = false,
        max_turns = nil,
        system_prompt = nil,
        append_system_prompt = nil,
        resume = false,
        session_id = nil,
        mcp_server = false,
        agent_mode = true,
        help = false,
        version = false,
        subcommand = nil,
        subcommand_args = {},
        remaining = {},
    }

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--version" or a == "-V" then
            opts.version = true
        elseif a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--print" or a == "-p" then
            opts.print_mode = true
            if i < #args and args[i + 1]:sub(1, 1) ~= "-" then
                i = i + 1
                opts.prompt = args[i]
            end
        elseif a == "--output-format" then
            i = i + 1
            opts.output_format = args[i] or "text"
        elseif a == "--model" then
            i = i + 1
            opts.model = args[i]
        elseif a == "--provider" then
            i = i + 1
            opts.provider = args[i]
        elseif a == "--verbose" then
            opts.verbose = true
        elseif a == "--no-input" then
            opts.no_input = true
        elseif a == "--max-turns" then
            i = i + 1
            opts.max_turns = tonumber(args[i])
        elseif a == "--system-prompt" then
            i = i + 1
            opts.system_prompt = args[i]
        elseif a == "--append-system-prompt" then
            i = i + 1
            opts.append_system_prompt = args[i]
        elseif a == "--resume" or a == "-r" then
            opts.resume = true
            if i < #args and args[i + 1]:sub(1, 1) ~= "-" then
                i = i + 1
                opts.session_id = args[i]
            end
        elseif a == "--mcp-server" or a == "--mcp" then
            opts.mcp_server = true
        elseif a == "--no-agent" then
            opts.agent_mode = false
        elseif a:sub(1, 1) ~= "-" and not opts.subcommand then
            opts.subcommand = a
        else
            table.insert(opts.remaining, a)
        end
        i = i + 1
    end

    return opts
end

-- ── Fast paths ──────────────────────────────────────────────────────────

local function show_version()
    print("cli-agent " .. VERSION .. " (C + Lua + llama.cpp)")
end

local function show_help()
    print("cli-agent — AI coding agent (pure C + Lua + llama.cpp)")
    print("")
    print("Usage: cli-agent [options] [command]")
    print("")
    print("Options:")
    print("  -p, --print <prompt>      One-shot mode: send prompt and exit")
    print("  -r, --resume [session]    Resume a previous conversation")
    print("  --model <model>           Model to use")
    print("  --provider <provider>     LLM provider (jenova_backend, llamacpp)")
    print("  --output-format <fmt>     Output format: text, json, stream-json")
    print("  --system-prompt <prompt>  Override system prompt")
    print("  --max-turns <n>           Maximum agent turns")
    print("  --mcp-server              Start as MCP server (stdio transport)")
    print("  --no-agent                Disable agentic loop (simple chat)")
    print("  --no-input                Non-interactive mode")
    print("  --verbose                 Verbose output")
    print("  -V, --version             Show version")
    print("  -h, --help                Show this help")
    print("")
    print("Commands:")
    print("  init        Initialize project configuration")
    print("  resume      Resume a previous conversation")
    print("  doctor      Run diagnostics")
    print("  config      View/edit configuration")
    print("  mcp         Manage MCP servers")
    print("")
    print("Interactive commands (use / prefix in REPL):")
    print("  /help, /config, /model, /cost, /compact, /clear, /exit")
    print("  /plan, /debug, /context, /files, /search, /errors, /learn")
    print("  /prefs, /bench, /stats, /diag, /history, /reindex")
end

-- ── Bootstrap & Initialization ──────────────────────────────────────────

local function bootstrap()
    package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

    local subsystems = {
        "config.loader",
        "state.app_state",
        "permissions.manager",
        "context.manager",
        "history.manager",
        "services.memory.manager",
        "cli.commands.registry",
    }

    for _, module_name in ipairs(subsystems) do
        local ok, m = pcall(require, module_name)
        if ok and m and m.init then
            pcall(m.init)
        end
    end

    -- Load command extensions (self-register on require)
    pcall(require, "cli.commands.extended")
    pcall(require, "cli.commands.ported")

    local ok_tools, tool_registry = pcall(require, "tools.registry")
    if ok_tools then
        tool_registry.load_builtin_tools()
    end

    local ok_prov, providers = pcall(require, "providers.init")
    if ok_prov and providers.init then
        pcall(providers.init)
    end

    local ok_plugins, plugins = pcall(require, "plugins.loader")
    if ok_plugins then
        pcall(plugins.load_all)
    end

    local ok_skills, skills = pcall(require, "skills.loader")
    if ok_skills then
        pcall(skills.load_all)
    end

    local _jenova = rawget(_G, "jenova")
    if type(_jenova) == "table" and _jenova.agent and _jenova.agent.init then
        _jenova.agent.init({
            enable_tools = true,
            enable_memory = true,
            context_size = 16384,
            max_turns = 100,
        })
    end
end

-- ── Agent Loop (integrated from legacy-agent) ───────────────────────────

local function run_agent_repl(opts)
    -- Primary path: agent/loop.lua (full UI + QueryEngine)
    local ok_agent, agent_loop = pcall(require, "agent.loop")
    if ok_agent and agent_loop then
        return agent_loop.run(opts)
    end

    -- Secondary path: ui/screens/repl.lua (full UI + QueryEngine)
    local ok_repl, repl_screen = pcall(require, "ui.screens.repl")
    if ok_repl and repl_screen then
        return repl_screen.run(opts)
    end

    -- Fallback: minimal REPL with UI where available
    local ui = nil
    pcall(function() ui = require("agent.ui") end)

    if ui and ui.draw_header then
        io.write("\n")
        ui.draw_header()
        ui.draw_info({ cwd = os.getenv("JENOVA_CWD") or os.getenv("PWD") or "." })
        ui.separator("session")
    else
        print("cli-agent " .. VERSION .. " (C + Lua + llama.cpp)")
        print("Type your message or /help for commands. Ctrl+D to exit.\n")
    end

    local memory = nil
    pcall(function() memory = require("agent.memory") end)

    while true do
        local _is_interrupted = rawget(_G, "is_interrupted")
        if type(_is_interrupted) == "function" and _is_interrupted() then
            if ui then ui.status_warn("interrupted")
            else print("\nInterrupted.") end
            break
        end

        if ui and ui.write_prompt then
            ui.write_prompt()
        else
            io.write("> ")
            io.flush()
        end

        local line = io.read("*l")
        if not line then
            if ui and ui.goodbye then ui.goodbye()
            else print("\nGoodbye!") end
            break
        end

        if line == "/exit" or line == "/quit" or line == "/q" or line == "\3" then
            if ui and ui.goodbye then ui.goodbye()
            else print("Goodbye!") end
            break
        elseif line == "/clear" then
            if memory then memory.clear() end
            if ui then ui.status_ok("cleared")
            else print("Session cleared.") end
        elseif line:sub(1, 1) == "/" then
            local cmd_name = line:match("^/(%S+)")
            local cmd_args = line:match("^/%S+%s+(.*)") or ""
            local ok_reg, cmd_registry = pcall(require, "cli.commands.registry")
            local handler = ok_reg and cmd_registry.get_command(cmd_name) or nil
            if handler then
                pcall(handler, cmd_args)
            else
                if ui then ui.status_err("unknown command: " .. line)
                else print("Unknown command: " .. line) end
            end
        elseif #line > 0 then
            if ui and ui.spinner_start then ui.spinner_start("cognizing") end
            local ok_prov, provider_base = pcall(require, "providers.base")
            if ok_prov then
                local ok_reg, tool_registry = pcall(require, "tools.registry")
                local tools = ok_reg and tool_registry.build_api_tools() or nil
                local response, err = provider_base.generate(line, {
                    model = opts.model,
                    tools = tools,
                    tool_choice = (tools and #tools > 0) and "required" or nil,
                })
                if ui and ui.spinner_stop then ui.spinner_stop() end
                if response then
                    if ui and ui.agent_response then
                        ui.agent_response(type(response) == "table" and response.content or response)
                    else
                        print(type(response) == "table" and response.content or response)
                    end
                else
                    if ui then ui.status_err(tostring(err))
                    else print("[Error: " .. tostring(err) .. "]") end
                end
            else
                if ui and ui.spinner_stop then ui.spinner_stop() end
                if ui then ui.status_err("no AI provider configured")
                else print("[No AI provider configured]") end
            end
        end
    end
    return 0
end

-- ── MCP Server Mode ──────────────────────────────────────────────────

local function run_mcp_server(opts)
    io.stderr:write("cli-agent MCP server started (stdio transport)\n")

    local json = require("utils.json_fallback")
    local tool_registry = require("tools.registry")

    -- MCP clients are expected to mediate permissions themselves — we
    -- must never block tools/call waiting for interactive y/n input on
    -- stdin, which would deadlock the JSON-RPC stream.
    local ok_state, app_state = pcall(require, "state.app_state")
    if ok_state and app_state and app_state.set then
        app_state.set("permission_mode", "bypassPermissions")
    end

    while true do
        local line = io.read("*l")
        if not line then break end
        if #line == 0 then goto continue end

        local ok_parse, request = pcall(json.parse, line)
        if not ok_parse or type(request) ~= "table" then
            io.write(json.stringify({
                jsonrpc = "2.0",
                error = { code = -32700, message = "Parse error" },
                id = nil,
            }) .. "\n")
            io.flush()
            goto continue
        end

        local method = request.method
        local id = request.id

        if method == "initialize" then
            local tools = tool_registry.get_all()
            local tool_list = {}
            for _, tool in ipairs(tools) do
                table.insert(tool_list, {
                    name = tool.name,
                    description = type(tool.description) == "function"
                        and tool.description({}) or (tool.description or ""),
                    inputSchema = tool.parameters or { type = "object", properties = {} },
                })
            end

            io.write(json.stringify({
                jsonrpc = "2.0",
                id = id,
                result = {
                    protocolVersion = "2024-11-05",
                    capabilities = { tools = { listChanged = false } },
                    serverInfo = { name = "cli-agent", version = VERSION },
                    tools = tool_list,
                },
            }) .. "\n")
            io.flush()

        elseif method == "tools/list" then
            local tools = tool_registry.get_all()
            local tool_list = {}
            for _, tool in ipairs(tools) do
                table.insert(tool_list, {
                    name = tool.name,
                    description = type(tool.description) == "function"
                        and tool.description({}) or (tool.description or ""),
                    inputSchema = tool.parameters or { type = "object", properties = {} },
                })
            end
            io.write(json.stringify({
                jsonrpc = "2.0", id = id,
                result = { tools = tool_list },
            }) .. "\n")
            io.flush()

        elseif method == "tools/call" then
            local params = request.params or {}
            local tool_name = params.name
            local arguments = params.arguments or {}

            local result, err = tool_registry.execute(tool_name, arguments)
            local response
            if err then
                response = { jsonrpc = "2.0", id = id,
                    result = { content = { { type = "text", text = "Error: " .. err } }, isError = true } }
            else
                local text = type(result) == "string" and result or json.stringify(result)
                response = { jsonrpc = "2.0", id = id,
                    result = { content = { { type = "text", text = text } } } }
            end
            io.write(json.stringify(response) .. "\n")
            io.flush()

        elseif method == "ping" then
            io.write(json.stringify({ jsonrpc = "2.0", id = id, result = {} }) .. "\n")
            io.flush()

        elseif method ~= "notifications/initialized" then
            io.write(json.stringify({
                jsonrpc = "2.0", id = id,
                error = { code = -32601, message = "Method not found: " .. tostring(method) },
            }) .. "\n")
            io.flush()
        end

        ::continue::
    end

    io.stderr:write("cli-agent MCP server stopped\n")
    return 0
end

-- ── Main ────────────────────────────────────────────────────────────────

local function main()
    local cli_args = arg or {}
    local opts = parse_args(cli_args)

    if opts.version then show_version(); return 0 end
    if opts.help then show_help(); return 0 end

    bootstrap()

    local ok_config, config = pcall(require, "config.loader")
    if ok_config and config.load then
        config.load()
        if opts.provider then config.set("provider", opts.provider) end
    end

    if opts.mcp_server then
        return run_mcp_server(opts)
    end

    if opts.print_mode and opts.prompt then
        local ok_prov, provider_base = pcall(require, "providers.base")
        if ok_prov then
            local response, err = provider_base.generate(opts.prompt, {
                model = opts.model,
                system_prompt = opts.system_prompt,
            })
            if response then print(type(response) == "table" and response.content or response) else io.stderr:write("Error: " .. tostring(err) .. "\n"); return 1 end
        end
        return 0
    end

    if opts.subcommand then
        local cmd_path = "cli.commands." .. opts.subcommand:gsub("-", "_")
        local ok_cmd, cmd = pcall(require, cmd_path)
        if ok_cmd and cmd and cmd.run then
            return cmd.run(opts.subcommand_args) or 0
        else
            io.stderr:write("Unknown command: " .. opts.subcommand .. "\n")
            return 1
        end
    end

    return run_agent_repl(opts)
end

local exit_code = main()
if exit_code and exit_code ~= 0 then
    os.exit(exit_code)
end
