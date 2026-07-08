local database = require("services.database")

local workspace = {}

workspace.INITIAL_IDENTITY = "You are Jenova, of the Jenova Cognitive Architecture (JCA). You operate as a high-privilege, local-first autonomous agent within the designated workspaces. Your mandate is to assist, engage, and refine the user's ideas with precision and context awareness. You are highly capable, direct, and conversational. All outputs are grounded in the provided workspace artifacts, prioritizing clarity and efficiency."

function workspace.get_workspace_context()
    local notes = database.get_folder_notes()
    if #notes == 0 then return "" end

    local parts = { "--- NOTES & FILES ---\n" }
    local total_len = #parts[1]
    
    for _, note in ipairs(notes) do
        local next_part = "Title: " .. note.title .. "\nContent:\n" .. note.content .. "\n\n"
        if total_len + #next_part > 100000 then
            table.insert(parts, "\n... (workspace context truncated)\n")
            break
        end
        table.insert(parts, next_part)
        total_len = total_len + #next_part
    end
    
    return table.concat(parts)
end

return workspace
