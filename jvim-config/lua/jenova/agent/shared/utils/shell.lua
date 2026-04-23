-- lua/utils/shell.lua — POSIX shell utilities (FreeBSD, Linux, macOS)
local M = {}

-- POSIX single-quote escaping: wrap in single quotes, escape embedded quotes.
function M.quote(s)
    s = tostring(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Format an environment variable assignment for POSIX shell.
-- Returns "KEY=VALUE " suitable for prefixing a command.
function M.format_env(key, value)
    return string.format("%s=%s ", key, M.quote(value))
end

return M
