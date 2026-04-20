-- lua/utils/shell.lua
local M = {}

-- Detect Windows hosts so we can pick the right shell-quoting style.
function M.is_windows()
    return package.config:sub(1, 1) == "\\"
end

-- Quote a string for the local shell. POSIX shells get the canonical
-- single-quote form (`'\''` for embedded quotes); cmd.exe gets a
-- double-quoted form with escaped backslashes/quotes since it doesn't
-- understand single quotes at all. Both forms are only used as a fallback
-- when we can't reach the argv-based jenova.process.spawn FFI.
function M.quote(s)
    s = tostring(s)
    if M.is_windows() then
        -- For cmd.exe, wrapping in double quotes protects spaces. To prevent 
        -- command injection if the string contains quotes, we must escape 
        -- the quotes AND cmd.exe metacharacters.
        -- A robust approach for cmd.exe + CommandLineToArgvW is to replace 
        -- " with \" and then escape cmd metacharacters that might be exposed.
        -- Alternatively, since this is for shell execution, we can escape 
        -- metacharacters with ^ to prevent injection.
        local escaped = s:gsub('(\\*)(["])', function(slashes, quote)
            return slashes .. slashes .. "\\" .. quote
        end)
        escaped = escaped:gsub('(\\+)$', function(slashes)
            return slashes .. slashes
        end)
        -- To prevent cmd.exe from parsing metacharacters if the quote toggling
        -- gets misaligned by \", we escape the dangerous ones.
        -- Note: this might pass literal carets to the underlying program, but
        -- it prevents command injection which is the critical security issue.
        escaped = escaped:gsub('([&|<>()^%%!])', '^%1')
        return '"' .. escaped .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Format an environment variable assignment for the current shell.
-- Returns "KEY=VALUE " for POSIX and 'set "KEY=VALUE"&& ' for Windows.
function M.format_env(key, value)
    if M.is_windows() then
        -- On Windows cmd.exe, `set "KEY=VALUE"` safely encapsulates the value,
        -- ignoring special characters. We only need to escape internal quotes
        -- with ^" so they don't terminate the block early.
        local escaped_val = tostring(value):gsub('"', '^"')
        return string.format('set "%s=%s"&&', key, escaped_val)
    end
    -- POSIX: 'KEY=VALUE '
    return string.format("%s=%s ", key, M.quote(value))
end

return M
