-- tools/mcp_tool.lua — MCPTool: Execute MCP server tools
-- Uses jenova.mcp (Rust FFI) for JSON-RPC communication.

local json = require("utils.json_fallback")

local M = {}
M.name = "MCPTool"
M.description = "Execute a tool on a connected MCP server."

M.input_schema = {
    type = "object",
    properties = {
        server_name = { type = "string", description = "Name of the MCP server" },
        tool_name = { type = "string", description = "Name of the tool to call" },
        arguments = { type = "object", description = "Arguments to pass to the tool" },
    },
    required = { "server_name", "tool_name" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input)
    if input and input.tool_name then
        return "MCP: " .. input.tool_name
    end
    return "MCPTool"
end
function M.check_permissions() return { allowed = true } end

-- JSON-RPC request IDs must be unique per in-flight request on a single
-- connection. The earlier implementation used `os.time()`, which collides
-- whenever two calls happen inside the same second — the second response
-- can then be misattributed. We use a per-connection monotonically
-- increasing counter instead, falling back to a module-level counter if the
-- connection table can't carry state.
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
    local server_name = args.server_name
    local tool_name = args.tool_name
    if not server_name then return { type = "error", error = "No server name" } end
    if not tool_name then return { type = "error", error = "No tool name" } end

    local arguments = args.arguments or {}

    -- Look up MCP connection
    local app_state = require("state.app_state")
    local connections = app_state.get("mcp_connections") or {}
    local conn = connections[server_name]

    if not conn then
        return {
            type = "error",
            error = string.format("MCP server '%s' not connected. Configure it in settings.", server_name),
        }
    end

    -- Build JSON-RPC tools/call request with a unique per-connection id.
    local request = json.stringify({
        jsonrpc = "2.0",
        id = _next_request_id(conn),
        method = "tools/call",
        params = {
            name = tool_name,
            arguments = arguments,
        },
    })

    -- Send request via the connection's transport
    if conn.send and conn.receive then
        conn.send(request)
        local response_str = conn.receive()
        if response_str then
            local ok, response = pcall(json.parse, response_str)
            if ok and response then
                if response.result then
                    -- Extract text content
                    local content = response.result.content
                    if type(content) == "table" then
                        local texts = {}
                        for _, item in ipairs(content) do
                            if item.type == "text" then
                                table.insert(texts, item.text)
                            end
                        end
                        return { type = "text", text = table.concat(texts, "\n") }
                    end
                    return { type = "text", text = json.stringify(response.result) }
                elseif response.error then
                    return { type = "error", error = response.error.message or "MCP error" }
                end
            end
        end
    end

    return {
        type = "error",
        error = string.format("Failed to call tool '%s' on server '%s'", tool_name, server_name),
    }
end

return M
