local ui = {}
local root = ""

ui.init = function(root_path)
    root = root_path
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
    if action == "web" then
        sys_exec_async("xdg-open http://localhost:8080")
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
    -- 1. Check if backend pipeline is ready
    local f1 = io.popen(root .. "/bin/jenova-ca status 2>&1", "r")
    if not f1 then return "inactive" end
    local output_backend = f1:read("*a")
    f1:close()
    
    if not (output_backend and output_backend:match("is ready")) then
        return "inactive"
    end
    
    -- 2. Check if port 8080 is actually accepting connections
    local cmd = "if curl -s -o /dev/null http://127.0.0.1:8080/; then echo active; elif nc -z -w 1 127.0.0.1 8080 2>/dev/null; then echo active; else echo inactive; fi"
    local f2 = io.popen(cmd, "r")
    if not f2 then return "inactive" end
    local output_port = f2:read("*l")
    f2:close()
    
    if output_port == "active" then
        return "active"
    else
        return "inactive"
    end
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
