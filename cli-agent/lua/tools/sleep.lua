-- tools/sleep.lua — SleepTool: Wait for a specified duration

local M = {}
M.name = "Sleep"
M.description = "Wait for a specified number of seconds before continuing."

M.input_schema = {
    type = "object",
    properties = {
        seconds = { type = "number", description = "Number of seconds to sleep" },
    },
    required = { "seconds" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name(input)
    return input and input.seconds and ("Sleep " .. input.seconds .. "s") or "Sleep"
end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local seconds = tonumber(args.seconds) or 1
    if not seconds then seconds = 1 end
    if seconds < 0 then seconds = 0 end
    if seconds > 300 then seconds = 300 end -- Cap at 5 minutes

    -- Platform-aware sleep
    if package.config:sub(1, 1) == "\\" then
        -- Windows: use ping as a sleep workaround
        os.execute(string.format("ping -n %d 127.0.0.1 >nul 2>&1", math.ceil(seconds) + 1))
    else
        os.execute(string.format("sleep %.1f", seconds))
    end

    return {
        type = "text",
        text = string.format("Slept for %.1f seconds", seconds),
    }
end

return M
