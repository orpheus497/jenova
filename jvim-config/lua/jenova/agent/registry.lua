-- jvim-config/lua/jenova/agent/registry.lua
-- Pure jvim-native tool registry. ZERO CLI dependencies.

local M = {}
local tools = {}

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

function M.execute(name, args, context)
  local tool = tools[name]
  if not tool then return nil, "Unknown tool: " .. name end
  
  -- Simple jvim-native permission check
  if tool.check_permissions then
    local perm = tool.check_permissions(args, context)
    if perm and not perm.allowed then
      return nil, "Permission denied: " .. (perm.reason or "")
    end
  end

  local ok, result = pcall(tool.call, args, context or {})
  if not ok then return nil, "Tool error: " .. tostring(result) end
  return result
end

return M
