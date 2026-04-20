-- tools/registry.lua — Tool registry and dispatch
-- Manages all available tools, filtering by permissions and feature flags.

local M = {}

-- Registered tools
local tools = {}

--- Register a tool module
function M.register(tool)
    assert(tool.name, "Tool must have a name")
    assert(tool.call, "Tool must have a call function")
    tools[tool.name] = tool
end

--- Get a tool by name
function M.get(name)
    return tools[name]
end

--- Alias for get() — compatibility with QueryEngine callers
function M.get_tool(name)
    return tools[name]
end

--- List all tool names (alias for get_names)
function M.list_tools()
    return M.get_names()
end

--- Get all registered tools
function M.get_all()
    local result = {}
    for _, tool in pairs(tools) do
        if not tool.is_enabled or tool.is_enabled() then
            table.insert(result, tool)
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--- Get tool names
function M.get_names()
    local names = {}
    for name, tool in pairs(tools) do
        if not tool.is_enabled or tool.is_enabled() then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

--- Filter tools by permission context
function M.filter_by_permissions(permission_context)
    local result = {}
    for _, tool in pairs(tools) do
        local enabled = not tool.is_enabled or tool.is_enabled()
        if enabled then
            table.insert(result, tool)
        end
    end
    return result
end

--- Execute a tool by name
function M.execute(name, args, context)
    local tool = tools[name]
    if not tool then
        return nil, "Unknown tool: " .. name
    end

    -- Check permissions
    if tool.check_permissions then
        local perm = tool.check_permissions(args, context)
        if perm and not perm.allowed then
            return nil, "Permission denied: " .. (perm.reason or "")
        end
    end

    -- Execute — always forward context so tools can access cwd, session, etc.
    local ok, result = pcall(tool.call, args, context or {})
    if not ok then
        return nil, "Tool error: " .. tostring(result)
    end
    return result
end

--- Build tool definitions for API (JSON Schema format)
function M.build_api_tools()
    local api_tools = {}
    for _, tool in pairs(tools) do
        if not tool.is_enabled or tool.is_enabled() then
            table.insert(api_tools, {
                name = tool.name,
                description = type(tool.description) == "function"
                    and tool.description({}) or tool.description,
                input_schema = tool.input_schema,
            })
        end
    end
    return api_tools
end

--- Load all built-in tools, gated by category and environment availability.
-- Core filesystem/search tools are always loaded. Specialized tools (MCP,
-- tasks, LSP, scheduling, web, powershell, remote) are loaded only when
-- the required runtime is present, reducing prompt token usage.
function M.load_builtin_tools()
    -- Always-on: core file, code and search operations
    local core_tools = {
        "tools.bash", "tools.file_read", "tools.file_write", "tools.file_edit",
        "tools.glob", "tools.grep", "tools.ask_user", "tools.todo_write",
        "tools.brief", "tools.enter_plan_mode", "tools.exit_plan_mode",
        "tools.verify_plan", "tools.tool_search", "tools.config_tool",
        "tools.synthetic_output", "tools.sleep",
    }

    -- Web tools: load when network is expected to be available
    local web_tools = {
        "tools.web_fetch", "tools.web_search",
    }

    -- MCP tools: only load when an MCP server is configured
    local mcp_tools = {
        "tools.mcp_tool", "tools.mcp_auth",
        "tools.list_mcp_resources", "tools.read_mcp_resource",
    }

    -- Task/team/agent orchestration: load when multi-agent mode is enabled
    local orchestration_tools = {
        "tools.agent", "tools.task_create", "tools.task_get", "tools.task_list",
        "tools.task_update", "tools.task_stop", "tools.task_output",
        "tools.send_message", "tools.team_create", "tools.team_delete",
    }

    -- LSP tools: load when LSP bindings or a known LSP client is present
    local lsp_tools = {
        "tools.lsp",
    }

    -- Dev environment tools
    local dev_tools = {
        "tools.notebook_edit", "tools.skill", "tools.snip",
        "tools.repl", "tools.local_search",
        "tools.enter_worktree", "tools.exit_worktree",
    }

    -- Platform-specific: PowerShell (Windows / pwsh available)
    local platform_tools = {
        "tools.powershell",
    }

    -- Scheduling / remote: only when explicitly needed
    local automation_tools = {
        "tools.schedule_cron", "tools.remote_trigger",
    }

    local function load_set(set)
        for _, mod_name in ipairs(set) do
            local ok, tool = pcall(require, mod_name)
            if ok and tool and tool.name then
                M.register(tool)
            end
        end
    end

    -- Core always loads
    load_set(core_tools)

    -- Web: load unless explicitly disabled
    local ok_config, config = pcall(require, "config.loader")
    local no_network = ok_config and config.get("no_network") or false
    if not no_network then
        load_set(web_tools)
    end

    -- MCP: load when mcp_servers config exists or MCP binding present
    local _jenova = rawget(_G, "jenova")
    local has_mcp = (type(_jenova) == "table" and _jenova.mcp ~= nil)
    if not has_mcp and ok_config then
        local mcp_servers = config.get("mcp_servers")
        has_mcp = type(mcp_servers) == "table" and next(mcp_servers) ~= nil
    end
    if has_mcp then
        load_set(mcp_tools)
    end

    -- LSP: load when jenova.lsp binding or LSP client is present
    local has_lsp = (type(_jenova) == "table" and _jenova.lsp ~= nil)
    if has_lsp then
        load_set(lsp_tools)
    end

    -- Orchestration: load when multi-agent or tasks feature is enabled
    local enable_tasks = ok_config and (config.get("enable_tasks") ~= false) or true
    if enable_tasks then
        load_set(orchestration_tools)
    end

    -- Dev tools: always load
    load_set(dev_tools)

    -- PowerShell: only when pwsh or powershell binary is present
    local pwsh_check = io.popen("pwsh --version 2>/dev/null || powershell -Version 2>/dev/null", "r")
    if pwsh_check then
        local out = pwsh_check:read("*l")
        pwsh_check:close()
        if out and #out > 0 then
            load_set(platform_tools)
        end
    end

    -- Automation: load when cron or remote config is present
    local enable_cron = ok_config and config.get("enable_cron") or false
    local enable_remote = ok_config and config.get("enable_remote") or false
    if enable_cron or enable_remote then
        load_set(automation_tools)
    end
end

return M
