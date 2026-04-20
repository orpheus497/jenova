-- tools/todo_write.lua — TodoWriteTool: Manage a structured task list
-- Tracks progress of multi-step tasks in the current session.

local json = require("utils.json_fallback")
local app_state = require("state.app_state")

local M = {}
M.name = "TodoWrite"
M.description = "Create and manage a structured task list for tracking progress on multi-step tasks."

M.input_schema = {
    type = "object",
    properties = {
        todos = {
            type = "array",
            description = "The updated todo list",
            items = {
                type = "object",
                properties = {
                    content = { type = "string", description = "Task description (imperative form)" },
                    status = { type = "string", description = "Task status: pending, in_progress, or completed" },
                    activeForm = { type = "string", description = "Present continuous form (e.g., 'Running tests')" },
                },
                required = { "content", "status" }
            }
        }
    },
    required = { "todos" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "TodoWrite" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local todos = args.todos
    if not todos then return { type = "error", error = "No todos provided" } end

    -- Store in app state
    app_state.set("todos", todos)

    -- Format display
    local lines = {}
    local completed = 0
    local total = #todos
    local current_task = nil

    for i, todo in ipairs(todos) do
        local icon
        if todo.status == "completed" then
            icon = "[x]"
            completed = completed + 1
        elseif todo.status == "in_progress" then
            icon = "[>]"
            current_task = todo.activeForm or todo.content
        else
            icon = "[ ]"
        end
        table.insert(lines, string.format("  %s %d. %s", icon, i, todo.content))
    end

    local summary = string.format("Updated %d todos (%d/%d completed)", total, completed, total)
    if current_task then
        summary = summary .. string.format("\nCurrently: %s", current_task)
    end

    return { type = "text", text = summary }
end

return M
