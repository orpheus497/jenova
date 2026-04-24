-- jvim-config/lua/jenova/agent/registry.lua
-- Pure jvim-native tool registry. ZERO CLI dependencies.

local M = {}
local tools = {}

-- ── Session-level permission grants ──────────────────────────────────────────
-- Keys: tool name (e.g. "Shell") or "*" for all write tools in this session.
local _session_allowed = {}

function M.reset_permissions()
  _session_allowed = {}
end

-- ── Registry CRUD ─────────────────────────────────────────────────────────────

function M.register(tool)
  tools[tool.name] = tool
end

function M.get(name)
  return tools[name]
end

function M.list()
  local names = {}
  for name, _ in pairs(tools) do table.insert(names, name) end
  table.sort(names)
  return names
end

function M.get_all()
  local res = {}
  for _, t in pairs(tools) do table.insert(res, t) end
  return res
end

function M.clear()
  tools = {}
end

-- ── Interactive permission prompt ─────────────────────────────────────────────
-- Runs inside the engine coroutine; yields to the event loop while the user
-- makes a selection, so jvim stays responsive.

local function format_call_preview(name, args)
  if type(args) ~= "table" then return name end
  local key = args.command or args.file_path or args.path
           or args.pattern or args.query    or args.question
  if type(key) == "string" and #key > 0 then
    return name .. "  " .. key:sub(1, 80)
  end
  return name
end

-- Returns one of: "allow_once", "allow_tool", "allow_all", "deny:<reason>"
local function prompt_user_permission(name, args)
  local co = coroutine.running()
  if not co then return "allow_once" end  -- not in coroutine: allow by default

  local preview  = format_call_preview(name, args)
  local choices  = {
    "Allow once",
    "Allow " .. name .. " for session",
    "Allow all tools for session",
    "Deny",
  }
  local decision = nil

  vim.schedule(function()
    vim.ui.select(choices, {
      prompt = "⚡ Tool: " .. preview,
      kind   = "jenova_permission",
    }, function(_, idx)
      if not idx then
        -- User cancelled the select (Escape) → treat as deny with no reason.
        decision = "deny:"
        coroutine.resume(co)
      elseif idx == 1 then
        decision = "allow_once"
        coroutine.resume(co)
      elseif idx == 2 then
        decision = "allow_tool"
        coroutine.resume(co)
      elseif idx == 3 then
        decision = "allow_all"
        coroutine.resume(co)
      else
        -- Deny selected — ask for an optional reason before resuming.
        vim.ui.input({ prompt = "Deny reason (optional): " }, function(input)
          decision = "deny:" .. (input or "")
          coroutine.resume(co)
        end)
      end
    end)
  end)

  coroutine.yield()
  return decision
end

-- ── Execute ───────────────────────────────────────────────────────────────────

function M.execute(name, args, context)
  local tool = tools[name]
  if not tool then return nil, "Unknown tool: " .. name end

  -- 1. Tool-level automated permission check (e.g. restricted paths).
  if tool.check_permissions then
    local perm = tool.check_permissions(args, context)
    if perm and not perm.allowed then
      return nil, "Permission denied: " .. (perm.reason or "")
    end
  end

  -- 2. Read-only tools (Read, Glob, Grep, LS, LSP, AskUser …) run without
  --    prompting. Write/execute tools require explicit user approval unless
  --    the session already granted permission.
  local is_ro = tool.is_read_only and tool.is_read_only()
  if not is_ro and not _session_allowed["*"] and not _session_allowed[name] then
    local decision = prompt_user_permission(name, args)
    if decision == "allow_tool" then
      _session_allowed[name] = true
    elseif decision == "allow_all" then
      _session_allowed["*"] = true
    elseif decision and decision:match("^deny") then
      local reason = decision:match("^deny:(.*)") or ""
      local msg = "[PERMISSION_DENIED] You declined to allow " .. name .. "."
      if reason ~= "" then
        msg = msg .. " Your reason: " .. reason .. "."
      end
      msg = msg .. " Please try a different approach that does not require " .. name .. "."
      return nil, msg
    end
    -- "allow_once" falls through to execution below.
  end

  -- 3. Execute.
  local ok, result = pcall(tool.call, args, context or {})
  if not ok then return nil, "Tool error: " .. tostring(result) end
  return result
end

return M
