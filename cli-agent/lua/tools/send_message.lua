-- tools/send_message.lua — SendMessageTool: Send a message to another agent or task

local json = require("utils.json_fallback")

local M = {}
M.name = "SendMessage"
M.description = "Send a message to another running agent or task by ID."

M.parameters = {
    type = "object",
    properties = {
        to = { type = "string", description = "Target agent or task ID" },
        content = { type = "string", description = "Message content to send" },
    },
    required = { "to", "content" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input)
    return input and input.to and ("Message to " .. input.to) or "SendMessage"
end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local to = args.to
    local content = args.content
    if not to then return { type = "error", error = "No target specified" } end
    if not content then return { type = "error", error = "No message content" } end

    -- Check if target task/agent exists in app state
    local app_state = require("state.app_state")
    local tasks = app_state.get("active_tasks") or {}

    for _, task in ipairs(tasks) do
        if task.id == to or task.name == to then
            -- Queue message for the task
            task.inbox = task.inbox or {}
            table.insert(task.inbox, {
                from = "user",
                content = content,
                timestamp = os.time(),
            })
            app_state.set("active_tasks", tasks)
            return {
                type = "text",
                text = string.format("Message sent to %s", to),
            }
        end
    end

    return {
        type = "text",
        text = string.format("Agent/task '%s' not found. It may have completed or not been started yet.", to),
    }
end

return M
