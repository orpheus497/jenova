-- tools/powershell.lua — PowerShell Tool: Execute PowerShell commands (Windows)

local M = {}
M.name = "PowerShell"
M.description = "Execute PowerShell commands. Only available on Windows."

M.parameters = {
    type = "object",
    properties = {
        command = { type = "string", description = "PowerShell command to execute" },
        timeout = { type = "integer", description = "Timeout in milliseconds (default 120000)" },
    },
    required = { "command" }
}

function M.is_enabled()
    return false
end

function M.is_read_only() return false end
function M.user_facing_name() return "PowerShell" end

function M.check_permissions(args, ctx)
    return { allowed = true }
end

local shell = require("utils.shell")

function M.call(args, ctx)
    local command = args.command
    if not command or #command == 0 then
        return { type = "error", error = "No command provided" }
    end

    local timeout_ms = args.timeout or 120000

    -- Use jenova.process.spawn if available
    if jenova and jenova.process and jenova.process.spawn then
        local json = require("utils.json_fallback")
        local ps_cmd = M._find_powershell() .. " -NoProfile -NonInteractive -Command " .. shell.quote(command)
        local config = json.stringify({
            command = ps_cmd,
            timeout_ms = timeout_ms,
            capture_output = true,
        })
        local result_json = jenova.process.spawn(config)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                local output = (result.stdout or "") .. (result.stderr or "")
                if result.exit_code ~= 0 then
                    return { type = "text", text = string.format("[Exit %d]\n%s", result.exit_code, output) }
                end
                return { type = "text", text = output }
            end
        end
    end

    -- Fallback: io.popen
    local ps = M._find_powershell()
    local cmd = string.format('%s -NoProfile -NonInteractive -Command %s 2>&1', ps, shell.quote(command))
    local handle = io.popen(cmd)
    if not handle then
        return { type = "error", error = "Failed to start PowerShell" }
    end
    local output = handle:read("*a")
    handle:close()

    return { type = "text", text = output or "" }
end

function M._find_powershell()
    -- Prefer pwsh (PowerShell Core) over powershell (Windows PowerShell)
    local handle = io.popen("which pwsh 2>/dev/null || where pwsh 2>nul")
    if handle then
        local result = handle:read("*l")
        handle:close()
        if result and #result > 0 then return "pwsh" end
    end
    return "powershell"
end

return M
