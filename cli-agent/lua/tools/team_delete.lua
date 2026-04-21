-- tools/team_delete.lua — TeamDelete: Delete a team of worker agents

local app_state = require("state.app_state")

local M = {}
M.name = "TeamDelete"
M.description = "Delete a team and stop its worker agents."

M.parameters = {
    type = "object",
    properties = {
        team_id = { type = "string", description = "Team ID or name to delete" },
        force = { type = "boolean", description = "Force delete even if agents are running" },
    },
    required = { "team_id" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "TeamDelete" end

function M.check_permissions()
    return { allowed = true }
end

function M.call(args, ctx)
    local team_id = args.team_id
    if not team_id or #team_id == 0 then
        return { type = "error", error = "team_id is required" }
    end

    local teams = app_state.get("teams") or {}
    local new_teams = {}
    local removed_team = nil

    for _, team in ipairs(teams) do
        if team.id == team_id or team.name == team_id then
            removed_team = team
        else
            table.insert(new_teams, team)
        end
    end

    if not removed_team then
        return { type = "error", error = "Team not found: " .. team_id }
    end

    -- Stop running agents if needed
    local agents_stopped = 0
    if removed_team.members then
        local tasks = app_state.get("active_tasks") or {}
        for _, member in ipairs(removed_team.members) do
            if member.task_id then
                for i, task in ipairs(tasks) do
                    if task.id == member.task_id and task.status == "running" then
                        task.status = "stopped"
                        task.stopped_at = os.time()
                        tasks[i] = task
                        agents_stopped = agents_stopped + 1
                    end
                end
            end
        end
        if agents_stopped > 0 then
            app_state.set("active_tasks", tasks)
        end
    end

    app_state.set("teams", new_teams)

    local msg = string.format("Team '%s' deleted.", removed_team.name)
    if agents_stopped > 0 then
        msg = msg .. string.format(" Stopped %d running agent(s).", agents_stopped)
    end

    return { type = "text", text = msg }
end

return M
