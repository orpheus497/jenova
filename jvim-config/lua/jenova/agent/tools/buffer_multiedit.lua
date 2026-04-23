-- jenova/agent/tools/buffer_multiedit.lua
-- jvim-native override for the shared "MultiEdit" tool.
-- Applies multiple sequential find-and-replace edits to a file.
-- Edits in an open buffer are batched and applied in a single nvim_buf_set_lines call.

local paths = require("utils.paths")

local M = {
  name        = "MultiEdit",
  description = "Apply multiple sequential find-and-replace edits to a single file in one operation. " ..
    "You MUST Read the file first. Each edit's old_string is matched against the current file state after prior edits. " ..
    "When the file is open in jvim, the live buffer is updated in real-time.",
  parameters  = {
    type = "object",
    properties = {
      file_path = { type = "string", description = "Absolute or repo-relative file path to edit" },
      edits = {
        type = "array",
        description = "Array of edit operations applied in order",
        items = {
          type = "object",
          properties = {
            old_string  = { type = "string", description = "Exact text to find (must match verbatim including whitespace)" },
            new_string  = { type = "string", description = "Replacement text" },
            replace_all = { type = "boolean", description = "Replace all occurrences (default false)" },
          },
          required = { "old_string", "new_string" }
        }
      }
    },
    required = { "file_path", "edits" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
  return input and input.file_path and ("MultiEdit: " .. input.file_path) or "MultiEdit"
end

function M.check_permissions(input, ctx)
  local ok_mgr, manager = pcall(require, "permissions.manager")
  if not ok_mgr or not manager or not manager.can_use_tool then
    return { allowed = true }
  end
  local allowed, reason = manager.can_use_tool("MultiEdit", input, ctx or {})
  return { allowed = allowed, reason = reason }
end

local function find_buf_by_path(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs_path then return b end
    end
  end
  return nil
end

local function apply_edits_to_content(content, edits, path)
  for i, edit in ipairs(edits) do
    local old_str = edit.old_string
    local new_str = edit.new_string
    local replace_all = edit.replace_all or false

    local plain_count = 0
    local start = 1
    while true do
      local s = content:find(old_str, start, true)
      if not s then break end
      plain_count = plain_count + 1
      start = s + #old_str
    end

    if plain_count == 0 then
      return nil, string.format("Edit %d failed: old_string not found in %s", i, path)
    end
    if plain_count > 1 and not replace_all then
      return nil, string.format("Edit %d failed: old_string matches %d locations in %s — add more context or use replace_all=true", i, plain_count, path)
    end

    if replace_all then
      local escaped = old_str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
      content = content:gsub(escaped, new_str:gsub("%%", "%%%%"))
    else
      local s = content:find(old_str, 1, true)
      content = content:sub(1, s - 1) .. new_str .. content:sub(s + #old_str)
    end
  end
  return content, nil
end

function M.call(args, context)
  local raw_path = args.file_path or args.path
  if not raw_path or raw_path == "" then return { type = "error", error = "file_path is required" } end
  local edits = args.edits
  if type(edits) ~= "table" or #edits == 0 then return { type = "error", error = "edits array is required and must not be empty" } end

  local resolved = paths.resolve(raw_path, context and context.cwd)
  if paths.is_restricted(resolved) then return paths.restricted_error(resolved) end

  local abs = vim.fn.fnamemodify(resolved, ":p")

  local buf = find_buf_by_path(abs)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    
    local new_content, err = apply_edits_to_content(content, edits, abs)
    if err then return { type = "error", error = err } end

    local new_lines = vim.split(new_content, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.bo[buf].modified = true

    local bname = vim.api.nvim_buf_get_name(buf)
    if bname ~= "" then
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent! write " .. vim.fn.fnameescape(bname))
      end)
    end
    return { type = "text", text = "Edits applied successfully to buffer" }
  end

  local f = io.open(abs, "r")
  if not f then return { type = "error", error = "file not found: " .. abs } end
  local content = f:read("*a")
  f:close()

  local new_content, err = apply_edits_to_content(content, edits, abs)
  if err then return { type = "error", error = err } end

  local wf = io.open(abs, "w")
  if not wf then return { type = "error", error = "cannot write file: " .. abs } end
  wf:write(new_content)
  wf:close()
  return { type = "text", text = "Edits applied successfully to disk" }
end

return M
