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

local function parse_metadata_from_buffer(chat_buf)
  local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local ctx = { path = nil, start_line = nil, end_line = nil }
  for i = #lines, 1, -1 do
    local line = lines[i]
    local p = line:match("## Active Context: (.*)")
    if p then
      ctx.path = vim.trim(p)
      break
    end
    local ps, s, e = line:match("## Active Selection: (.*) %(lines (%d+)-(%d+)%)")
    if ps then
      ctx.path = vim.trim(ps)
      ctx.start_line = tonumber(s)
      ctx.end_line = tonumber(e)
      break
    end
  end
  return ctx
end

local function get_buffer_content(path, start_line, end_line)
  local abs = vim.fn.fnamemodify(path, ":p")
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, (start_line or 1) - 1, end_line or -1, false)
  return table.concat(lines, "\n")
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- Pinned workspace buffer — set by chat.lua the moment a chat split opens,
-- while the source file is still the current buffer. This is more reliable
-- than guessing from window state later inside the agent coroutine.
local _pinned_workspace_buf = nil

function M.set_workspace_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    _pinned_workspace_buf = buf
  end
end

local function get_best_workspace_buf()
  -- 0. Use pinned buf captured at chat-open time (most reliable).
  if _pinned_workspace_buf and vim.api.nvim_buf_is_valid(_pinned_workspace_buf) then
    local n = vim.api.nvim_buf_get_name(_pinned_workspace_buf)
    if n ~= "" and vim.bo[_pinned_workspace_buf].buftype == "" then
      return _pinned_workspace_buf
    end
    _pinned_workspace_buf = nil  -- stale, fall through
  end

  -- 1. Try active buffer if it's a real file
  local active = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(active)
  if name ~= "" and vim.bo[active].buftype == "" and not name:match("/jenova/chats/") then
    return active
  end

  -- 2. Try the first window that isn't the chat or tree
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    local n = vim.api.nvim_buf_get_name(b)
    if n ~= "" and vim.bo[b].buftype == "" and not n:match("/jenova/chats/") then
      return b
    end
  end
  return nil
end

