-- tools/snip.lua — SnipTool: Trim conversation history to reduce context

local app_state = require("state.app_state")

local M = {}
M.name = "Snip"
M.description = "Remove older messages from conversation context to free up token space."

M.parameters = {
    type = "object",
    properties = {
        keep_recent = { type = "integer", description = "Number of recent message pairs to keep (default 4)" },
        summary = { type = "string", description = "Optional summary of snipped content to preserve context" },
    },
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "Snip" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local keep_recent = args.keep_recent or 4
    local summary = args.summary

    local messages = app_state.get("messages") or {}
    local original_count = #messages

    if original_count <= keep_recent * 2 then
        return { type = "text", text = string.format("Only %d messages — nothing to snip.", original_count) }
    end

    -- Keep the system message (index 1) and the last keep_recent pairs
    local keep_start = math.max(2, original_count - (keep_recent * 2) + 1)
    local new_messages = {}

    -- Always preserve the first message (system prompt)
    if messages[1] then
        table.insert(new_messages, messages[1])
    end

    -- Add a summary marker if provided
    if summary and #summary > 0 then
        table.insert(new_messages, {
            role = "assistant",
            content = "[Context summary: " .. summary .. "]",
        })
    end

    -- Keep recent messages
    for i = keep_start, original_count do
        table.insert(new_messages, messages[i])
    end

    app_state.set("messages", new_messages)

    local removed = original_count - #new_messages
    return {
        type = "text",
        text = string.format("Snipped %d messages. Kept %d (from %d total).", removed, #new_messages, original_count)
    }
end

return M
