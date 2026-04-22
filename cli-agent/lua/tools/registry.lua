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
                parameters = tool.parameters,
            })
        end
    end
    return api_tools
end

--- Load built-in tools for the Jenova CLI.
-- Core tools (file ops, search, shell, planning) always load.
-- MCP and LSP tools load only when the respective runtime is present.
-- Web tools load unless the user has disabled network access.
function M.load_builtin_tools()
    -- Core: always loaded — focused on coding and document work.
    -- Deliberately minimal: local models perform best with a small, clear tool set.
    local core_tools = {
        "tools.file_read", "tools.file_write", "tools.file_edit",
        "tools.multiedit",
        "tools.glob", "tools.grep", "tools.local_search",
        "tools.bash",
        "tools.brief",
    }

    -- Optional extras: only loaded when explicitly enabled in config.
    -- `enable_extended_tools: true`  — adds AskUser, TodoWrite, plan-mode tools
    -- `enable_web: true`             — adds WebSearch, WebFetch
    local extended_tools = {
        "tools.ask_user",
        "tools.todo_write",
        "tools.enter_plan_mode", "tools.exit_plan_mode", "tools.verify_plan",
    }

    local web_tools = {
        "tools.web_fetch", "tools.web_search",
    }

    -- MCP: only when jenova.mcp binding is present or mcp_servers is configured
    local mcp_tools = {
        "tools.mcp_tool", "tools.mcp_auth",
        "tools.list_mcp_resources", "tools.read_mcp_resource",
    }

    -- LSP: only when jenova.lsp binding is present
    local lsp_tools = {
        "tools.lsp",
    }

    local function load_set(set)
        for _, mod_name in ipairs(set) do
            local ok, tool = pcall(require, mod_name)
            if ok and tool and tool.name then
                M.register(tool)
            end
        end
    end

    load_set(core_tools)

    local ok_config, config = pcall(require, "config.loader")

    -- Extended tools: opt-in only
    local enable_extended = ok_config and config.get("enable_extended_tools") or false
    if enable_extended then
        load_set(extended_tools)
    end

    -- Web tools: opt-in only
    local enable_web = ok_config and config.get("enable_web") or false
    if enable_web then
        load_set(web_tools)
    end

    local _jenova = rawget(_G, "jenova")
    local has_mcp = (type(_jenova) == "table" and _jenova.mcp ~= nil)
    if not has_mcp and ok_config then
        local mcp_servers = config.get("mcp_servers")
        has_mcp = type(mcp_servers) == "table" and next(mcp_servers) ~= nil
    end
    if has_mcp then
        load_set(mcp_tools)
    end

    local has_lsp = (type(_jenova) == "table" and _jenova.lsp ~= nil)
    if has_lsp then
        load_set(lsp_tools)
    end

    -- Git: only when working directory is inside a git repository.
    -- Avoids advertising a tool that will always fail in non-repo contexts,
    -- and keeps the tool list lean for models running without git.
    local h = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
    local is_git = h and h:read("*l") == "true"
    if h then h:close() end
    if is_git then
        load_set({ "tools.git" })
    end
end

return M
