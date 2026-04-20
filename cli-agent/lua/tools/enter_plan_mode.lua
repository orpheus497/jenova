-- tools/enter_plan_mode.lua — EnterPlanModeTool
-- Switches to plan mode which restricts tool access to read-only operations.

local M = {}
M.name = "EnterPlanMode"
M.description = "Enter plan mode for high-level architectural planning. Only read-only tools are available in plan mode."
M.parameters = { type = "object", properties = {} }

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Enter Plan Mode" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local ok_cfg, config = pcall(require, "config.loader")
    if ok_cfg and config and config.set then
        config.set("permission_mode", "plan")
    end
    local ok_st, app_state = pcall(require, "state.app_state")
    if ok_st and app_state and app_state.set then
        app_state.set("permission_mode", "plan")
        app_state.set("current_screen", "plan")
    end
    return {
        type = "text",
        text = "Entered plan mode. Only read-only tools (Read, Glob, Grep, WebFetch, WebSearch) are available. Use ExitPlanMode to return to normal mode.",
    }
end

return M
