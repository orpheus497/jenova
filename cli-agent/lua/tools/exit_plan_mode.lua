-- tools/exit_plan_mode.lua — ExitPlanModeTool
-- Returns to normal mode with full tool access.

local M = {}
M.name = "ExitPlanMode"
M.description = "Exit plan mode and return to normal mode with full tool access."
M.parameters = { type = "object", properties = {} }

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Exit Plan Mode" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local ok_cfg, config = pcall(require, "config.loader")
    if ok_cfg and config and config.set then
        config.set("permission_mode", "default")
    end
    local ok_st, app_state = pcall(require, "state.app_state")
    if ok_st and app_state and app_state.set then
        app_state.set("current_screen", "repl")
    end
    return {
        type = "text",
        text = "Exited plan mode. Full tool access restored.",
    }
end

return M
