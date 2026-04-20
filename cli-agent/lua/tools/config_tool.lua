-- tools/config_tool.lua — ConfigTool: Read/write Jenova CLI configuration

local json = require("utils.json_fallback")
local config = require("config.loader")

local M = {}
M.name = "Config"
M.description = "Read or write Jenova CLI configuration settings."

M.input_schema = {
    type = "object",
    properties = {
        action = { type = "string", description = "Action: 'get', 'set', or 'list'" },
        key = { type = "string", description = "Configuration key" },
        value = { type = "string", description = "Value to set (for 'set' action)" },
    },
    required = { "action" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "Config" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local action = args.action or "list"

    if action == "get" then
        if not args.key then
            return { type = "error", error = "No key specified" }
        end
        local value = config.get(args.key)
        if value == nil then
            return { type = "text", text = string.format("%s: (not set)", args.key) }
        end
        return { type = "text", text = string.format("%s: %s", args.key, tostring(value)) }

    elseif action == "set" then
        if not args.key then
            return { type = "error", error = "No key specified" }
        end
        config.set(args.key, args.value)
        return { type = "text", text = string.format("Set %s = %s", args.key, tostring(args.value)) }

    elseif action == "list" then
        local all = config.get()
        if not all then
            return { type = "text", text = "No configuration loaded" }
        end
        local lines = {}
        local keys = {}
        for k in pairs(all) do table.insert(keys, k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = all[k]
            if type(v) ~= "table" then
                table.insert(lines, string.format("  %s = %s", k, tostring(v)))
            else
                table.insert(lines, string.format("  %s = %s", k, json.stringify(v)))
            end
        end
        return { type = "text", text = "Configuration:\n" .. table.concat(lines, "\n") }
    end

    return { type = "error", error = "Unknown action: " .. tostring(action) }
end

return M
