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

-- Simulating the Dexie database for conversation history
function database.save_conversation(conv_id, messages)
    local path = database.get_default_workspace() .. "/chats/" .. conv_id .. ".json"
    local file = io.open(path, "w")
    if file then
        file:write(json.encode(messages))
        file:close()
    end
end

function database.load_conversation(conv_id)
    local path = database.get_default_workspace() .. "/chats/" .. conv_id .. ".json"
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local ok, parsed = pcall(json.decode, content)
        if ok and parsed then
            return parsed
        end
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
