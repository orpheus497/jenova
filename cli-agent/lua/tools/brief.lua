-- tools/brief.lua — BriefTool: Deliver a plain-text response to the user
-- This is the ONLY tool the model should call when the correct action is
-- to reply with words rather than take a system action. It lets the model
-- satisfy tool_choice="required" while still producing a conversational reply.

local M = {}
M.name = "Brief"
M.description = [[Respond to the user with a plain-text message. Call this when the task is complete and you need to report results, explain findings, answer a question, or ask for clarification. Do NOT call other tools to "search" or "fetch" information before using Brief — if you already have the answer, call Brief directly.]]

M.parameters = {
    type = "object",
    properties = {
        response = {
            type = "string",
            description = "Your response to the user. Plain text, markdown is supported.",
        },
    },
    required = { "response" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "Brief" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local response = args.response or ""
    -- The caller (query_engine) detects Brief calls and surfaces the response
    -- as the final turn text instead of continuing the agentic loop.
    return { type = "text", text = response, is_brief = true }
end

return M
