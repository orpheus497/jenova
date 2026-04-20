-- utils/http.lua — Lua 5.4 compatible HTTP client via curl subprocess
-- No FFI, no C bindings required. Falls back gracefully if curl is absent.
--
-- API mirrors the jenova.http C binding shape so jenova_backend.lua can
-- use the same call sites whether the C binding is present or not.

local json = require("utils.json_fallback")

local M = {}

local function curl_available()
    local h = io.popen("curl --version 2>/dev/null", "r")
    if not h then return false end
    local out = h:read("*l")
    h:close()
    return out ~= nil
end

local _curl_ok = nil
local function has_curl()
    if _curl_ok == nil then
        _curl_ok = curl_available()
    end
    return _curl_ok
end

-- Build the header args string from a headers table or JSON string.
local function build_header_args(headers)
    if not headers then return "" end
    local t = headers
    if type(headers) == "string" and #headers > 0 then
        local ok, parsed = pcall(json.parse, headers)
        if ok and type(parsed) == "table" then t = parsed else t = {} end
    end
    if type(t) ~= "table" then return "" end
    local parts = {}
    for k, v in pairs(t) do
        -- shell-single-quote each value to prevent injection
        local safe_k = tostring(k):gsub("'", "")
        local safe_v = tostring(v):gsub("'", "")
        parts[#parts + 1] = string.format("-H '%s: %s'", safe_k, safe_v)
    end
    return table.concat(parts, " ")
end

-- Write body to a temp file and return the path (avoids shell injection).
local function write_tempfile(content)
    local path = os.tmpname()
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(content)
    f:close()
    return path
end

-- Run curl and return (body_string | nil, error_string | nil)
local function run_curl(args)
    local cmd = "curl -s -S --max-time 300 --connect-timeout 10 " .. args .. " 2>&1"
    local h = io.popen(cmd, "r")
    if not h then return nil, "failed to spawn curl" end
    local out = h:read("*a")
    local ok, _, code = h:close()
    if not ok or (code and code ~= 0) then
        -- curl stderr is mixed into out; surface it as an error
        return nil, out or ("curl exited with code " .. tostring(code))
    end
    return out, nil
end

-- GET request. Returns body string or nil + error.
function M.get(url, headers)
    if not has_curl() then return nil, "curl not available" end
    local hargs = build_header_args(headers)
    local safe_url = "'" .. url:gsub("'", "'\\''") .. "'"
    local body, err = run_curl(hargs .. " " .. safe_url)
    return body, err
end

-- POST with a JSON body. Returns body string or nil + error.
function M.post_json(url, headers, body)
    if not has_curl() then return nil, "curl not available" end

    -- Merge in Content-Type if not provided
    local h = headers
    if type(h) == "string" and #h > 0 then
        local ok, t = pcall(json.parse, h)
        h = (ok and type(t) == "table") and t or {}
    end
    if type(h) ~= "table" then h = {} end
    if not h["Content-Type"] then h["Content-Type"] = "application/json" end

    local tmpfile = body and write_tempfile(body)
    if not tmpfile and body and #body > 0 then
        return nil, "failed to write temp file"
    end

    local hargs = build_header_args(h)
    local safe_url = "'" .. url:gsub("'", "'\\''") .. "'"
    local data_arg = tmpfile and ("-d @'" .. tmpfile .. "'") or ""

    local result, err = run_curl(hargs .. " -X POST " .. data_arg .. " " .. safe_url)

    if tmpfile then os.remove(tmpfile) end
    return result, err
end

-- Alias matching the C binding name
M.post = M.post_json

return M
