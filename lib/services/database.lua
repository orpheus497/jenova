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
    os.execute("mkdir -p " .. shell_quote(path .. "/chats"))
    return path
end

function database.save_conversation(conv_id, messages)
    local path = database.get_default_workspace() .. "/Chats/" .. conv_id .. ".md"
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
                file:write("## " .. role .. "\n\n")
                file:write(msg.content .. "\n\n")
            end
        end
        file:close()
    end
end

function database.load_conversation(conv_id)
    local path = database.get_default_workspace() .. "/Chats/" .. conv_id .. ".md"
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        
        local messages = {}
        local current_role = nil
        local current_msg = {}
        
        for line in content:gmatch("([^\n]*)\n?") do
            if line:match("^<!-- system: (.*) -->") then
                local sys_content = line:match("^<!-- system: (.*) -->")
                table.insert(messages, {role = "system", content = sys_content})
            elseif line:match("^##%s+(%w+)$") then
                if current_role and #current_msg > 0 then
                    local mapped_role = (current_role == "jenova") and "assistant" or current_role
                    table.insert(messages, {role = mapped_role, content = table.concat(current_msg, "\n")})
                end
                current_role = line:match("^##%s+(%w+)$")
                current_msg = {}
            elseif current_role then
                if line ~= "" or #current_msg > 0 then
                    table.insert(current_msg, line)
                end
            end
        end
        
        if current_role and #current_msg > 0 then
            local mapped_role = (current_role == "jenova") and "assistant" or current_role
            table.insert(messages, {role = mapped_role, content = table.concat(current_msg, "\n")})
        end
        
        return messages
    end
    return {}
end

-- Scan the workspace for notes/files to inject into context
function database.get_folder_notes()
    local path = database.get_default_workspace()
    local notes = {}
    -- Naive scan of .md files in the workspace root
    local p = io.popen("find " .. string.format("%q", path) .. " -maxdepth 1 -name '*.md' -o -name '*.txt'")
    if p then
        for file_path in p:lines() do
            local file = io.open(file_path, "r")
            if file then
                local content = file:read("*a")
                file:close()
                local name = file_path:match("([^/]+)$")
                table.insert(notes, { title = name, content = content })
            end
        end
        p:close()
    end
    return notes
end

return database
