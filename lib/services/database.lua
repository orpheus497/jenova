local database = {}
local json = require("json")

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- In a native environment, we use the JENOVA_WORKSPACES directory as the root.
function database.get_workspace_path()
    local path = os.getenv("JENOVA_WORKSPACES")
    if not path then
        local home = os.getenv("HOME")
        if home then
            path = home .. "/JCA/Workspaces"
        else
            path = "/tmp/JCA/Workspaces"
        end
    end
    os.execute("mkdir -p " .. shell_quote(path))
    return path
end

function database.get_default_workspace()
    local path = database.get_workspace_path() .. "/default"
    os.execute("mkdir -p " .. shell_quote(path))
    os.execute("mkdir -p " .. shell_quote(path .. "/Chats"))
    return path
end

function database.save_conversation_to_path(path, conv_id, messages)
    local file = io.open(path, "w")
    if file then
        file:write("# topic: " .. conv_id .. " [agent]\n")
        file:write("- model: jenova\n")
        file:write("- temperature: 0.7\n")
        file:write("- top_p: 0.9\n")
        file:write("---\n\n")
        
        for _, msg in ipairs(messages) do
            if msg.role == "system" then
                if msg.content and msg.content ~= "" then
                    file:write("<!-- system: " .. msg.content:gsub("\n", " ") .. " -->\n\n")
                end
            else
                local role = (msg.role == "assistant") and "jenova" or msg.role
                file:write("<!-- role: " .. role .. " -->\n\n")
                file:write((msg.content or "") .. "\n\n")
            end
        end
        file:close()
    end
end

function database.parse_conversation_content(content)
    local messages = {}
    if not content or content == "" then return messages end
    
    local current_role = nil
    local current_msg = {}
    
    for line in content:gmatch("([^\n]*)\n?") do
        local sys_content = line:match("^<!-- system: (.*) -->")
        if sys_content then
            table.insert(messages, {role = "system", content = sys_content})
        else
            local r = line:match("^<!%-%-%s*role:%s*(%w+)%s*%-%->")
            if r then r = r:lower() end
            if r == "user" or r == "jenova" or r == "assistant" then
                if current_role and #current_msg > 0 then
                    local mapped_role = (current_role == "jenova") and "assistant" or current_role
                    table.insert(messages, {role = mapped_role, content = table.concat(current_msg, "\n")})
                end
                current_role = r
                current_msg = {}
            elseif current_role then
            if line ~= "" or #current_msg > 0 then
                table.insert(current_msg, line)
            end
        end
        end
    end
    
    if current_role and #current_msg > 0 then
        local mapped_role = (current_role == "jenova") and "assistant" or current_role
        table.insert(messages, {role = mapped_role, content = table.concat(current_msg, "\n")})
    end
    
    return messages
end

function database.load_conversation_from_path(path)
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        return database.parse_conversation_content(content or "")
    end
    return {}
end

-- Scan the workspace for notes/files to inject into context
function database.get_folder_notes()
    local path = database.get_default_workspace()
    local notes = {}
    -- Naive scan of .md files in the workspace root
    if path:find("[\r\n]") then
        error("Command injection attempt detected")
    end
    local p = io.popen("find " .. shell_quote(path) .. " " .. shell_quote(path .. "/Notes") .. " " .. shell_quote(path .. "/Files") .. " " .. shell_quote(path .. "/Chats") .. " -maxdepth 1 -name '*.md' -o -name '*.txt' 2>/dev/null")
    if p then
        for file_path in p:lines() do
            local file = io.open(file_path, "r")
            if file then
                local content = file:read(16385)
                file:close()
                if content then
                    if #content > 16384 then content = content:sub(1, 16384) .. "\n... (truncated)" end
                    local name = file_path:match("([^/]+)$")
                    table.insert(notes, { title = name, content = content })
                    if #notes >= 15 then break end
                end
            end
        end
        p:close()
    end
    return notes
end

return database
