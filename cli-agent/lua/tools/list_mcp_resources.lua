-- tools/list_mcp_resources.lua — ListMcpResources: List resources from MCP servers

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

-- Normalise the `mcp_servers` config value into a flat list of server records.
-- The config may be an array ({ name, url, ... } entries) or a map
-- ({ server_name -> { url, ... } }).  Both shapes are normalised so that each
-- record has a `.name` field set.
local function normalise_servers(raw)
    if type(raw) ~= "table" then return {} end
    local out = {}
    -- Detect array shape: numeric keys from 1..#raw
    if #raw > 0 then
        for _, entry in ipairs(raw) do
            if type(entry) == "table" then
                table.insert(out, entry)
            end
        end
    else
        -- Map shape: keys are server names
        for name, entry in pairs(raw) do
            if type(entry) == "table" then
                local rec = {}
                for k, v in pairs(entry) do rec[k] = v end
                rec.name = rec.name or name
                table.insert(out, rec)
            end
        end
    end
    return out
end

function M.call(args, _ctx)
    local server_filter = args.server_name

    local raw = config.get("mcp_servers") or {}
    local servers = normalise_servers(raw)
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
