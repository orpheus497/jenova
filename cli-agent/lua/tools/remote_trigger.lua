-- tools/remote_trigger.lua — RemoteTrigger: Trigger a remote agent or webhook

local json = require("utils.json_fallback")

local M = {}
M.name = "RemoteTrigger"
M.description = "Trigger a remote agent session or fire a webhook."

M.parameters = {
    type = "object",
    properties = {
        url = { type = "string", description = "Webhook URL or remote agent endpoint" },
        method = { type = "string", description = "HTTP method (default: POST)" },
        payload = { type = "object", description = "JSON payload to send" },
        headers = { type = "object", description = "Additional HTTP headers" },
    },
    required = { "url" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "RemoteTrigger" end

function M.check_permissions()
    return { allowed = true }
end

-- Header values must not contain CR/LF — otherwise an attacker controlling
-- a header value could inject additional headers (HTTP response splitting
-- / CRLF injection). We strip both characters from header names and values
-- before they're handed to the HTTP client or to curl.
local function _sanitize_header_component(s)
    return tostring(s):gsub("[\r\n]", " ")
end

local function _sanitize_headers(headers)
    if type(headers) ~= "table" then return {} end
    local clean = {}
    for k, v in pairs(headers) do
        clean[_sanitize_header_component(k)] = _sanitize_header_component(v)
    end
    return clean
end

-- Returns true when the URL resolves to a private/loopback address that
-- must not be reachable from an agent tool (SSRF protection).
local function _is_private_url(url)
    local host = url:match("https?://([^/:?#]+)")
    if not host then return true end  -- unparseable — reject
    host = host:lower()
    if host == "localhost" then return true end
    if host == "0.0.0.0"   then return true end
    if host == "::1"        then return true end
    -- IPv4 loopback: 127.0.0.0/8
    if host:match("^127%.[%d]+%.[%d]+%.[%d]+$") then return true end
    -- RFC-1918: 10.0.0.0/8
    if host:match("^10%.[%d]+%.[%d]+%.[%d]+$") then return true end
    -- RFC-1918: 192.168.0.0/16
    if host:match("^192%.168%.[%d]+%.[%d]+$") then return true end
    -- RFC-1918: 172.16.0.0/12  (172.16–172.31)
    local oct2 = host:match("^172%.(%d+)%.[%d]+%.[%d]+$")
    if oct2 then
        local n = tonumber(oct2)
        if n and n >= 16 and n <= 31 then return true end
    end
    -- Link-local: 169.254.0.0/16
    if host:match("^169%.254%.[%d]+%.[%d]+$") then return true end
    return false
end

function M.call(args, ctx)
    local url = args.url
    if not url or #url == 0 then
        return { type = "error", error = "URL is required" }
    end
    -- Reject URLs containing CR/LF outright — they should never appear in
    -- a real URL and only show up via injection attempts.
    if url:find("[\r\n]") then
        return { type = "error", error = "URL must not contain newline characters" }
    end
    -- SSRF protection: block requests to private/loopback address ranges.
    if _is_private_url(url) then
        return { type = "error", error = "SSRF: requests to private/loopback addresses are not permitted" }
    end

    local method = (args.method or "POST"):upper()
    local payload = args.payload
    local headers = _sanitize_headers(args.headers or {})

    -- Use jenova.http if available
    if jenova and jenova.http then
        local headers_json = json.stringify(headers)
        local result, err

        if method == "GET" then
            result, err = jenova.http.get(url, headers_json)
        elseif method == "POST" then
            local body = payload and json.stringify(payload) or ""
            headers["Content-Type"] = headers["Content-Type"] or "application/json"
            headers_json = json.stringify(headers)
            result, err = jenova.http.post_json(url, headers_json, body)
        else
            return { type = "error", error = "Unsupported method: " .. method }
        end

        if err then
            return { type = "error", error = "Request failed: " .. tostring(err) }
        end

        return { type = "text", text = result or "Request completed (no response body)." }
    end

    -- Fallback: curl. Prefer the FFI's argv form so neither header values
    -- nor payloads need shell quoting. Both styles still pass headers as
    -- distinct argv elements after the CR/LF strip above.
    if jenova and jenova.process and jenova.process.spawn then
        local argv = { "-s", "-X", method }
        for k, v in pairs(headers) do
            argv[#argv + 1] = "-H"
            argv[#argv + 1] = k .. ": " .. v
        end
        if payload and method ~= "GET" then
            argv[#argv + 1] = "-H"
            argv[#argv + 1] = "Content-Type: application/json"
            argv[#argv + 1] = "-d"
            argv[#argv + 1] = json.stringify(payload)
        end
        argv[#argv + 1] = url

        local config = json.stringify({
            command = "curl",
            args = argv,
            timeout_ms = 60000,
            capture_stdout = true,
            capture_stderr = true,
        })
        local res = jenova.process.spawn(config)
        if res then
            local ok, parsed = pcall(json.parse, res)
            if ok and parsed then
                local out = (parsed.stdout or "") .. (parsed.stderr or "")
                return { type = "text", text = out }
            end
        end
    end

    -- io.popen last-resort: build a properly quoted command line. Each
    -- header value has already had CR/LF stripped, and we re-escape any
    -- single quotes inside the POSIX single-quote wrapper.
    local shell = require("utils.shell")

    local curl_parts = { "curl", "-s", "-X", shell.quote(method) }
    for k, v in pairs(headers) do
        curl_parts[#curl_parts + 1] = "-H"
        curl_parts[#curl_parts + 1] = shell.quote(k .. ": " .. v)
    end
    if payload and method ~= "GET" then
        curl_parts[#curl_parts + 1] = "-H"
        curl_parts[#curl_parts + 1] = shell.quote("Content-Type: application/json")
        curl_parts[#curl_parts + 1] = "-d"
        curl_parts[#curl_parts + 1] = shell.quote(json.stringify(payload))
    end
    curl_parts[#curl_parts + 1] = shell.quote(url)
    curl_parts[#curl_parts + 1] = "2>&1"

    local cmd = table.concat(curl_parts, " ")
    local handle = io.popen(cmd)
    if not handle then
        return { type = "error", error = "Failed to execute curl" }
    end
    local output = handle:read("*a")
    handle:close()

    return { type = "text", text = output or "Request completed." }
end

return M
