-- tools/team_create.lua — TeamCreate: Create a team of worker agents
-- Used by the coordinator to define groups of collaborating agents.

local app_state = require("state.app_state")

local M = {}
M.name = "TeamCreate"
M.description = "Create a team of worker agents for coordinated multi-agent task execution."

M.parameters = {
    type = "object",
    properties = {
        name = { type = "string", description = "Team name" },
        description = { type = "string", description = "Team purpose/description" },
        members = {
            type = "array",
            description = "List of agent definitions",
            items = {
                type = "object",
                properties = {
                    role = { type = "string", description = "Agent role (e.g. 'researcher', 'implementer')" },
                    prompt = { type = "string", description = "System prompt for this agent" },
                    tools = { type = "array", items = { type = "string" }, description = "Allowed tools" },
                },
            },
        },
    },
    required = { "name" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "TeamCreate" end

function M.check_permissions()
    return { allowed = true }
end

function M.call(args, ctx)
    local name = args.name
    if not name or #name == 0 then
        return { type = "error", error = "Team name is required" }
    end

    local teams = app_state.get("teams") or {}

    -- Check if team already exists
    for _, team in ipairs(teams) do
        if team.name == name then
            return { type = "error", error = "Team already exists: " .. name }
        end
    end

    local team = {
        id = string.format("team_%d_%s", os.time(), name:gsub("[^%w]", "_"):sub(1, 20)),
        name = name,
        description = args.description or "",
        members = args.members or {},
        created_at = os.time(),
        status = "active",
    }

    table.insert(teams, team)
    app_state.set("teams", teams)

    local member_count = #team.members
    local lines = {
        string.format("Team '%s' created (id: %s)", name, team.id),
        string.format("  Description: %s", team.description),
        string.format("  Members: %d", member_count),
    }

    for i, member in ipairs(team.members) do
        table.insert(lines, string.format("    %d. %s", i, member.role or "worker"))
    end

    return { type = "text", text = table.concat(lines, "\n") }
end

return M