function M.build_editor_context(chat_buf)
  local ws_buf = get_best_workspace_buf()
  local path = ws_buf and vim.api.nvim_buf_get_name(ws_buf) or ""
  local ft = ws_buf and vim.bo[ws_buf].filetype or "?"
  local row, col = 0, 0
  if ws_buf then
    local cursor = vim.api.nvim_win_get_cursor(0) -- fallback to global if ws_buf not focused
    -- Better: if ws_buf is in a window, get that window's cursor
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == ws_buf then
        cursor = vim.api.nvim_win_get_cursor(win)
        break
      end
    end
    row, col = cursor[1], cursor[2]
  end

  local branch = git_branch()
  local diag = ws_buf and lsp_diagnostics_summary(ws_buf) or nil
  local sel = visual_selection()
  local bufs = open_buffers()
  
  -- Metadata from chat
  local metadata = chat_buf and parse_metadata_from_buffer(chat_buf) or {}

  local lines = { "## Context" }
  table.insert(lines, "cwd: " .. vim.fn.getcwd())
  
  if ws_buf and path ~= "" then
    table.insert(lines, string.format("file: %s:%d:%d (%s)",
      vim.fn.fnamemodify(path, ":~:."), row, col + 1, ft))

    -- Inject the full active buffer with line numbers. The agent has the
    -- complete file from the start and can reference exact line numbers in
    -- Edit/MultiEdit without a prior Read call.
    local all_lines = vim.api.nvim_buf_get_lines(ws_buf, 0, -1, false)
    local numbered = {}
    for i, l in ipairs(all_lines) do
      table.insert(numbered, string.format("%6d | %s", i, l))
    end
    local rel = vim.fn.fnamemodify(path, ":~:.")
    table.insert(lines, string.format("active_buffer (%s, %d lines):\n```\n%s\n```",
      rel, #all_lines, table.concat(numbered, "\n")))
  end

  if metadata.path and metadata.path ~= path then
    local content = get_buffer_content(metadata.path, metadata.start_line, metadata.end_line)
    if content and content ~= "" then
      local label = metadata.start_line
        and string.format("context (%s lines %d-%d)", metadata.path, metadata.start_line, metadata.end_line)
        or  string.format("context (%s)", metadata.path)
      table.insert(lines, label .. ":\n```\n" .. content .. "\n```")
    end
  end

  if diag then table.insert(lines, "diagnostics: " .. diag) end
  if branch then table.insert(lines, "git: " .. branch) end

  -- Compact one-line buffer list (max 8 entries) — full list available via Buffers tool.
  if #bufs > 0 then
    local shown, n = {}, math.min(#bufs, 8)
    for i = 1, n do table.insert(shown, bufs[i]) end
    local extra = #bufs > n and (" +" .. (#bufs - n)) or ""
    table.insert(lines, "buffers: " .. table.concat(shown, ", ") .. extra)
  end

  if sel then
    table.insert(lines, "selection:\n```\n" .. sel .. "\n```")
  end

  return table.concat(lines, "\n")
end

-- Returns just the active buffer content as a formatted message string,
-- suitable for injection as the first background exchange in a new session.
-- This gives the model the file prominently in conversation history (it is
-- also present in the system prompt via build_editor_context).
function M.build_file_seed_prompt()
  local ws_buf = safe(get_best_workspace_buf)
  if not ws_buf then return nil end
  local path = vim.api.nvim_buf_get_name(ws_buf)
  if not path or path == "" then return nil end
  local all_lines = vim.api.nvim_buf_get_lines(ws_buf, 0, -1, false)
  if #all_lines == 0 then return nil end
  local numbered = {}
  for i, l in ipairs(all_lines) do
    table.insert(numbered, string.format("%6d | %s", i, l))
  end
  local rel = vim.fn.fnamemodify(path, ":~:.")
  local ft  = vim.bo[ws_buf].filetype or "?"
  return string.format(
    "I have the following file open in my editor. Use it as the primary context for this session.\n\nFile: %s (%s)\n```\n%s\n```",
    rel, ft, table.concat(numbered, "\n"))
end

function M.build_system_prompt(chat_buf)
  local base = table.concat({
    "You are JENOVA, built by orpheus497. You are a high-privilege autonomous AGENT integrated directly into the jvim editor.",
    "You are NOT a chatbot. You do not simply discuss code; you IMPLEMENT it by modifying the filesystem.",
    "Your primary way of interacting is through TOOL CALLS. Text output should be minimal and focused on reasoning.",
    "",
    "## CORE DIRECTIVES",
    "1. ACTION OVER DISCUSSION: If the user asks for a change, use Edit/MultiEdit immediately.",
    "2. NO HALLUCINATIONS: Do not claim you lack filesystem access. You are integrated into the editor and have the capability to modify files.",
    "3. PERMISSION LAYER: All tool calls (Shell, Edit, Write, etc.) are intercepted by a permission manager. The user will approve or deny each action. DO NOT ask for permission in text; simply issue the tool call and wait for the result.",
    "4. NO PLACEHOLDERS: Implement the full requested logic. Do not use '// ...' or 'rest of code'.",
    "5. MANDATORY TOOL USE: If you output code in a markdown block without calling a tool, you have FAILED the task.",
    "",
    "## Tools (Call with: ```json {\"name\":..,\"arguments\":{..}} ```)",
    "- Read(file_path, start_line?, end_line?): View code with line numbers.",
    "- LSP(action, file_path?, line?, character?, query?): Diagnostics, definition, references, symbols.",
    "- Edit(file_path, start_line, end_line, new_string): Replace line range.",
    "- MultiEdit(file_path, edits[{start_line, end_line, new_string}]): Batch edits.",
    "- Shell(command): Run tests/build. (Not for diagnostics).",
    "- Glob(pattern), Grep(pattern, path?), LS(path?): Search files.",
    "- AskUserQuestion(question): Prompt user for input.",
    "",
    "## Rules",
    "0. JUST ACT. Do not discuss what you are going to do. Issue the tool calls required to complete the task. The permission manager will handle the approval flow.",
    "- Never invent file contents. Read first.",
    "- Never write <tool_response>, <observation>, or <result>. Wait for the system response.",
    "- Multi-file tasks: discover with LS/Glob, then issue one Read per file in the same turn.",
    "- You MUST Read a file before any Edit/MultiEdit. Use exact line numbers from the Read output.",
    "- Relative paths resolve against workspace cwd (shown below).",
    "- Be terse. Apply edits directly.",
  }, "\n")

  local editor_ctx = safe(M.build_editor_context, chat_buf)
  if editor_ctx then
    return base .. "\n\n" .. editor_ctx
  end
  return base
end

return M
