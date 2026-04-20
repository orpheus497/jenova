-- utils/paths.lua — shared path classification helpers
--
-- The .jenova directory is the CLI's own record-keeping store: project rules,
-- prompt overrides, session transcripts, planning notes, etc. Tools must never
-- read, write, or enumerate it — doing so wastes AI compute and risks exposing
-- or corrupting internal agent state.

local M = {}

-- Patterns that match .jenova directories anywhere in a path.
-- We intentionally also block the legacy .claude directory used by the
-- Anthropic reference client for the same reasons.
local BLOCKED_DIRS = {
    "/.jenova/",
    "/.jenova$",
    "^%.jenova/",
    "^%.jenova$",
    "/.claude/",
    "/.claude$",
    "^%.claude/",
    "^%.claude$",
}

-- Returns true when a path refers to a .jenova (or .claude) subtree that
-- the agent should never touch.
function M.is_restricted(path)
    if type(path) ~= "string" then return false end
    for _, pat in ipairs(BLOCKED_DIRS) do
        if path:find(pat) then return true end
    end
    return false
end

-- Convenience: returns the error table that tools should return when a
-- restricted path is requested.
function M.restricted_error(path)
    return {
        type  = "error",
        error = string.format(
            "Access denied: '%s' is inside a .jenova directory used for internal agent state. "
            .. "This directory is managed by the CLI and should not be read or modified by tools.",
            path
        ),
    }
end

-- Resolve a (possibly relative) path against a base directory.
-- If path is already absolute (starts with / or a Windows drive letter)
-- it is returned unchanged. Otherwise it is joined to base_dir.
function M.resolve(path, base_dir)
    if type(path) ~= "string" then return path end
    -- Already absolute
    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
        return path
    end
    if type(base_dir) == "string" and #base_dir > 0 then
        return base_dir:gsub("[/\\]+$", "") .. "/" .. path
    end
    return path
end

return M
