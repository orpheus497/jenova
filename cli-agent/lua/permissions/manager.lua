-- permissions/manager.lua — Tool permission management

local config = require("config.loader")
local app_state = require("state.app_state")

local Permissions = {}

Permissions.MODES = {
    DEFAULT  = "default",           -- ask before any action tool
    AUTO     = "auto",              -- approve all without asking
    BYPASS   = "bypassPermissions", -- same as auto
    PLAN     = "plan",              -- read-only; action tools always ask
}

-- Read-only: no side-effects, never need confirmation
local READONLY_TOOLS = {
    Read=true, Glob=true, Grep=true, LocalSearch=true, Brief=true,
    WebFetch=true, WebSearch=true,
    ListMcpResources=true, ReadMcpResource=true, LSP=true,
    TaskGet=true, TaskList=true, TaskOutput=true,
}

-- Action tools: modify files, run code, or spawn processes.
-- These ALWAYS require user confirmation in default/plan mode.
-- "Bash" kept as alias in case old code uses it.
local ACTION_TOOLS = {
    Write=true, Edit=true, Shell=true, Bash=true,
    NotebookEdit=true, MCPTool=true,
    TaskCreate=true, TaskUpdate=true, TaskStop=true,
    Agent=true, TeamCreate=true, TeamDelete=true,
    RemoteTrigger=true,
}

local permission_cache = {}

-- ── Public API ────────────────────────────────────────────────────────

function Permissions.is_readonly_tool(name)  return READONLY_TOOLS[name] == true end
function Permissions.is_action_tool(name)    return ACTION_TOOLS[name]   == true end

-- Kept for compat with old callers
function Permissions.is_write_tool(name)     return ACTION_TOOLS[name]   == true end
function Permissions.is_dangerous_tool(name) return ACTION_TOOLS[name]   == true end

function Permissions.can_use_tool(tool_name, input, context)
    context = context or {}

    local mode = app_state.get("permission_mode")
        or config.get("permission_mode")
        or Permissions.MODES.DEFAULT

    -- Auto/bypass: never block
    if mode == Permissions.MODES.BYPASS or mode == Permissions.MODES.AUTO then
        return true, nil
    end

    -- Read-only tools: always allowed
    if Permissions.is_readonly_tool(tool_name) then
        return true, nil
    end

    -- Everything else (action tools and unknown tools) requires confirmation
    return Permissions.request_permission(tool_name, input, context)
end

-- ── Permission Request ────────────────────────────────────────────────

-- Build a concise human-readable summary of what the tool will do.
local function describe_action(tool_name, input)
    if type(input) ~= "table" then return nil end
    if tool_name == "Shell" or tool_name == "Bash" then
        return input.command and ("$ " .. input.command:sub(1, 200))
    elseif tool_name == "Write" then
        local size = input.content and (#input.content .. " bytes") or ""
        return input.file_path and ("write " .. size .. " → " .. input.file_path)
    elseif tool_name == "Edit" then
        return input.file_path and ("edit " .. input.file_path)
    end
    -- Generic: show first non-content string field
    for _, k in ipairs({"file_path", "path", "command", "query", "url"}) do
        if type(input[k]) == "string" and #input[k] > 0 then
            return k .. ": " .. input[k]:sub(1, 120)
        end
    end
    return nil
end

function Permissions.request_permission(tool_name, input, _context)
    local cache_key = Permissions.get_cache_key(tool_name, input)
    if permission_cache[cache_key] ~= nil then
        local cached = permission_cache[cache_key]
        if not cached then
            return false, "Permission denied (cached)"
        end
        return true, nil
    end

    local Y  = "\27[33m"
    local B  = "\27[1m"
    local D  = "\27[2m"
    local R  = "\27[0m"
    local CY = "\27[36m"

    io.write("\n")
    io.write(Y .. "  ┌─ action required " .. string.rep("─", 40) .. R .. "\n")
    io.write(Y .. "  │ " .. R .. B .. tool_name .. R .. "\n")

    local detail = describe_action(tool_name, input)
    if detail then
        -- Wrap long details
        local max = 68
        while #detail > max do
            io.write(Y .. "  │ " .. R .. D .. detail:sub(1, max) .. R .. "\n")
            detail = detail:sub(max + 1)
        end
        if #detail > 0 then
            io.write(Y .. "  │ " .. R .. D .. detail .. R .. "\n")
        end
    end

    io.write(Y .. "  └" .. string.rep("─", 58) .. R .. "\n")
    io.write(CY .. "  [y]es  [n]o  [a]lways  [s]ession: " .. R)
    io.flush()

    local response = io.read("*l")
    response = response and response:lower():match("^%s*(.-)%s*$") or "n"

    local allowed = false

    if response == "y" or response == "yes" then
        allowed = true
    elseif response == "a" or response == "always" then
        allowed = true
        permission_cache[cache_key] = true
    elseif response == "s" or response == "session" then
        -- Allow for the rest of the session (cache by tool name only)
        allowed = true
        permission_cache[tool_name .. ":*"] = true
    elseif response == "n" or response == "no" or response == "" then
        allowed = false
        permission_cache[cache_key] = false
    end

    io.write("\n")

    Permissions.record_permission(tool_name, input, allowed)
    if not allowed then
        return false, "Permission denied by user"
    end
    return true, nil
end

-- ── Cache ─────────────────────────────────────────────────────────────

function Permissions.get_cache_key(tool_name, input)
    -- Check for session-wide grant first
    if permission_cache[tool_name .. ":*"] then
        return tool_name .. ":*"
    end
    local parts = {tool_name}
    if type(input) == "table" then
        if input.command   then parts[#parts+1] = input.command end
        if input.file_path then parts[#parts+1] = input.file_path end
    end
    return table.concat(parts, ":")
end

function Permissions.clear_cache()
    permission_cache = {}
end

-- ── History ───────────────────────────────────────────────────────────

local permission_history = {}

function Permissions.record_permission(tool_name, input, allowed)
    table.insert(permission_history, {
        tool_name = tool_name,
        input     = input,
        allowed   = allowed,
        timestamp = os.time(),
    })
    if #permission_history > 100 then
        table.remove(permission_history, 1)
    end
end

function Permissions.get_history()
    return permission_history
end

return Permissions
