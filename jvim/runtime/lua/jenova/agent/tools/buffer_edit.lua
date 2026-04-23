-- jenova/agent/tools/buffer_edit.lua
-- Replaces cli-agent's file_edit.lua when running inside jvim.
-- Applies search-and-replace edits via vim.api.nvim_buf_set_lines so:
--   • Edits are immediately visible in the open buffer (real-time preview)
--   • Undo history is preserved inside vim
--   • No disk I/O, no stale-file risk

local M = {
  name        = "Edit",
  description = "Edit a file using exact search-and-replace. " ..
    "old_string must match the file content exactly (including whitespace). " ..
    "When the file is open in jvim the live buffer is updated in real-time. " ..
    "Use replace_all=true to replace every occurrence.",
  parameters  = {
    type = "object",
    properties = {
      path        = { type = "string",  description = "File path to edit" },
      old_string  = { type = "string",  description = "Exact text to find" },
      new_string  = { type = "string",  description = "Replacement text" },
      replace_all = { type = "boolean", description = "Replace all occurrences (default false)" },
    },
    required = { "path", "old_string", "new_string" },
  },
}

local function find_buf_by_path(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs or bname == path then
        return b
      end
    end
  end
  return nil
end

local function buf_apply_edit(buf, old_str, new_str, replace_all)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Count occurrences
  local count = 0
  for _ in content:gmatch(old_str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), 1) do
    count = count + 1
  end
  -- Use plain find to count exact occurrences
  local plain_count = 0
  local start = 1
  while true do
    local s = content:find(old_str, start, true)
    if not s then break end
    plain_count = plain_count + 1
    start = s + #old_str
  end

  if plain_count == 0 then
    return nil, "old_string not found in " .. vim.api.nvim_buf_get_name(buf)
  end
  if plain_count > 1 and not replace_all then
    return nil, string.format(
      "old_string matches %d locations — add more context to make it unique, or use replace_all=true",
      plain_count)
  end

  local new_content
  if replace_all then
    -- gsub needs escaped pattern
    local escaped = old_str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
    new_content = content:gsub(escaped, new_str:gsub("%%", "%%%%"))
  else
    local s = content:find(old_str, 1, true)
    new_content = content:sub(1, s - 1) .. new_str .. content:sub(s + #old_str)
  end

  local new_lines = vim.split(new_content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  vim.bo[buf].modified = true
  return true, nil
end

local function disk_apply_edit(path, old_str, new_str, replace_all)
  local abs = vim.fn.fnamemodify(path, ":p")
  local f = io.open(abs, "r")
  if not f then return nil, "file not found: " .. path end
  local content = f:read("*a")
  f:close()

  local plain_count = 0
  local start = 1
  while true do
    local s = content:find(old_str, start, true)
    if not s then break end
    plain_count = plain_count + 1
    start = s + #old_str
  end

  if plain_count == 0 then
    return nil, "old_string not found in " .. path
  end
  if plain_count > 1 and not replace_all then
    return nil, string.format(
      "old_string matches %d locations in %s — add more context or use replace_all=true",
      plain_count, path)
  end

  local new_content
  if replace_all then
    local escaped = old_str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
    new_content = content:gsub(escaped, new_str:gsub("%%", "%%%%"))
  else
    local s = content:find(old_str, 1, true)
    new_content = content:sub(1, s - 1) .. new_str .. content:sub(s + #old_str)
  end

  local wf = io.open(abs, "w")
  if not wf then return nil, "cannot write file: " .. path end
  wf:write(new_content)
  wf:close()
  return true, nil
end

function M.call(args, _ctx)
  local path       = args.path
  local old_string = args.old_string
  local new_string = args.new_string
  local replace_all = args.replace_all or false

  if not path or path == "" then return { error = "path is required" } end
  if old_string == nil then return { error = "old_string is required" } end
  if new_string == nil then return { error = "new_string is required" } end

  local buf = find_buf_by_path(path)
  if buf then
    local ok, err = buf_apply_edit(buf, old_string, new_string, replace_all)
    if not ok then return { error = err } end
    -- Auto-save if the buffer has a file backing
    local bname = vim.api.nvim_buf_get_name(buf)
    if bname ~= "" then
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent! write " .. vim.fn.fnameescape(bname))
      end)
    end
    return { success = true, source = "buffer" }
  end

  local ok, err = disk_apply_edit(path, old_string, new_string, replace_all)
  if not ok then return { error = err } end
  return { success = true, source = "disk" }
end

return M
