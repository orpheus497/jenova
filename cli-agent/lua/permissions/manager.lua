-- permissions/manager.lua — Tool permission management
-- Equivalent to src/hooks/toolPermission/

local config = require("config.loader")
local app_state = require("state.app_state")

local Permissions = {}

-- Permission modes
Permissions.MODES = {
    DEFAULT = "default",           -- Ask for permission each time
    AUTO = "auto",                 -- Auto-approve all
    BYPASS = "bypassPermissions",  -- Bypass all permission checks
    PLAN = "plan",                 -- Plan mode: limited tools
}

-- Tool categories (TitleCase names matching tools/registry.lua registrations)
local READONLY_TOOLS = {
    "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    "ListMcpResources", "ReadMcpResource", "LSP",
    "TaskGet", "TaskList", "TaskOutput"
}

local WRITE_TOOLS = {
    "Write", "Edit", "Bash", "PowerShell",
    "NotebookEdit", "MCPTool"
}

local DANGEROUS_TOOLS = {
    "Bash", "PowerShell", "Write", "Edit",
    "TaskCreate", "Agent", "TeamCreate"
}

-- Permission cache
local permission_cache = {}

-- ── Check Permission ──────────────────────────────────────────────────

function Permissions.can_use_tool(tool_name, input, context)
    context = context or {}

    local mode = config.get("permission_mode") or Permissions.MODES.DEFAULT

    -- Bypass mode: always allow
    if mode == Permissions.MODES.BYPASS or mode == Permissions.MODES.AUTO then
        return true, nil
    end

    -- Plan mode: only allow readonly tools
    if mode == Permissions.MODES.PLAN then
        if Permissions.is_readonly_tool(tool_name) then
            return true, nil
        end

        -- Ask for permission for write tools
        return Permissions.request_permission(tool_name, input, context)
    end

    -- Default mode: ask for permission for dangerous tools
    if Permissions.is_dangerous_tool(tool_name) then
        return Permissions.request_permission(tool_name, input, context)
    end

    -- All other tools are allowed by default
    return true, nil
end

-- ── Permission Request ────────────────────────────────────────────────

function Permissions.request_permission(tool_name, input, context)
    -- Check cache
    local cache_key = Permissions.get_cache_key(tool_name, input)
    if permission_cache[cache_key] ~= nil then
        return permission_cache[cache_key], nil
    end

    -- Format the request
    print(string.format("\n\x1b[33m┌─ Permission Request ────────────────────\x1b[0m"))
    print(string.format("\x1b[33m│\x1b[0m Tool: \x1b[1m%s\x1b[0m", tool_name))

    -- Show relevant input fields
    if type(input) == "table" then
        for k, v in pairs(input) do
            if type(v) == "string" and #v < 200 then
                print(string.format("\x1b[33m│\x1b[0m %s: %s", k, v))
            elseif type(v) == "string" then
                print(string.format("\x1b[33m│\x1b[0m %s: %s...", k, v:sub(1, 197)))
            end
        end
    end

    print(string.format("\x1b[33m└─────────────────────────────────────────\x1b[0m"))
    io.write("\x1b[33mAllow? [y/n/always/never]: \x1b[0m")
    io.flush()

    local response = io.read("*l")
    response = response and response:lower() or "n"

    local allowed = false

    if response == "y" or response == "yes" then
        allowed = true
    elseif response == "always" or response == "a" then
        allowed = true
        permission_cache[cache_key] = true
    elseif response == "never" or response == "nev" then
        allowed = false
        permission_cache[cache_key] = false
    else
        allowed = false
    end

    if not allowed then
        return false, "Permission denied by user"
    end

    return true, nil
end

-- ── Tool Classification ───────────────────────────────────────────────

function Permissions.is_readonly_tool(tool_name)
    for _, name in ipairs(READONLY_TOOLS) do
        if name == tool_name then
            return true
        end
    end
    return false
end

function Permissions.is_write_tool(tool_name)
    for _, name in ipairs(WRITE_TOOLS) do
        if name == tool_name then
            return true
        end
    end
    return false
end

function Permissions.is_dangerous_tool(tool_name)
    for _, name in ipairs(DANGEROUS_TOOLS) do
        if name == tool_name then
            return true
        end
    end
    return false
end

-- ── Cache Management ──────────────────────────────────────────────────

function Permissions.get_cache_key(tool_name, input)
    -- Simple cache key: tool name + relevant input fields
    local key_parts = {tool_name}

    if type(input) == "table" then
        -- Include critical fields in cache key
        if input.command then
            table.insert(key_parts, input.command)
        end
        if input.file_path then
            table.insert(key_parts, input.file_path)
        end
    end

    return table.concat(key_parts, ":")
end

function Permissions.clear_cache()
    permission_cache = {}
end

-- ── Permission History ────────────────────────────────────────────────

local permission_history = {}

function Permissions.record_permission(tool_name, input, allowed)
    table.insert(permission_history, {
        tool_name = tool_name,
        input = input,
        allowed = allowed,
        timestamp = os.time()
    })

    -- Keep only last 100 entries
    if #permission_history > 100 then
        table.remove(permission_history, 1)
    end
end

function Permissions.get_history()
    return permission_history
end

return Permissions
