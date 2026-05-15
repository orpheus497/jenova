local ui = {}
local root = ""

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- LAN mode state file path (resolved after init)
local function lan_state_file()
    return root .. "/.jenova/lan_mode"
end

-- Read persisted LAN mode state (pcall-wrapped for I/O safety)
local function is_lan_enabled()
    local ok, f = pcall(io.open, lan_state_file(), "r")
    if not ok or not f then return false end
    local read_ok, val = pcall(f.read, f, "*l")
    f:close()
    if not read_ok then return false end
    return val == "1"
end

-- Persist LAN mode state (shell-safe path quoting)
local function set_lan_state(enabled)
    -- Shell-quote the path to prevent injection via root containing metacharacters
    local dir = root .. "/.jenova"
    os.execute("mkdir -p " .. shell_quote(dir) .. " 2>/dev/null")
    local ok, f = pcall(io.open, lan_state_file(), "w")
    if ok and f then
        f:write(enabled and "1" or "0")
        f:close()
    end
end

-- Cache detected HTTP probe tool at module level to avoid spawning
-- `command -v` subprocesses on every 3-second poll cycle.
local _cached_probe_tool = nil
local _probe_tool_checked = false

local function detect_probe_tool()
    if _probe_tool_checked then return _cached_probe_tool end
    _probe_tool_checked = true

    if os.execute("command -v curl >/dev/null 2>&1") == 0 then
        _cached_probe_tool = "curl"
    elseif os.execute("command -v nc >/dev/null 2>&1") == 0 then
        _cached_probe_tool = "nc"
    elseif os.execute("command -v fetch >/dev/null 2>&1") == 0 then
        _cached_probe_tool = "fetch"   -- FreeBSD base system
    end
    return _cached_probe_tool
end

ui.init = function(root_path)
    root = root_path or ""
    -- Pre-cache probe tool on init so first poll_status is fast
    detect_probe_tool()
end

ui.get_menu = function()
    local lan_label = is_lan_enabled() and "Disable LAN (switch to Local)" or "Enable LAN (allow network access)"
    return {
        { label = "Open Web UI", action = "web" },
        { label = "System Control", action = "tui" },
        { separator = true },
        { label = "Start Server", action = "start" },
        { label = "Stop Server", action = "stop" },
        { label = "Restart Server", action = "restart" },
        { separator = true },
        { label = lan_label, action = "toggle_lan" },
        { separator = true },
        { label = "Quit", action = "quit" }
    }
end

ui.on_action = function(action)
    if not action then return end

    if action == "web" then
        -- FreeBSD: use xdg-open if present, fall back to open(1)
        local opener = "xdg-open"
        if os.execute("command -v xdg-open >/dev/null 2>&1") ~= 0 then
            opener = "open" -- macOS / FreeBSD with xdg-utils missing
        end
        sys_exec_async(shell_quote(opener) .. " http://localhost:8080")
    elseif action == "tui" then
        local bin_term = shell_quote(root .. "/bin/jenova-term")
        local bin_ui = shell_quote(root .. "/bin/jenova-ui")
        sys_exec_async(bin_term .. " " .. bin_ui .. " tui")
    elseif action == "start" then
        if is_lan_enabled() then
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " start --lan")
        else
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " start")
        end
    elseif action == "stop" then
        sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " stop")
    elseif action == "restart" then
        if is_lan_enabled() then
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " restart --lan")
        else
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " restart")
        end
    elseif action == "toggle_lan" then
        local currently_lan = is_lan_enabled()
        set_lan_state(not currently_lan)
        -- Restart with new mode
        if not currently_lan then
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " restart --lan")
        else
            sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " restart")
        end
    elseif action == "quit" then
        sys_exec_async(shell_quote(root .. "/bin/jenova-ca") .. " stop")
        quit_app()
    end
end

ui.poll_status = function()
    -- 1. Check if backend pipeline reports ready using its own status command
    -- which correctly respects configured ports and runs internal healthchecks.
    local f1 = io.popen(shell_quote(root .. "/bin/jenova-ca") .. " status 2>&1", "r")
    if not f1 then return "inactive" end
    local output_backend = f1:read("*a")
    f1:close()

    if output_backend and output_backend:match("is ready") then
        return "active"
    end

    return "inactive"
end

-- Extended status for TUI: returns mode info alongside active/inactive
ui.get_status_info = function()
    local status = ui.poll_status()
    local lan = is_lan_enabled()
    local mode_str = "LOCAL"
    
    if lan then
        -- Attempt to get the actual LAN IP address
        local cmd = "ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
        local f = io.popen(cmd, "r")
        local ip = nil
        if f then
            ip = f:read("*l")
            f:close()
        end
        if not ip or ip == "" then
            -- Fallback for FreeBSD/macOS
            local cmd_ifconfig = "ifconfig | awk '/inet / && !/127.0.0.1/ {print $2}' | head -n 1"
            local f2 = io.popen(cmd_ifconfig, "r")
            if f2 then
                ip = f2:read("*l")
                f2:close()
            end
        end
        
        if ip and ip ~= "" then
            mode_str = "LAN (" .. ip .. ")"
        else
            mode_str = "LAN (0.0.0.0)"
        end
    else
        mode_str = "LOCAL (127.0.0.1)"
    end

    return {
        status = status,
        mode = mode_str,
        lan_enabled = lan,
    }
end

ui.get_tui_menu = function()
    local lan_label = is_lan_enabled() and "Disable LAN Mode" or "Enable LAN Mode"
    return {
        { label = "Start Backend", action = "start" },
        { label = "Stop Backend", action = "stop" },
        { label = "Restart Backend", action = "restart" },
        { label = lan_label, action = "toggle_lan" },
        { label = "Launch J-Vim", action = "jvim" },
        { label = "Launch Web UI", action = "web" },
        { label = "Exit", action = "exit_tui" }
    }
end

ui.on_tui_action = function(action)
    if not action then return end

    if action == "jvim" then
        local bin_term = shell_quote(root .. "/bin/jenova-term")
        local bin_jvim = shell_quote(root .. "/bin/jvim")
        sys_exec_async(bin_term .. " " .. bin_jvim)
    elseif action == "exit_tui" then
        -- Handled in C
    else
        ui.on_action(action)
    end
end

_G.ui = ui
return ui
