-- jenova/agent/tools/buffer_ls.lua
-- jvim-native LS tool for directory traversal.
--
-- The shared cli-agent tool set has no general "list directory" primitive
-- (only Glob, which requires the model to guess a pattern). Without LS the
-- agent can't enumerate folders to discover what files exist — which is
-- exactly the "file traversal" capability the user reported missing.
--
-- Returns a tree-style listing capped at depth 3 by default with .git,
-- .jenova, node_modules and similar noise filtered out.

local paths = require("utils.paths")

local M = {
  name        = "LS",
  description = "List the contents of a directory in tree form. " ..
    "Use this to discover the structure of a folder before reading specific files. " ..
    "Defaults to depth 3 from the given path; pass depth=1 for a shallow listing.",
  parameters  = {
    type = "object",
    properties = {
      path  = { type = "string",  description = "Absolute or workspace-relative directory (default: workspace cwd)" },
      depth = { type = "integer", description = "Maximum traversal depth (default 3, max 5)" },
    },
    required = {},
  },
}

function M.is_enabled()    return true end
function M.is_read_only()  return true end
function M.user_facing_name(input)
  return input and input.path and ("LS: " .. input.path) or "LS"
end
function M.check_permissions(_i, _c) return { allowed = true } end

local IGNORE = {
  [".git"] = true, [".jenova"] = true, [".claude"] = true,
  ["node_modules"] = true, [".cache"] = true, [".venv"] = true,
  ["__pycache__"] = true, [".pytest_cache"] = true,
  ["target"] = true, ["build"] = true, ["dist"] = true,
}

local function walk(root, max_depth, lines, prefix, depth, count)
  if count[1] >= 1000 then return end
  if depth > max_depth then return end

  local handle = vim.uv.fs_scandir(root)
  if not handle then return end

  -- Collect entries first so we can sort dirs-first, alphabetical.
  local entries = {}
  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if not IGNORE[name] and not name:match("^%.") then
      table.insert(entries, { name = name, type = t })
    end
  end
  table.sort(entries, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name < b.name
  end)

  for i, e in ipairs(entries) do
    if count[1] >= 1000 then
      table.insert(lines, prefix .. "└── … (truncated at 1000 entries)")
      return
    end
    local last = (i == #entries)
    local connector = last and "└── " or "├── "
    local label = e.name .. (e.type == "directory" and "/" or "")
    table.insert(lines, prefix .. connector .. label)
    count[1] = count[1] + 1

    if e.type == "directory" then
      local child_prefix = prefix .. (last and "    " or "│   ")
      walk(root .. "/" .. e.name, max_depth, lines, child_prefix, depth + 1, count)
    end
  end
end

function M.call(args, context)
  local raw = args.path
  local include_parent = false
  local root
  if raw and #raw > 0 then
    root = paths.resolve(raw, context and context.cwd)
  else
    -- "LS" with no arguments is the model's way of saying "show me where
    -- I am". List the workspace root AND its parent so cross-directory
    -- analysis tasks (e.g. "fix this file plus everything in the parent
    -- directory") have visibility on both levels in a single call.
    root = (context and context.cwd) or vim.fn.getcwd()
    include_parent = true
  end
  if paths.is_restricted(root) then return paths.restricted_error(root) end

  local abs = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  if vim.fn.isdirectory(abs) == 0 then
    -- Helpful recovery: list the parent so the model can see what siblings
    -- actually exist. Avoids the "the model retries with another guess"
    -- loop after a typo or wrong-cwd assumption.
    local parent = vim.fn.fnamemodify(abs, ":h")
    local hint = ""
    if vim.fn.isdirectory(parent) == 1 then
      local plines = { parent .. "/" }
      walk(parent, 1, plines, "", 1, { 0 })
      hint = "\n\nParent listing (" .. parent .. "):\n" .. table.concat(plines, "\n")
    end
    return { type = "error",
      error = "Not a directory: " .. abs ..
        ". Re-call LS with one of the visible entries instead of guessing." .. hint }
  end

  local depth = math.min(math.max(args.depth or 3, 1), 5)
  local lines = { abs .. "/" }
  walk(abs, depth, lines, "", 1, { 0 })

  -- Auto-include parent listing when called with no arguments. Many user
  -- prompts mention "the current directory and the parent directory" or
  -- "all related files" — surfacing both at once removes the need for the
  -- model to issue a follow-up LS that it might fabricate the answer to.
  if include_parent then
    local parent = vim.fn.fnamemodify(abs, ":h")
    if parent and parent ~= abs and vim.fn.isdirectory(parent) == 1 then
      table.insert(lines, "")
      table.insert(lines, parent .. "/  (parent, depth 1)")
      walk(parent, 1, lines, "", 1, { 0 })
    end
  end

  return {
    type = "text",
    text = table.concat(lines, "\n"),
  }
end

return M
