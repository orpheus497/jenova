-- tools/brief.lua — BriefTool: Toggle brief/verbose response mode

local app_state = require("state.app_state")

local M = {}
M.name = "Brief"
M.description = "Toggle brief mode for shorter, more concise responses."

M.parameters = {
    type = "object",
    properties = {
        enabled = { type = "boolean", description = "Enable or disable brief mode" },
    },
    required = { "enabled" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Brief" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local enabled = args.enabled
    app_state.set("brief_mode", enabled)

    if enabled then
        return { type = "text", text = "Brief mode enabled. Responses will be shorter." }
    else
        return { type = "text", text = "Brief mode disabled. Normal verbose responses." }
    end
end

return M
