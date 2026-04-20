-- tools/ask_user.lua — AskUserQuestionTool
local M = {}
M.name = "AskUserQuestion"
M.description = "Ask the user a question and wait for their response."
M.input_schema = { type = "object", properties = { question = { type = "string", description = "Question to ask" } }, required = { "question" } }
function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "AskUser" end
function M.check_permissions() return { allowed = true } end
function M.call(args, ctx)
    io.write("\n❓ " .. args.question .. "\n> ")
    io.flush()
    local answer = io.read("*l")
    return { type = "text", text = answer or "" }
end
return M
