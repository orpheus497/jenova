-- jenova/agent/utils/paths.lua
-- jvim-native path utilities. No CLI or FFI dependencies.

local M = {}

-- Paths matching these patterns are off-limits for read/write operations.
local RESTRICTED = {
  "/%.system/",
  "/%.jenova/",
  "/%.claude/",
  "/%.ssh/",
  "/%.gnupg/",
  "/%.git/objects/",
  "/%.git/refs/",
}

--- Resolve a path against cwd. Returns an absolute path string.
function M.resolve(path, cwd)
  if not path or path == "" then
    return cwd or vim.fn.getcwd()
  end
  if path:sub(1, 1) == "~" then
    return vim.fn.expand(path)
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  return (cwd or vim.fn.getcwd()) .. "/" .. path
end

--- Returns true if path falls inside a restricted location.
function M.is_restricted(path)
  if not path then return false end
  local p = vim.fn.fnamemodify(path, ":p")
  for _, pat in ipairs(RESTRICTED) do
    if p:find(pat) then return true end
  end
  return false
end

--- Standard error table returned when a restricted path is accessed.
function M.restricted_error(path)
  return { type = "error", error = "Access denied — restricted path: " .. tostring(path) }
end

return M
