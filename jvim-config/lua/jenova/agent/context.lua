-- jenova/agent/context.lua
-- Builds the editor-state system prompt injected before every agent query.
-- Provides: current file, cursor position, LSP diagnostics, open buffers,
-- git branch, and any active visual selection.

local M = {}

local function safe(fn, ...)
  local ok, v = pcall(fn, ...)
  return ok and v or nil
end

local function git_branch()
  local result = safe(function()
    return vim.system({ "git", "branch", "--show-current" }, { text = true }):wait()
  end)
  if result and result.code == 0 and result.stdout then
    return vim.trim(result.stdout)
  end
  return nil
end

local function git_status_short()
  local result = safe(function()
    return vim.system({ "git", "status", "--porcelain" }, { text = true }):wait()
  end)
  if result and result.code == 0 and result.stdout then
    local lines = vim.split(vim.trim(result.stdout), "\n", { plain = true })
    local changed = 0
    for _, l in ipairs(lines) do
      if l ~= "" then changed = changed + 1 end
    end
    return changed
  end
  return 0
end

local function current_file_info()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then path = "[scratch]" end
  local ft  = vim.bo[buf].filetype or ""
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  return path, ft, row, col + 1
end

local function open_buffers()
  local bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        table.insert(bufs, vim.fn.fnamemodify(name, ":~:."))
      end
    end
  end
  return bufs
end

local function lsp_diagnostics_summary(buf)
  local diags = safe(vim.diagnostic.get, buf)
  if not diags or #diags == 0 then return nil end
  local counts = { error = 0, warn = 0, info = 0, hint = 0 }
  local sev = vim.diagnostic.severity
  for _, d in ipairs(diags) do
    if d.severity == sev.ERROR then counts.error = counts.error + 1
    elseif d.severity == sev.WARN  then counts.warn  = counts.warn  + 1
    elseif d.severity == sev.INFO  then counts.info  = counts.info  + 1
    elseif d.severity == sev.HINT  then counts.hint  = counts.hint  + 1
    end
  end
  local parts = {}
  if counts.error > 0 then table.insert(parts, counts.error .. " error(s)") end
  if counts.warn  > 0 then table.insert(parts, counts.warn  .. " warning(s)") end
  if counts.info  > 0 then table.insert(parts, counts.info  .. " info") end
  if counts.hint  > 0 then table.insert(parts, counts.hint  .. " hint(s)") end
  return #parts > 0 and table.concat(parts, ", ") or nil
end

local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
  local buf = vim.api.nvim_get_current_buf()
  local sl  = vim.fn.line("'<")
  local el  = vim.fn.line("'>")
  if sl == 0 or el == 0 then return nil end
  local lines = vim.api.nvim_buf_get_lines(buf, sl - 1, el, false)
  return table.concat(lines, "\n")
end

-- ── Public ────────────────────────────────────────────────────────────────────

function M.build_editor_context()
  local buf = vim.api.nvim_get_current_buf()
  local path, ft, row, col = current_file_info()
  local branch  = git_branch()
  local changes = git_status_short()
  local diag    = lsp_diagnostics_summary(buf)
  local sel     = visual_selection()
  local bufs    = open_buffers()

  local lines = { "## Editor Context" }
  table.insert(lines, string.format("- Current file: %s  (line %d, col %d)",
    vim.fn.fnamemodify(path, ":~:."), row, col))
  if ft ~= "" then
    table.insert(lines, "- Filetype: " .. ft)
  end
  if diag then
    table.insert(lines, "- LSP diagnostics: " .. diag)
  end
  if branch then
    local git_line = "- Git: branch `" .. branch .. "`"
    if changes > 0 then
      git_line = git_line .. ", " .. changes .. " changed file(s)"
    end
    table.insert(lines, git_line)
  end
  if #bufs > 1 then
    local shown = {}
    for i, b in ipairs(bufs) do
      if i > 8 then table.insert(shown, "… (" .. (#bufs - 8) .. " more)"); break end
      table.insert(shown, b)
    end
    table.insert(lines, "- Open buffers: " .. table.concat(shown, ", "))
  end
  if sel then
    table.insert(lines, "- Active selection:\n```\n" .. sel .. "\n```")
  end

  return table.concat(lines, "\n")
end

function M.build_system_prompt()
  local base = table.concat({
    "You are Jenova, an expert coding assistant embedded inside jvim.",
    "You have direct access to the user's editor buffers, LSP, and file system.",
    "Prefer buffer tools over file tools when reading or editing code.",
    "Be concise and precise. Apply edits directly rather than explaining them unless asked.",
  }, "\n")

  local editor_ctx = safe(M.build_editor_context)
  if editor_ctx then
    return base .. "\n\n" .. editor_ctx
  end
  return base
end

return M
