-- jenova/agent/tools/remember.lua
-- Explicit fact pin. The agent calls Remember when the user dictates
-- something durable ("the build command is X", "always run gofmt before
-- commit", "this codebase uses 2-space indent for Lua"). Auto-extraction
-- from tool outcomes covers most observed facts, but Remember exists for
-- preferences and policies that no tool result will ever surface.

local M = {
  name        = "Remember",
  description = "Pin a durable fact to long-term memory (user preferences, project conventions, build commands the user dictates). Memory is auto-injected into the system prompt when relevant. Use sparingly: use only when the user explicitly states something durable.",
  parameters  = {
    type = "object",
    properties = {
      text = { type = "string", description = "One-sentence fact to remember." },
      tags = {
        type        = "array",
        items       = { type = "string" },
        description = "Optional tags (e.g. 'pref', 'build', 'lang:lua', 'file:path').",
      },
      scope = {
        enum        = { "workspace", "global" },
        description = "workspace = only this project, global = every project. Default: workspace.",
      },
    },
    required = { "text" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input)
  return input and input.text and ("Remember: " .. input.text:sub(1, 60)) or "Remember"
end
function M.check_permissions(input, _ctx)
  if not input or type(input.text) ~= "string" or input.text == "" then
    return { allowed = false, reason = "text is required" }
  end
  return { allowed = true }
end

function M.call(args, _ctx)
  local memory = require("jenova.agent.memory")
  local scope
  if args.scope == "global" then
    scope = "global"
  end
  local id = memory.record(args.text, {
    tags       = args.tags,
    source     = "agent:Remember",
    confidence = 0.9,
    scope      = scope,   -- nil → defaults to workspace
  })
  if not id then
    return { type = "error", error = "Failed to record fact" }
  end
  return { type = "text", text = "Remembered: " .. args.text .. " (id=" .. id .. ")" }
end

return M
