local ui = {}
local root = ""

ui.init = function(root_path)
    root = root_path or ""
end

ui.get_menu = function()
    return {
        { label = "Open Web UI", action = "web" },
        { label = "System Control", action = "tui" },
        { separator = true },
        { label = "Start Server", action = "start" },
        { label = "Stop Server", action = "stop" },
        { label = "Restart Server", action = "restart" },
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
        sys_exec_async(opener .. " http://localhost:8080")
    elseif action == "tui" then
        sys_exec_async(root .. "/bin/jenova-term " .. root .. "/bin/jenova-ui tui")
    elseif action == "start" then
        sys_exec_async(root .. "/bin/jenova-ca start")
    elseif action == "stop" then
        sys_exec_async(root .. "/bin/jenova-ca stop")
    elseif action == "restart" then
        sys_exec_async(root .. "/bin/jenova-ca restart")
    elseif action == "quit" then
        sys_exec_async(root .. "/bin/jenova-ca stop")
        quit_app()
    end
end

ui.poll_status = function()
    -- 1. Check if backend pipeline reports ready
    local f1 = io.popen(root .. "/bin/jenova-ca status 2>&1", "r")
    if not f1 then return "inactive" end
    local output_backend = f1:read("*a")
    local ok1, _, code1 = f1:close()

    if not output_backend or not output_backend:match("is ready") then
        return "inactive"
    end

    -- 2. Check if port 8080 is actually accepting connections
    -- Use the most portable method available: curl > nc > fetch (FreeBSD)
    local cmd
    if os.execute("command -v curl >/dev/null 2>&1") == 0 then
        cmd = "curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8080/ 2>/dev/null"
    elseif os.execute("command -v nc >/dev/null 2>&1") == 0 then
        cmd = "nc -z -w 1 127.0.0.1 8080 2>/dev/null && echo active || echo inactive"
    elseif os.execute("command -v fetch >/dev/null 2>&1") == 0 then
        -- FreeBSD base system has fetch(1)
        cmd = "fetch -q -o /dev/null -T 2 http://127.0.0.1:8080/ 2>/dev/null && echo active || echo inactive"
    else
        -- Last resort: try /dev/tcp if bash, otherwise assume inactive
        return "inactive"
    end

    local f2 = io.popen(cmd, "r")
    if not f2 then return "inactive" end
    local output_port = f2:read("*l")
    f2:close()

    if not output_port then return "inactive" end

    -- curl returns HTTP status code; anything 200-399 is active
    local http_code = tonumber(output_port)
    if http_code then
        if http_code >= 200 and http_code < 400 then
            return "active"
        else
            return "inactive"
        end
    end

    -- nc / fetch return "active" or "inactive" string
    if output_port == "active" then
        return "active"
    end

    return "inactive"
end

ui.get_tui_menu = function()
    return {
        { label = "Start Backend", action = "start" },
        { label = "Stop Backend", action = "stop" },
        { label = "Restart Backend", action = "restart" },
        { label = "Launch J-Vim", action = "jvim" },
        { label = "Launch Web UI", action = "web" },
        { label = "Exit", action = "exit_tui" }
    }
end

ui.on_tui_action = function(action)
    if not action then return end

    if action == "jvim" then
        sys_exec_async(root .. "/bin/jenova-term " .. root .. "/bin/jvim")
    elseif action == "exit_tui" then
        -- Handled in C
    else
        ui.on_action(action)
    end
end

_G.ui = ui
return ui
