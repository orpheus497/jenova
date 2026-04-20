-- json_fallback.lua — Pure Lua JSON encode/decode fallback
-- Used when jenova.json (Rust FFI) is not available.
-- Provides a minimal but functional JSON implementation.

local M = {}

-- ── JSON Encoding ─────────────────────────────────────────────────────

local encode_value  -- forward declaration

local function encode_string(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('[\x00-\x1f]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local function encode_table(t, indent, level)
    if next(t) == nil then
        if is_array(t) then return "[]" else return "{}" end
    end

    level = level or 0
    local nl = indent and "\n" or ""
    local sp = indent and string.rep("  ", level + 1) or ""
    local sp_end = indent and string.rep("  ", level) or ""
    local sep = indent and ",\n" or ","

    if is_array(t) then
        local parts = {}
        for _, v in ipairs(t) do
            table.insert(parts, sp .. encode_value(v, indent, level + 1))
        end
        return "[" .. nl .. table.concat(parts, sep) .. nl .. sp_end .. "]"
    else
        local parts = {}
        local keys = {}
        for k in pairs(t) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            table.insert(parts, sp .. encode_string(tostring(k)) .. ":" ..
                (indent and " " or "") .. encode_value(t[k], indent, level + 1))
        end
        return "{" .. nl .. table.concat(parts, sep) .. nl .. sp_end .. "}"
    end
end

encode_value = function(v, indent, level)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v then return "null" end  -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2^53 then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif t == "string" then
        return encode_string(v)
    elseif t == "table" then
        return encode_table(v, indent, level)
    else
        return "null"
    end
end

--- Encode a Lua value to JSON string
--- @param value any Lua value to encode
--- @return string json JSON string
function M.stringify(value)
    return encode_value(value, false, 0)
end

--- Encode a Lua value to pretty-printed JSON string
--- @param value any Lua value to encode
--- @return string json Pretty JSON string
function M.stringify_pretty(value)
    return encode_value(value, true, 0)
end

-- ── JSON Decoding ─────────────────────────────────────────────────────

local decode_value  -- forward declaration

local function skip_whitespace(s, pos)
    return s:match('^%s*()', pos)
end

local function decode_string(s, pos)
    local start = pos + 1  -- skip opening quote
    local result = {}
    local i = start
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(result), i + 1
        elseif c == '\\' then
            i = i + 1
            c = s:sub(i, i)
            if c == '"' then table.insert(result, '"')
            elseif c == '\\' then table.insert(result, '\\')
            elseif c == '/' then table.insert(result, '/')
            elseif c == 'n' then table.insert(result, '\n')
            elseif c == 'r' then table.insert(result, '\r')
            elseif c == 't' then table.insert(result, '\t')
            elseif c == 'b' then table.insert(result, '\b')
            elseif c == 'f' then table.insert(result, '\f')
            elseif c == 'u' then
                local hex = s:sub(i + 1, i + 4)
                local code = tonumber(hex, 16)
                if code then
                    if code < 0x80 then
                        table.insert(result, string.char(code))
                    elseif code < 0x800 then
                        table.insert(result, string.char(
                            0xC0 + math.floor(code / 64),
                            0x80 + (code % 64)))
                    else
                        table.insert(result, string.char(
                            0xE0 + math.floor(code / 4096),
                            0x80 + (math.floor(code / 64) % 64),
                            0x80 + (code % 64)))
                    end
                end
                i = i + 4
            end
        else
            table.insert(result, c)
        end
        i = i + 1
    end
    error("Unterminated string")
end

local function decode_number(s, pos)
    local num_str = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*()', pos)
    if not num_str then error("Invalid number at position " .. pos) end
    local val = tonumber(s:sub(pos, num_str - 1))
    return val, num_str
end

local function decode_array(s, pos)
    pos = skip_whitespace(s, pos + 1)  -- skip '['
    local arr = {}
    if s:sub(pos, pos) == ']' then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = decode_value(s, pos)
        table.insert(arr, val)
        pos = skip_whitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = skip_whitespace(s, pos + 1)
        else
            error("Expected ',' or ']' at position " .. pos)
        end
    end
end

local function decode_object(s, pos)
    pos = skip_whitespace(s, pos + 1)  -- skip '{'
    local obj = {}
    if s:sub(pos, pos) == '}' then
        return obj, pos + 1
    end
    while true do
        -- Key must be a string
        if s:sub(pos, pos) ~= '"' then
            error("Expected string key at position " .. pos)
        end
        local key
        key, pos = decode_string(s, pos)
        pos = skip_whitespace(s, pos)
        if s:sub(pos, pos) ~= ':' then
            error("Expected ':' at position " .. pos)
        end
        pos = skip_whitespace(s, pos + 1)
        local val
        val, pos = decode_value(s, pos)
        obj[key] = val
        pos = skip_whitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = skip_whitespace(s, pos + 1)
        else
            error("Expected ',' or '}' at position " .. pos)
        end
    end
end

decode_value = function(s, pos)
    pos = skip_whitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == '"' then
        return decode_string(s, pos)
    elseif c == '{' then
        return decode_object(s, pos)
    elseif c == '[' then
        return decode_array(s, pos)
    elseif c == 't' then
        if s:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
        error("Invalid value at position " .. pos)
    elseif c == 'f' then
        if s:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
        error("Invalid value at position " .. pos)
    elseif c == 'n' then
        if s:sub(pos, pos + 3) == 'null' then return nil, pos + 4 end
        error("Invalid value at position " .. pos)
    elseif c == '-' or (c >= '0' and c <= '9') then
        return decode_number(s, pos)
    else
        error("Unexpected character '" .. c .. "' at position " .. pos)
    end
end

--- Decode a JSON string to a Lua value
--- @param str string JSON string to decode
--- @return any value Decoded Lua value
function M.parse(str)
    if type(str) ~= "string" then
        return nil, "Expected string argument"
    end
    if #str == 0 then
        return nil, "Empty string"
    end
    local ok, result, _ = pcall(decode_value, str, 1)
    if ok then
        return result
    else
        return nil, tostring(result)
    end
end

return M
