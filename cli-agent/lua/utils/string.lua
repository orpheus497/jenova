-- utils/string.lua — String utility functions

local M = {}

function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

function M.split(s, sep)
    local parts = {}
    for part in s:gmatch("([^" .. (sep or "%s") .. "]+)") do
        table.insert(parts, part)
    end
    return parts
end

function M.starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

function M.ends_with(s, suffix)
    return s:sub(-#suffix) == suffix
end

function M.pad_right(s, width, char)
    char = char or " "
    if #s >= width then return s end
    return s .. string.rep(char, width - #s)
end

function M.pad_left(s, width, char)
    char = char or " "
    if #s >= width then return s end
    return string.rep(char, width - #s) .. s
end

function M.truncate(s, max_len, suffix)
    suffix = suffix or "..."
    if #s <= max_len then return s end
    return s:sub(1, max_len - #suffix) .. suffix
end

function M.wrap(s, width)
    local lines = {}
    local line = ""
    for word in s:gmatch("%S+") do
        if #line + #word + 1 > width then
            table.insert(lines, line)
            line = word
        else
            line = #line > 0 and (line .. " " .. word) or word
        end
    end
    if #line > 0 then table.insert(lines, line) end
    return lines
end

function M.escape_pattern(s)
    return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

function M.count(s, sub)
    local count = 0
    local start = 1
    while true do
        local pos = s:find(sub, start, true)
        if not pos then break end
        count = count + 1
        start = pos + 1
    end
    return count
end

return M
