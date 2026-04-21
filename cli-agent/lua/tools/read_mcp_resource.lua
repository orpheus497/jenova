-- tools/read_mcp_resource.lua — ReadMcpResource: Read a resource from an MCP server

local json = require("utils.json_fallback")

local M = {}
M.name = "ReadMcpResource"
M.description = "Read a specific resource from a connected MCP server by URI."

M.parameters = {
    type = "object",
    properties = {
        uri = { type = "string", description = "Resource URI (e.g. 'file:///path' or 'custom://resource')" },
        server_name = { type = "string", description = "Target MCP server name (optional if unambiguous)" },
    },
    required = { "uri" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "ReadMcpResource" end
function M.check_permissions() return { allowed = true } end

-- JSON-RPC request IDs must be unique per in-flight request on a single
-- connection. We use a per-connection monotonically increasing counter.
local _fallback_next_id = 0
local function _next_request_id(conn)
    if conn then
        local next_id = (conn._next_request_id or 0) + 1
        conn._next_request_id = next_id
        return next_id
    end
    _fallback_next_id = _fallback_next_id + 1
    return _fallback_next_id
end

function M.call(args, ctx)
    local uri = args.uri
    if not uri or #uri == 0 then
        return { type = "error", error = "URI is required" }
    end

    -- 1. file:// URIs: read directly from the local filesystem, regardless
    -- of whether an MCP server is connected. This matches the behavior of
    -- the TypeScript implementation for local file resources.
    local file_path = uri:match("^file://(.+)")
    if file_path then
        local _jenova = rawget(_G, "jenova")
        if type(_jenova) == "table" and _jenova.sandbox and _jenova.sandbox.validate_path then
            local cwd
        do
            local ok, app_state = pcall(require, "state.app_state")
            if ok and type(app_state) == "table" and type(app_state.get_cwd) == "function" then
                cwd = app_state.get_cwd()
            end
        end
        cwd = cwd or os.getenv("PWD") or "."
            if _jenova.sandbox.validate_path(file_path, cwd) == 0 then
                return { type = "error", error = "Access denied: path outside working directory" }
            end
        end
        local f = io.open(file_path, "r")
        if not f then
            return { type = "error", error = "Cannot open file: " .. file_path }
        end
        local content = f:read("*a")
        f:close()
        return {
            type = "text",
            text = string.format("Resource: %s\n\n%s", uri, content)
        }
    end

    -- 2. Otherwise, send a resources/read JSON-RPC request over an existing
    -- MCP connection. Connections are managed in app_state.mcp_connections
    -- (see tools/mcp_tool.lua for the matching send/receive protocol).
    local app_state = require("state.app_state")
    local connections = app_state.get("mcp_connections") or {}

    -- Pick the target connection: explicit server_name if given, otherwise
    -- the only one if exactly one is connected.
    local conn, conn_name
    if args.server_name then
        conn = connections[args.server_name]
        conn_name = args.server_name
    else
        local count = 0
        for name, c in pairs(connections) do
            count = count + 1
            conn = c
            conn_name = name
        end
        if count > 1 then
            return {
                type = "error",
                error = "Multiple MCP servers connected; pass server_name to disambiguate.",
            }
        end
    end

    if not conn or not conn.send or not conn.receive then
        return {
            type = "error",
            error = string.format(
                "No MCP connection available for resource '%s'%s. " ..
                "Either use a file:// URI or connect an MCP server.",
                uri,
                conn_name and (" (server: " .. conn_name .. ")") or ""
            ),
        }
    end

    local request = json.stringify({
        jsonrpc = "2.0",
        id = _next_request_id(conn),
        method = "resources/read",
        params = { uri = uri },
    })

    conn.send(request)
    local response_str = conn.receive()
    if not response_str then
        return { type = "error", error = "No response from MCP server for resources/read" }
    end

    local ok, response = pcall(json.parse, response_str)
    if not ok or not response then
        return { type = "error", error = "Invalid JSON-RPC response from MCP server" }
    end
    if response.error then
        return { type = "error", error = response.error.message or "MCP error" }
    end

    -- Extract text content from the standard MCP resource response shape
    local result = response.result or {}
    local contents = result.contents
    if type(contents) == "table" then
        local texts = {}
        for _, item in ipairs(contents) do
            if item.text then
                table.insert(texts, item.text)
            elseif item.blob then
                table.insert(texts, "[blob " .. tostring(#item.blob) .. " bytes]")
            end
        end
        return {
            type = "text",
            text = string.format("Resource: %s\n\n%s", uri, table.concat(texts, "\n")),
        }
    end

    return { type = "text", text = json.stringify(result) }
end

return M
