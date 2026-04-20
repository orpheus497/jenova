-- tools/synthetic_output.lua — SyntheticOutput: Inject assistant-visible output
-- Used by coordinators/agents to relay information into the conversation
-- without it appearing as a user message.

local app_state = require("state.app_state")

local M = {}
M.name = "SyntheticOutput"
M.description = "Inject synthetic assistant output into the conversation stream."

M.parameters = {
    type = "object",
    properties = {
        content = { type = "string", description = "Content to inject as synthetic output" },
        source = { type = "string", description = "Source label (e.g. worker agent name)" },
    },
    required = { "content" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "SyntheticOutput" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local content = args.content
    if not content or #content == 0 then
        return { type = "error", error = "No content provided" }
    end

    local source = args.source or "system"

    -- Append as a synthetic message in the conversation
    local messages = app_state.get("messages") or {}
    table.insert(messages, {
        role = "assistant",
        content = content,
        synthetic = true,
        source = source,
        timestamp = os.time(),
    })
    app_state.set("messages", messages)

    return {
        type = "text",
        text = string.format("Injected synthetic output from '%s' (%d chars).", source, #content)
    }
end

return M
