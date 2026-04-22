-- tools/brief.lua — BriefTool: Deliver a plain-text response to the user
-- This is the ONLY tool the model should call when the correct action is
-- to reply with words rather than take a system action. It lets the model
-- satisfy tool_choice="required" while still producing a conversational reply.

local M = {}
M.name = "Brief"
M.description = [[Deliver a final plain-text reply to the user. Call this ONLY when all required actions are fully complete and you have concrete results to report.

FORBIDDEN uses of Brief:
- Announcing what you are about to do ("I will run make", "I'll read the file", "Let me check...")
- Saying you are "proceeding", "running", or "checking" anything
- Responding to "proceed", "go ahead", or "continue" with words instead of action
- Calling Brief mid-task before the work is done

CORRECT use: call the appropriate action tool first (Shell, Read, Edit, etc.), complete all work, THEN call Brief with the actual results.]]

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
