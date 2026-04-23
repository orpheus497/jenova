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
  table.insert(lines, "- Workspace cwd: " .. vim.fn.getcwd())
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

  -- Always list every open buffer (not just count) so the model can answer
  -- "the other files I have open" without first calling Buffers. Capped at
  -- 20 entries to keep the system prompt small.
  if #bufs > 0 then
    table.insert(lines, "- Open buffers (" .. #bufs .. "):")
    for i, b in ipairs(bufs) do
      if i > 20 then
        table.insert(lines, "    … (" .. (#bufs - 20) .. " more)")
        break
      end
      table.insert(lines, "    • " .. b)
    end
  end

  -- Sibling files in the current file's directory — the most common
  -- "related files" the user means when they say "the other files".
  if path ~= "[scratch]" and path ~= "" then
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir and dir ~= "" and vim.fn.isdirectory(dir) == 1 then
      local handle = vim.uv.fs_scandir(dir)
      if handle then
        local siblings = {}
        while true do
          local name, t = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if t == "file" and not name:match("^%.") then
            table.insert(siblings, name)
          end
        end
        table.sort(siblings)
        if #siblings > 0 then
          table.insert(lines, string.format("- Files in %s/ (%d):",
            vim.fn.fnamemodify(dir, ":~:."), #siblings))
          for i, name in ipairs(siblings) do
            if i > 30 then
              table.insert(lines, "    … (" .. (#siblings - 30) .. " more)")
              break
            end
            table.insert(lines, "    • " .. name)
          end
        end
      end
    end
  end

  if sel then
    table.insert(lines, "- Active selection:\n```\n" .. sel .. "\n```")
  end

  return table.concat(lines, "\n")
end

function M.build_system_prompt()
  local base = table.concat({
    "You are Jenova, an expert coding assistant embedded inside jvim.",
    "You have direct access to the user's editor buffers, LSP, and the full project file system.",
    "",
    "## File traversal — use these tools, do NOT guess",
    "  • Buffers — list every file the user currently has open (tabs/buffers)",
    "  • LS      — list a directory's contents (tree view, default depth 3)",
    "  • Glob    — find files by pattern; use `**/*.ext` for recursive matches",
    "  • Grep    — search file contents across the workspace",
    "  • Read    — read a file or open buffer (returns line-numbered output)",
    "  • Edit / MultiEdit / Write — modify files (live buffers when open)",
    "",
    "## Mandatory workflow",
    "When the user asks you to inspect, debug, or report on multiple files:",
    "  1. Call **Buffers** first if they reference 'open', 'these', 'related' files.",
    "  2. Call **LS** on the relevant directory if they reference 'this directory',",
    "     'the parent directory', 'all files in X', 'the include folder', etc.",
    "  3. Then call **Read** on each discovered file — one Read per file. You MUST",
    "     chain the calls in the same turn; do not stop after a single Read when",
    "     the user clearly asked for multiple files.",
    "  4. Only after every relevant file has been Read, write your analysis.",
    "",
    "## Absolute rules — never break these",
    "  • NEVER fabricate or guess file contents. If you have not Read a file in",
    "    this conversation, you do not know what it contains. Say so and call Read.",
    "  • NEVER invent header bodies, function prototypes, or Makefile rules from",
    "    the file name alone. Always Read first, then quote the actual content.",
    "  • NEVER write `<tool_response>`, `</tool_response>`, `<observation>`,",
    "    `<tool_result>`, `<function_response>`, or any similar tag. Tool output",
    "    is delivered to you by the runtime as a separate `tool` message — you",
    "    do not have to (and must not) write it yourself. Emitting these tags",
    "    is fabrication and will be discarded.",
    "  • NEVER assume a tool succeeded with the answer you wanted. After every",
    "    tool call, STOP and wait for the real `tool` message. Only then continue.",
    "  • Emit each tool call in its OWN ```json fence, one JSON object per fence.",
    "    Do not concatenate multiple JSON objects in one fence.",
    "",
    "Relative paths resolve against the workspace root (jvim's cwd).",
    "Prefer Read on a buffer over re-reading from disk when a file is open.",
    "Be concise and precise. Apply edits directly rather than describing them unless asked.",
  }, "\n")

  local editor_ctx = safe(M.build_editor_context)
  if editor_ctx then
    return base .. "\n\n" .. editor_ctx
  end
  return base
end

return M
