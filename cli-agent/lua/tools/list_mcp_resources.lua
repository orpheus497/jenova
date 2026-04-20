-- tools/list_mcp_resources.lua — ListMcpResources: List resources from MCP servers

local json = require("utils.json_fallback")
local config = require("config.loader")

local M = {}
M.name = "ListMcpResources"
M.description = "List resources exposed by connected MCP servers."

M.parameters = {
    type = "object",
    properties = {
        server_name = { type = "string", description = "Filter by MCP server name (optional)" },
    },
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "ListMcpResources" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local server_filter = args.server_name

    -- Read from config-registered MCP servers
    local servers = config.get("mcp_servers") or {}
    if #servers == 0 then
        return { type = "text", text = "No MCP servers configured." }
    end

    local lines = { "MCP servers and resources:" }
    for _, server in ipairs(servers) do
        if not server_filter or server.name == server_filter then
            table.insert(lines, string.format("\n  Server: %s", server.name or "unnamed"))
            if server.url then
                table.insert(lines, string.format("    URL: %s", server.url))
            end
            if server.resources then
                for _, res in ipairs(server.resources) do
                    table.insert(lines, string.format("    - %s: %s",
                        res.uri or res.name or "?",
                        res.description or ""))
                end
            else
                table.insert(lines, "    (resources not enumerated — connect to server to discover)")
            end
        end
    end

    return { type = "text", text = table.concat(lines, "\n") }
end

return M
