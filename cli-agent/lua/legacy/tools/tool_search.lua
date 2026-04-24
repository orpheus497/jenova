-- tools/tool_search.lua — ToolSearchTool: Search available tools
-- Helps discover and look up tool schemas.

local tool_registry = require("tools.registry")

local M = {}
M.name = "ToolSearch"
M.description = "Search for available tools by name or keyword. Returns tool names and descriptions."

M.parameters = {
    type = "object",
    properties = {
        query = { type = "string", description = "Search query to match against tool names and descriptions" },
        max_results = { type = "integer", description = "Maximum results to return (default: 5)" },
    },
    required = { "query" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "ToolSearch" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local query = args.query
    if not query then return { type = "error", error = "No query provided" } end

    local max_results = args.max_results or 5
    local query_lower = query:lower()

    local all_tools = tool_registry.get_all()
    local matches = {}

    for _, tool in ipairs(all_tools) do
        local name_lower = tool.name:lower()
        local desc_lower = (type(tool.description) == "string" and tool.description or ""):lower()

        -- Score based on match quality
        local score = 0
        if name_lower == query_lower then
            score = 100
        elseif name_lower:find(query_lower, 1, true) then
            score = 50
        elseif desc_lower:find(query_lower, 1, true) then
            score = 25
        end

        if score > 0 then
            table.insert(matches, { tool = tool, score = score })
        end
    end

    -- Sort by score descending
    table.sort(matches, function(a, b) return a.score > b.score end)

    -- Format results
    local lines = {}
    for i, match in ipairs(matches) do
        if i > max_results then break end
        local desc = type(match.tool.description) == "string"
            and match.tool.description:sub(1, 80) or ""
        table.insert(lines, string.format("%s — %s", match.tool.name, desc))
    end

    if #lines == 0 then
        return { type = "text", text = "No tools matching '" .. query .. "'" }
    end

    return { type = "text", text = table.concat(lines, "\n") }
end

return M
