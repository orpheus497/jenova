-- tools/task_create.lua — TaskCreateTool: Create background tasks

local json = require("utils.json_fallback")
local app_state = require("state.app_state")

local M = {}
M.name = "TaskCreate"
M.description = "Create a new background task that runs independently."

M.input_schema = {
    type = "object",
    properties = {
        description = { type = "string", description = "Description of the task" },
        prompt = { type = "string", description = "Prompt for the task agent" },
    },
    required = { "description", "prompt" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input)
    return input and input.description and ("Task: " .. input.description) or "TaskCreate"
end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local task_id = string.format("task-%d-%04x", os.time(), math.random(0, 65535))

    local tasks = app_state.get("active_tasks") or {}
    table.insert(tasks, {
        id = task_id,
        description = args.description or "unnamed",
        prompt = args.prompt or "",
        status = "pending",
        created_at = os.time(),
        output = nil,
        inbox = {},
    })
    app_state.set("active_tasks", tasks)

    return {
        type = "text",
        text = string.format("Task created: %s (id: %s)", args.description or "unnamed", task_id),
    }
end

return M
