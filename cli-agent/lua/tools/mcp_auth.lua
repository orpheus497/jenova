-- tools/mcp_auth.lua — McpAuth: Start OAuth flow for MCP servers needing auth
--
-- This is a pseudo-tool that surfaces when an MCP server is configured but
-- not yet authenticated. When invoked it kicks off the OAuth 2.0 + PKCE flow
-- against the server's authorization endpoint and returns the URL for the
-- user to open in their browser. Once the callback fires, the server's real
-- tools are swapped into the registry via the background callback.

local json = require("utils.json_fallback")
local config = require("config.loader")
local app_state = require("state.app_state")

local M = {}
M.name = "McpAuth"
M.description = "Start the OAuth flow for an MCP server that requires authentication. Returns an authorization URL for the user to open in their browser."

M.input_schema = {
    type = "object",
    properties = {
        server_name = {
            type = "string",
            description = "Name of the MCP server to authenticate with.",
        },
    },
    required = { "server_name" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
    if input and input.server_name then
        return input.server_name .. " - authenticate (MCP)"
    end
    return "McpAuth"
end

function M.check_permissions() return { allowed = true } end

-- Find an MCP server config by name. Supports both list-of-servers and
-- map-of-name-to-config shapes in config/loader.
local function find_server(server_name)
    local servers = config.get("mcp_servers") or {}
    -- List shape: { { name = "foo", ... }, ... }
    for _, s in ipairs(servers) do
        if s.name == server_name then
            return s
        end
    end
    -- Map shape: { foo = { ... } }
    if servers[server_name] then
        local s = servers[server_name]
        if type(s) == "table" then
            s.name = s.name or server_name
            return s
        end
    end
    return nil
end

-- Mark a server connection as needing auth in app_state so the UI can
-- surface it alongside the returned auth URL.
local function set_needs_auth(server_name, auth_url)
    local conns = app_state.get("mcp_connections") or {}
    conns[server_name] = conns[server_name] or {}
    conns[server_name].status = "needs_auth"
    conns[server_name].auth_url = auth_url
    conns[server_name].last_auth_attempt = os.time()
    app_state.set("mcp_connections", conns)
end

-- Build the OAuth authorization URL via jenova.mcp.start_oauth if the Rust
-- side implements it. The Rust helper is expected to return a JSON string
-- with { auth_url = ..., state = ... } on success.
local function start_oauth_via_ffi(server_name, server_config)
    if not (jenova and jenova.mcp and jenova.mcp.start_oauth) then
        return nil, "jenova.mcp.start_oauth not available"
    end
    local req = json.stringify({
        server_name = server_name,
        url = server_config.url,
        transport = server_config.type or "http",
        skip_browser_open = true,
    })
    local result_json = jenova.mcp.start_oauth(req)
    if not result_json then
        return nil, "OAuth start returned no result"
    end
    local ok, result = pcall(json.parse, result_json)
    if not ok or not result then
        return nil, "Failed to parse OAuth response"
    end
    if result.error then
        return nil, result.error
    end
    return result
end

-- Plain-Lua fallback: construct a best-effort auth URL from the server's
-- known authorization endpoint. This is only useful as a hint for the user
-- when the FFI helper isn't wired up yet.
local function start_oauth_fallback(server_name, server_config)
    if not server_config.url then
        return nil, "MCP server '" .. server_name .. "' has no URL; cannot start OAuth"
    end
    if not server_config.authorization_endpoint then
        return nil, "MCP server '" .. server_name .. "' has no authorization_endpoint configured. Ask the user to run /mcp and authenticate manually."
    end

    -- Minimal PKCE-less stub: production should always go through FFI.
    local ep = server_config.authorization_endpoint
    local client_id = server_config.client_id or ""
    local redirect = server_config.redirect_uri or "http://localhost:3000/callback"
    local scope = server_config.scope or "openid profile"
    
    local function url_encode(str)
        if not str then return "" end
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "%%20")
        return str
    end

    local auth_url = string.format(
        "%s?response_type=code&client_id=%s&redirect_uri=%s&scope=%s",
        ep,
        url_encode(client_id),
        url_encode(redirect),
        url_encode(scope)
    )
    return { auth_url = auth_url }
end

function M.call(args, ctx)
    local server_name = args.server_name
    if not server_name then
        return { type = "error", error = "server_name is required" }
    end

    local server_config = find_server(server_name)
    if not server_config then
        return {
            type = "error",
            error = string.format(
                "MCP server '%s' not found in config. Run /mcp to configure it first.",
                server_name
            ),
        }
    end

    local transport = server_config.type or "stdio"

    -- claude.ai connectors use a separate flow that we can't drive from here
    if transport == "claudeai-proxy" then
        return {
            type = "text",
            text = string.format(
                "This is a claude.ai MCP connector. Ask the user to run /mcp and select \"%s\" to authenticate.",
                server_name
            ),
            status = "unsupported",
        }
    end

    -- performMCPOAuthFlow only accepts sse/http
    if transport ~= "sse" and transport ~= "http" then
        return {
            type = "text",
            text = string.format(
                "Server \"%s\" uses %s transport which does not support OAuth from this tool. Ask the user to run /mcp and authenticate manually.",
                server_name, transport
            ),
            status = "unsupported",
        }
    end

    -- Try FFI first, fall back to URL construction
    local result, err = start_oauth_via_ffi(server_name, server_config)
    if not result then
        local fb, fb_err = start_oauth_fallback(server_name, server_config)
        if not fb then
            return {
                type = "error",
                error = string.format(
                    "Failed to start OAuth flow for %s: %s. Ask the user to run /mcp and authenticate manually.",
                    server_name, fb_err or err or "unknown error"
                ),
            }
        end
        result = fb
    end

    local auth_url = result.auth_url or result.authorization_url
    if not auth_url then
        return {
            type = "text",
            text = string.format(
                "Authentication completed silently for %s. The server's tools should now be available.",
                server_name
            ),
            status = "auth_url",
        }
    end

    set_needs_auth(server_name, auth_url)

    return {
        type = "text",
        text = string.format(
            "Ask the user to open this URL in their browser to authorize the %s MCP server:\n\n%s\n\nOnce they complete the flow, the server's tools will become available automatically.",
            server_name, auth_url
        ),
        status = "auth_url",
        auth_url = auth_url,
    }
end

return M
