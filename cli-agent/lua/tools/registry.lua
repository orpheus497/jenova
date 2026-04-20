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

--- Load all built-in tools
function M.load_builtin_tools()
    local tool_modules = {
        "tools.bash", "tools.file_read", "tools.file_write", "tools.file_edit",
        "tools.glob", "tools.grep", "tools.agent", "tools.web_fetch",
        "tools.web_search", "tools.ask_user", "tools.todo_write",
        "tools.notebook_edit", "tools.skill", "tools.brief",
        "tools.enter_plan_mode", "tools.exit_plan_mode",
        "tools.mcp_tool", "tools.mcp_auth",
        "tools.list_mcp_resources", "tools.read_mcp_resource",
        "tools.task_create", "tools.task_get", "tools.task_list",
        "tools.task_update", "tools.task_stop", "tools.task_output",
        "tools.send_message", "tools.tool_search",
        "tools.sleep", "tools.config_tool", "tools.synthetic_output",
        "tools.lsp", "tools.repl", "tools.powershell", "tools.snip",
        "tools.verify_plan", "tools.enter_worktree", "tools.exit_worktree",
        "tools.schedule_cron", "tools.remote_trigger",
        "tools.team_create", "tools.team_delete",
        "tools.local_search",
    }

    for _, mod_name in ipairs(tool_modules) do
        local ok, tool = pcall(require, mod_name)
        if ok and tool and tool.name then
            M.register(tool)
        end
    end
end

return M
