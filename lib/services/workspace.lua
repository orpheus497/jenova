local database = require("services.database")

local workspace = {}

workspace.INITIAL_IDENTITY = "You are Jenova, of the Jenova Cognitive Architecture (JCA). You operate as a high-privilege, local-first autonomous agent within the designated workspaces. Your mandate is to assist, engage, and refine the user's ideas with precision and context awareness. You are highly capable, direct, and conversational. All outputs are grounded in the provided workspace artifacts, prioritizing clarity and efficiency."

function workspace.get_workspace_context()
    local notes = database.get_folder_notes()
    local context = ""
    
    if #notes > 0 then
        context = context .. "--- NOTES & FILES ---\n"
        for _, note in ipairs(notes) do
            context = context .. "Title: " .. note.title .. "\nContent:\n" .. note.content .. "\n\n"
        end
    end
    
    return context
end

return workspace
