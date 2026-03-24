-- Minimal JSON encoder/decoder for LuaJIT
-- No dependencies, pure Lua

local json = {}

-- Encode Lua value to JSON string
local encode_value

local function encode_string(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  s = s:gsub('%c', function(c)
    return string.format('\\u%04x', string.byte(c))
  end)
  return '"' .. s .. '"'
end

local function encode_table(t)
  -- Detect array vs object
  local is_array = true
  local max_i = 0
  for k, _ in pairs(t) do
    if type(k) == "number" and k == math.floor(k) and k >= 1 then
      if k > max_i then max_i = k end
    else
      is_array = false
      break
    end
  end
  if max_i == 0 and next(t) == nil then
    -- Empty table: default to array
    return "[]"
  end
  if is_array and max_i == #t then
    local parts = {}
    for i = 1, #t do
      parts[i] = encode_value(t[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  else
    local parts = {}
    for k, v in pairs(t) do
      parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode_value(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
end

encode_value = function(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v then return "null" end
    if v == 1/0 or v == -1/0 then return "null" end
    return tostring(v)
  elseif t == "string" then return encode_string(v)
  elseif t == "table" then return encode_table(v)
  else return "null"
  end
end

function json.encode(v)
  return encode_value(v)
end

-- Decode JSON string to Lua value
function json.decode(s)
  local pos = 1
  local function skip_ws()
    pos = s:match('^%s*()', pos)
  end

  local function peek()
    skip_ws()
    return s:sub(pos, pos)
  end

  local decode_value

  local function decode_string()
    assert(s:sub(pos, pos) == '"', "expected '\"' at position " .. pos)
    pos = pos + 1
    local parts = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(parts)
      elseif c == '\\' then
        pos = pos + 1
        local esc = s:sub(pos, pos)
        pos = pos + 1
        if esc == '"' then parts[#parts+1] = '"'
        elseif esc == '\\' then parts[#parts+1] = '\\'
        elseif esc == '/' then parts[#parts+1] = '/'
        elseif esc == 'n' then parts[#parts+1] = '\n'
        elseif esc == 'r' then parts[#parts+1] = '\r'
        elseif esc == 't' then parts[#parts+1] = '\t'
        elseif esc == 'b' then parts[#parts+1] = '\b'
        elseif esc == 'f' then parts[#parts+1] = '\f'
        elseif esc == 'u' then
          local hex = s:sub(pos, pos + 3)
          pos = pos + 4
          local cp = tonumber(hex, 16)
          if cp < 0x80 then
            parts[#parts+1] = string.char(cp)
          elseif cp < 0x800 then
            parts[#parts+1] = string.char(
              0xC0 + math.floor(cp / 64),
              0x80 + (cp % 64))
          else
            parts[#parts+1] = string.char(
              0xE0 + math.floor(cp / 4096),
              0x80 + math.floor((cp % 4096) / 64),
              0x80 + (cp % 64))
          end
        end
      else
        parts[#parts+1] = c
        pos = pos + 1
      end
    end
    error("unterminated string")
  end

  local function decode_number()
    local start = pos
    if s:sub(pos, pos) == '-' then pos = pos + 1 end
    while s:sub(pos, pos):match('[%d]') do pos = pos + 1 end
    if s:sub(pos, pos) == '.' then
      pos = pos + 1
      while s:sub(pos, pos):match('[%d]') do pos = pos + 1 end
    end
    if s:sub(pos, pos):match('[eE]') then
      pos = pos + 1
      if s:sub(pos, pos):match('[%+%-]') then pos = pos + 1 end
      while s:sub(pos, pos):match('[%d]') do pos = pos + 1 end
    end
    return tonumber(s:sub(start, pos - 1))
  end

  local function decode_array()
    pos = pos + 1 -- skip '['
    local arr = {}
    skip_ws()
    if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      arr[#arr + 1] = decode_value()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == ']' then pos = pos + 1; return arr end
      assert(c == ',', "expected ',' or ']' at position " .. pos)
      pos = pos + 1
    end
  end

  local function decode_object()
    pos = pos + 1 -- skip '{'
    local obj = {}
    skip_ws()
    if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = decode_string()
      skip_ws()
      assert(s:sub(pos, pos) == ':', "expected ':' at position " .. pos)
      pos = pos + 1
      obj[key] = decode_value()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == '}' then pos = pos + 1; return obj end
      assert(c == ',', "expected ',' or '}' at position " .. pos)
      pos = pos + 1
    end
  end

  decode_value = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then return decode_string()
    elseif c == '{' then return decode_object()
    elseif c == '[' then return decode_array()
    elseif c == 't' then
      assert(s:sub(pos, pos + 3) == 'true')
      pos = pos + 4; return true
    elseif c == 'f' then
      assert(s:sub(pos, pos + 4) == 'false')
      pos = pos + 5; return false
    elseif c == 'n' then
      assert(s:sub(pos, pos + 3) == 'null')
      pos = pos + 4; return nil
    elseif c == '-' or c:match('%d') then
      return decode_number()
    else
      error("unexpected character '" .. c .. "' at position " .. pos)
    end
  end

  local result = decode_value()
  return result
end

return json
