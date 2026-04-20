-- tools/web_fetch.lua — WebFetchTool: Fetch URL content
-- Uses jenova.http (Rust FFI) for HTTP requests.

local json = require("utils.json_fallback")

local M = {}
M.name = "WebFetch"
M.description = "Fetch a URL and return its content. Supports HTTP/HTTPS. Content is truncated to 100KB."

M.parameters = {
    type = "object",
    properties = {
        url = { type = "string", description = "URL to fetch" },
        headers = { type = "object", description = "Additional HTTP headers" },
    },
    required = { "url" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    if input and input.url then
        local short = input.url:sub(1, 50)
        if #input.url > 50 then short = short .. "..." end
        return "Fetch: " .. short
    end
    return "WebFetch"
end

function M.check_permissions(input, ctx) return { allowed = true } end

function M.call(args, context)
    local url = args.url
    if not url then return { type = "error", error = "No URL provided" } end

    -- Build headers JSON
    local headers_json = "{}"
    if args.headers then
        headers_json = json.stringify(args.headers)
    end

    -- Use Rust FFI (preferred)
    if jenova and jenova.http and jenova.http.get then
        local body = jenova.http.get(url, headers_json)
        if body then
            -- Truncate to 100KB
            if #body > 100000 then
                body = body:sub(1, 100000) .. "\n\n[Content truncated at 100KB]"
            end
            return { type = "text", text = body }
        end
    end

    -- Fallback: use curl
    local shell = require("utils.shell")
    local cmd = string.format('curl -sL %s 2>/dev/null | head -c 100000', shell.quote(url))
    
    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Fetch failed" } end
    local out = h:read("*a")
    h:close()

    if not out or #out == 0 then
        return { type = "error", error = "Empty response from " .. url }
    end

    -- Truncate in Lua as a final safeguard (always needed on Windows fallback)
    if #out > 100000 then
        out = out:sub(1, 100000) .. "\n\n[Content truncated at 100KB]"
    end

    return { type = "text", text = out }
end

return M
