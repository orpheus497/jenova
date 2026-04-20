-- tools/task_base.lua — Factory for task management tools
-- Creates task tools (create, get, list, update, stop, output) with shared state.

local app_state = require("state.app_state")

local function make_task_tool(name, description)
    local M = {}
    M.name = name
    M.description = description

    -- Per-tool schemas. All task tools accept a task_id; TaskUpdate also
    -- accepts a new status so callers (and schema-driven UIs) can reflect
    -- the actual contract.
    local properties = {
        task_id = { type = "string", description = "Task ID" },
    }
    local required = { "task_id" }

    if name == "TaskUpdate" then
        properties.status = {
            type = "string",
            description = "New status for the task (e.g. 'pending', 'running', 'completed', 'stopped')",
        }
    elseif name == "TaskList" then
        -- TaskList takes no arguments.
        required = {}
    end

    M.input_schema = {
        type = "object",
        properties = properties,
        required = required,
    }

    function M.is_enabled() return true end
    function M.is_read_only()
        return name ~= "TaskCreate" and name ~= "TaskUpdate" and name ~= "TaskStop"
    end
    function M.user_facing_name() return name end
    function M.check_permissions() return { allowed = true } end

    function M.call(args, ctx)
        local tasks = app_state.get("active_tasks") or {}

        if name == "TaskGet" then
            for _, task in ipairs(tasks) do
                if task.id == args.task_id then
                    return {
                        type = "text",
                        text = string.format("Task: %s\nStatus: %s\nDescription: %s",
                            task.id, task.status or "unknown", task.description or ""),
                    }
                end
            end
            return { type = "error", error = "Task not found: " .. (args.task_id or "") }

        elseif name == "TaskList" then
            if #tasks == 0 then
                return { type = "text", text = "No active tasks." }
            end
            local lines = {}
            for _, task in ipairs(tasks) do
                table.insert(lines, string.format("  %s  [%s]  %s",
                    task.id or "?", task.status or "?", task.description or ""))
            end
            return { type = "text", text = "Tasks:\n" .. table.concat(lines, "\n") }

        elseif name == "TaskStop" then
            for _, task in ipairs(tasks) do
                if task.id == args.task_id then
                    task.status = "stopped"
                    app_state.set("active_tasks", tasks)
                    return { type = "text", text = "Task " .. task.id .. " stopped" }
                end
            end
            return { type = "error", error = "Task not found: " .. (args.task_id or "") }

        elseif name == "TaskUpdate" then
            for _, task in ipairs(tasks) do
                if task.id == args.task_id then
                    task.status = args.status or task.status
                    app_state.set("active_tasks", tasks)
                    return { type = "text", text = "Task " .. task.id .. " updated" }
                end
            end
            return { type = "error", error = "Task not found: " .. (args.task_id or "") }

        elseif name == "TaskOutput" then
            for _, task in ipairs(tasks) do
                if task.id == args.task_id then
                    return { type = "text", text = task.output or "(no output yet)" }
                end
            end
            return { type = "error", error = "Task not found: " .. (args.task_id or "") }

        else
            return { type = "text", text = name .. " executed" }
        end
    end

    return M
end

return make_task_tool
