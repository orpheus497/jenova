-- agent/ui.lua — Terminal UI (from legacy-agent)
--
-- Pure ANSI terminal UI with:
--   - ASCII art header
--   - 256-color palette
--   - Spinner animation
--   - Structured status output
--   - Terminal size detection via ioctl

local M = {}

local P = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    cyan    = "\27[38;5;80m",
    green   = "\27[38;5;114m",
    yellow  = "\27[38;5;220m",
    red     = "\27[38;5;196m",
    blue    = "\27[38;5;69m",
    magenta = "\27[38;5;141m",
    grey    = "\27[38;5;245m",
    white   = "\27[38;5;255m",
}

local _cached_width = nil
local _cached_width_time = 0

local function get_terminal_width()
    local now = os.time()
    if _cached_width and (now - _cached_width_time) < 5 then
        return _cached_width
    end
    local f = io.popen("tput cols 2>/dev/null")
    if f then
        local w = tonumber(f:read("*l"))
        f:close()
        _cached_width = w or 80
    else
        _cached_width = 80
    end
    _cached_width_time = now
    return _cached_width
end

function M.show_header()
    local width = get_terminal_width()
    if width >= 52 then
        print(P.cyan .. [[
   ╔═══════════════════════════════════════════╗
   ║       CLI-AGENT · Pure C + Lua            ║
   ║       Local LLM · Agentic Tools           ║
   ╚═══════════════════════════════════════════╝]] .. P.reset)
    else
        print(P.cyan .. "── CLI-AGENT ──" .. P.reset)
    end
    print("")
end

function M.prompt()
    return P.green .. "❯ " .. P.reset
end

function M.status_ok(msg)
    io.write(P.green .. "✓ " .. P.reset .. msg .. "\n")
end

function M.status_err(msg)
    io.write(P.red .. "✗ " .. P.reset .. msg .. "\n")
end

function M.status_warn(msg)
    io.write(P.yellow .. "⚠ " .. P.reset .. msg .. "\n")
end

function M.status_info(tool_name, status)
    local color = status == "ok" and P.green or P.red
    io.write(P.grey .. "  [" .. P.reset .. color .. tool_name .. P.reset .. P.grey .. "] " .. P.reset .. status .. "\n")
end

function M.status_turn(n)
    io.write(P.dim .. string.format("── turn %d ", n) .. string.rep("─", 40) .. P.reset .. "\n")
end

function M.shell_cmd(cmd)
    io.write(P.grey .. "  $ " .. P.reset .. cmd .. "\n")
end

function M.shell_result(output, exit_code)
    if exit_code ~= 0 then
        io.write(P.red .. "  exit " .. tostring(exit_code) .. P.reset .. "\n")
    end
    if output and #output > 0 then
        local lines = {}
        for line in output:gmatch("[^\n]+") do
            table.insert(lines, "  " .. line)
            if #lines >= 20 then
                table.insert(lines, "  ... (truncated)")
                break
            end
        end
        io.write(P.dim .. table.concat(lines, "\n") .. P.reset .. "\n")
    end
end

function M.file_info(action, path)
    io.write(P.blue .. "  " .. action .. ": " .. P.reset .. path .. "\n")
end

function M.separator()
    io.write(P.dim .. string.rep("─", get_terminal_width()) .. P.reset .. "\n")
end

function M.thinking()
    io.write(P.dim .. "  thinking..." .. P.reset)
    io.flush()
end

function M.thinking_done()
    io.write("\r" .. string.rep(" ", 40) .. "\r")
end

return M
