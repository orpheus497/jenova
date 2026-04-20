-- tools/schedule_cron.lua — ScheduleCron: Schedule recurring tasks

local app_state = require("state.app_state")

local M = {}
M.name = "ScheduleCron"
M.description = "Create, list, or remove scheduled recurring tasks."

M.parameters = {
    type = "object",
    properties = {
        action = { type = "string", description = "Action: 'create', 'list', 'remove', 'run'" },
        name = { type = "string", description = "Task name" },
        schedule = { type = "string", description = "Cron expression (e.g. '*/5 * * * *')" },
        command = { type = "string", description = "Command or prompt to execute" },
        task_id = { type = "string", description = "Task ID for remove/run actions" },
    },
    required = { "action" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "ScheduleCron" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local action = args.action

    if action == "create" then
        return M._create(args)
    elseif action == "list" then
        return M._list()
    elseif action == "remove" then
        return M._remove(args)
    elseif action == "run" then
        return M._run(args)
    end

    return { type = "error", error = "Unknown action: " .. tostring(action) .. ". Use: create, list, remove, run" }
end

function M._create(args)
    if not args.name or not args.schedule or not args.command then
        return { type = "error", error = "name, schedule, and command are required for 'create'" }
    end

    local schedules = app_state.get("cron_schedules") or {}
    local id = string.format("cron_%d_%s", os.time(), args.name:gsub("[^%w]", "_"):sub(1, 20))

    table.insert(schedules, {
        id = id,
        name = args.name,
        schedule = args.schedule,
        command = args.command,
        created_at = os.time(),
        last_run = nil,
        enabled = true,
    })

    app_state.set("cron_schedules", schedules)

    return {
        type = "text",
        text = string.format("Scheduled task '%s' (id: %s)\n  Schedule: %s\n  Command: %s",
            args.name, id, args.schedule, args.command)
    }
end

function M._list()
    local schedules = app_state.get("cron_schedules") or {}

    if #schedules == 0 then
        return { type = "text", text = "No scheduled tasks." }
    end

    local lines = { string.format("Scheduled tasks (%d):", #schedules) }
    for _, sched in ipairs(schedules) do
        local status = sched.enabled and "active" or "paused"
        local last = sched.last_run and os.date("%Y-%m-%d %H:%M:%S", sched.last_run) or "never"
        table.insert(lines, string.format("  %s: %s [%s] (schedule: %s, last run: %s)",
            sched.id, sched.name, status, sched.schedule, last))
    end

    return { type = "text", text = table.concat(lines, "\n") }
end

function M._remove(args)
    local task_id = args.task_id or args.name
    if not task_id then
        return { type = "error", error = "task_id or name required for 'remove'" }
    end

    local schedules = app_state.get("cron_schedules") or {}
    local new_schedules = {}
    local removed = false

    for _, sched in ipairs(schedules) do
        if sched.id == task_id or sched.name == task_id then
            removed = true
        else
            table.insert(new_schedules, sched)
        end
    end

    if not removed then
        return { type = "error", error = "Task not found: " .. task_id }
    end

    app_state.set("cron_schedules", new_schedules)
    return { type = "text", text = "Removed scheduled task: " .. task_id }
end

function M._run(args)
    local task_id = args.task_id or args.name
    if not task_id then
        return { type = "error", error = "task_id or name required for 'run'" }
    end

    local schedules = app_state.get("cron_schedules") or {}
    for i, sched in ipairs(schedules) do
        if sched.id == task_id or sched.name == task_id then
            local output = ""
            if jenova and jenova.process and jenova.process.spawn then
                local json = require("utils.json_fallback")
                local shell = require("utils.shell")
                local config = json.stringify({
                    command = "sh",
                    args = { "-c", sched.command },
                    timeout_ms = 60000,
                    capture_output = true,
                })
                local result_json = jenova.process.spawn(config)
                if result_json then
                    local ok, result = pcall(json.parse, result_json)
                    if ok and result then
                        output = (result.stdout or "") .. (result.stderr or "")
                    end
                end
            else
                local shell = require("utils.shell")
                local quoted = shell.quote(sched.command)
                local handle = io.popen("sh -c " .. quoted .. " 2>&1")
                if handle then
                    output = handle:read("*a")
                    handle:close()
                end
            end

            sched.last_run = os.time()
            schedules[i] = sched
            app_state.set("cron_schedules", schedules)

            return {
                type = "text",
                text = string.format("Ran task '%s':\n%s", sched.name, output)
            }
        end
    end

    return { type = "error", error = "Task not found: " .. task_id }
end

return M
