-- jvim-native AskUserQuestion: prompts via vim.ui.input.
-- Overrides the cli-agent shared/tools/ask_user.lua which uses io.read
-- (would block jvim's event loop).
local M = {}
M.name = "AskUserQuestion"
M.description = "Ask the user a question and wait for their response."
M.parameters = {
  type = "object",
  properties = { question = { type = "string", description = "Question to ask" } },
  required = { "question" },
}
function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "AskUser" end
function M.check_permissions() return { allowed = true } end

function M.call(args)
  local q = args and args.question or ""
  -- vim.ui.input is async; bridge to coroutine wait.
  local co = coroutine.running()
  local answer
  if co then
    vim.schedule(function()
      vim.ui.input({ prompt = q .. " " }, function(input)
        answer = input or ""
        coroutine.resume(co)
      end)
    end)
    coroutine.yield()
  else
    -- Synchronous fallback: pop a modal prompt.
    answer = vim.fn.input(q .. " ") or ""
  end
  return { type = "text", text = answer or "" }
end

return M
