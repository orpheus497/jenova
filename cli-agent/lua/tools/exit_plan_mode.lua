-- tools/exit_plan_mode.lua — ExitPlanModeTool
-- Returns to normal mode with full tool access.

local app_state = require("state.app_state")

local M = {}
M.name = "ExitPlanMode"
M.description = "Exit plan mode and return to normal mode with full tool access."
M.input_schema = { type = "object", properties = {} }

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Exit Plan Mode" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    app_state.set("permission_mode", "default")
    app_state.set("current_screen", "repl")
    return {
        type = "text",
        text = "Exited plan mode. Full tool access restored.",
    }
end

return M
