-- tools/enter_plan_mode.lua — EnterPlanModeTool
-- Switches to plan mode which restricts tool access to read-only operations.

local app_state = require("state.app_state")

local M = {}
M.name = "EnterPlanMode"
M.description = "Enter plan mode for high-level architectural planning. Only read-only tools are available in plan mode."
M.input_schema = { type = "object", properties = {} }

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Enter Plan Mode" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    app_state.set("permission_mode", "plan")
    app_state.set("current_screen", "plan")
    return {
        type = "text",
        text = "Entered plan mode. Only read-only tools (Read, Glob, Grep, WebFetch, WebSearch) are available. Use ExitPlanMode to return to normal mode.",
    }
end

return M
