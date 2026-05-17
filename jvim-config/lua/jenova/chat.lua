local M = {}

local function ep()
  return require("jenova.endpoints")
end

local JENOVA_HOME = vim.env.JENOVA_HOME or (vim.fn.expand("$HOME") .. "/Jenova")
local WORKSPACE_ROOT = vim.env.JENOVA_WORKSPACES or (JENOVA_HOME .. "/Workspaces")
local DEFAULT_WORKSPACE = "default"
local CHAT_DIR = WORKSPACE_ROOT .. "/" .. DEFAULT_WORKSPACE .. "/Chats"
local MODEL = "jenova"
local SECRET = "jenova-local"
local TEMPERATURE = 0.7
local TOP_P = 0.9
local CHAT_WIDTH = 60

-- ── Mode state ────────────────────────────────────────────────────────────────
-- agent_mode=true  → full QueryEngine loop with tool use and editor context
-- agent_mode=false → plain streaming direct to proxy (legacy behaviour)
local agent_mode = true

local active_job      = nil
local toggle_buf      = nil
local toggle_win      = nil
local stop_generation  -- forward-declared so BufDelete autocmd can reference it

-- ── Agent activity state (read by statusline) ─────────────────────────────────
-- These are module-level so jvim.statusline can poll them without requiring
-- a direct callback registration.
M._agent_running   = false   -- true while a query coroutine is active
M._agent_tool      = nil     -- name of currently running tool, or nil
M._agent_turn      = 0       -- current turn index
M._agent_tokens_in  = 0
M._agent_tokens_out = 0
M._agent_cost       = 0.0

-- ── Highlights ────────────────────────────────────────────────────────────────
-- Custom colour for chat-specific glyphs that markdown syntax does not cover:
-- role headers, tool ✓/✗ badges, indented tool-output preview lines.
local HL_NS = vim.api.nvim_create_namespace("JenovaChat")

-- Palette mirrors the jvim colorscheme (powdery dark — maroon / royal-purple
-- / plum / tan / peach). When pywal is available we adopt its accent slots
-- so the chat blends with the rest of the editor and the user's wallpaper.
local FALLBACK_PALETTE = {
  user_hdr     = "#7A6AA0",  -- royal purple (matches Function/Tag)
  jenova_hdr   = "#9B4F6D",  -- maroon (matches Keyword/Statement)
  ok           = "#926A96",  -- plum
  fail         = "#C4685E",  -- coral
  tool_name    = "#C4A075",  -- tan
  preview      = "#7A6E78",  -- muted (matches fg_dim)
  cost         = "#926A96",  -- plum
}

local function load_pywal_palette()
  local path = vim.fn.expand("~/.cache/wal/colors")
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  local hex = {}
  for _, line in ipairs(lines) do
    local h = line:match("(#%x%x%x%x%x%x)")
    if h then table.insert(hex, h) end
  end
  if #hex < 8 then return nil end
  -- wal slots: 1 maroon, 2 coral, 3 peach, 4 tan, 5 royal, 6 plum, 8 dim
  return {
    user_hdr   = hex[6] or FALLBACK_PALETTE.user_hdr,    -- royal
    jenova_hdr = hex[2] or FALLBACK_PALETTE.jenova_hdr,  -- maroon
    ok         = hex[7] or FALLBACK_PALETTE.ok,          -- plum
    fail       = hex[3] or FALLBACK_PALETTE.fail,        -- coral
    tool_name  = hex[5] or FALLBACK_PALETTE.tool_name,   -- tan
    preview    = hex[9] or FALLBACK_PALETTE.preview,     -- dim
    cost       = hex[7] or FALLBACK_PALETTE.cost,
  }
end

local PALETTE = load_pywal_palette() or FALLBACK_PALETTE

local function setup_chat_hl_groups()
  local function def(name, fg, opts)
    opts = opts or {}
    opts.fg = fg
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  def("JenovaChatUserHdr",     PALETTE.user_hdr,   { bold = true })
  def("JenovaChatJenovaHdr",   PALETTE.jenova_hdr, { bold = true })
  def("JenovaChatToolOk",      PALETTE.ok,         { bold = true })
  def("JenovaChatToolFail",    PALETTE.fail,       { bold = true })
  def("JenovaChatToolName",    PALETTE.tool_name)
  def("JenovaChatToolPreview", PALETTE.preview,    { italic = true })
  def("JenovaChatError",       PALETTE.fail,       { bold = true })
  def("JenovaChatCost",        PALETTE.cost,       { italic = true })
end

local function apply_chat_highlights(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  setup_chat_hl_groups()
  vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local in_fence = false       -- inside a ``` markdown code fence
  local in_preview = false     -- inside a tool-output preview block (after ✓/✗)
  for i, line in ipairs(lines) do
    local lnum = i - 1

    -- Track ``` fences first; never colourise code-block content (let markdown
    -- syntax own those lines, otherwise our extmark would override the
    -- language highlighting and bleach keywords/strings into grey).
    if line:match("^%s*```") then
      in_fence = not in_fence
      in_preview = false
      goto continue
    end
    if in_fence then goto continue end

    if line:match("^## user%s*$") then
      in_preview = false
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #line, hl_group = "JenovaChatUserHdr" })
    elseif line:match("^## jenova%s*$") or line:match("^## assistant%s*$") then
      in_preview = false
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #line, hl_group = "JenovaChatJenovaHdr" })
    elseif line:match("^✓ ") then
      in_preview = true
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #"✓", hl_group = "JenovaChatToolOk" })
      local _, te = line:find("^✓ [%w_-]+")
      if te then
        pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, #"✓ ",
          { end_col = te, hl_group = "JenovaChatToolName" })
      end
    elseif line:match("^✗ ") then
      in_preview = true
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #"✗", hl_group = "JenovaChatToolFail" })
      local _, te = line:find("^✗ [%w_-]+")
      if te then
        pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, #"✗ ",
          { end_col = te, hl_group = "JenovaChatToolName" })
      end
    elseif line:match("^> turn ") then
      in_preview = false
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #line, hl_group = "JenovaChatCost" })
    elseif in_preview and line:match("^  ") then
      -- Only paint indented lines as preview when they actually belong to a
      -- recent ✓/✗ block. This stops us from greying out indented content
      -- inside the model's prose (lists, nested markdown, etc.).
      pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, lnum, 0,
        { end_col = #line, hl_group = "JenovaChatToolPreview" })
    elseif vim.trim(line) == "" then
      -- blank line keeps preview state (preview blocks may include blanks)
    else
      in_preview = false
    end
    ::continue::
  end
end

-- ── Error sanitization ───────────────────────────────────────────────────────
-- Strip Lua source-prefix and stack-traceback noise from raw pcall errors
-- so the chat shows a single readable line instead of a traceback dump.
local function clean_err(s)
  s = tostring(s or "")
  s = s:gsub("^%s*[^\n]+%.lua:%d+:%s*", "")
  s = s:gsub("\nstack traceback:.*$", "")
  local first = s:match("^[^\n]+") or s
  if #first > 240 then first = first:sub(1, 237) .. "..." end
  return first
end

-- ── Utilities ─────────────────────────────────────────────────────────────────

local function ensure_chat_dir()
  if vim.fn.isdirectory(CHAT_DIR) == 0 then
    vim.fn.mkdir(CHAT_DIR, "p")
  end
end

local function chat_filepath(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and (name:find(CHAT_DIR, 1, true) or name:find(WORKSPACE_ROOT, 1, true)) then
    return name
  end
  return nil
end

local function new_chat_filename()
  ensure_chat_dir()
  local pid = vim.fn.getpid()
  return CHAT_DIR .. "/Chat_" .. os.date("%Y%m%d_%H%M%S") .. ".md"
end

local function is_chat_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:find(WORKSPACE_ROOT, 1, true) ~= nil and name:match("%.md$") ~= nil
end

-- Languages we want stock vim-markdown fence-syntax injection for as a fallback
-- when treesitter is unavailable. Treesitter's markdown injections handle a far
-- wider set automatically.
local FENCED_LANGUAGES = {
  "bash=sh", "zsh=sh", "fish=sh",
  "c", "cpp", "rust", "go", "zig",
  "python", "py=python",
  "lua",
  "json", "yaml", "yml=yaml", "toml",
  "html", "css", "scss",
  "javascript", "js=javascript", "typescript", "ts=typescript",
  "make", "makefile=make", "cmake", "dockerfile",
  "sql", "diff", "git=diff",
}

local function ensure_fenced_languages()
  -- Merge instead of clobber so the user's own markdown config keeps working.
  local existing = vim.g.markdown_fenced_languages or {}
  local seen = {}
  for _, v in ipairs(existing) do seen[v] = true end
  for _, v in ipairs(FENCED_LANGUAGES) do
    if not seen[v] then table.insert(existing, v) end
  end
  vim.g.markdown_fenced_languages = existing
end

local function set_chat_buf_options(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = ""
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = true

  ensure_fenced_languages()

  -- Treesitter gives us proper syntax for fenced code blocks via injection
  -- queries when the markdown parser is installed. Wrapped in pcall because
  -- the parser may not yet be loaded (lazy plugin) at first chat open — in
  -- that case we silently fall back to vim's stock markdown syntax which
  -- honours markdown_fenced_languages.
  pcall(function()
    if vim.treesitter and vim.treesitter.language and vim.treesitter.language.add then
      local ok = pcall(vim.treesitter.language.add, "markdown")
      if ok then vim.treesitter.start(buf, "markdown") end
    end
  end)

  apply_chat_highlights(buf)
end

local function mode_tag()
  return agent_mode and "[agent]" or "[chat]"
end

-- ── Header / parsing ──────────────────────────────────────────────────────────

local function build_header(topic)
  topic = topic or "Jenova Chat"
  return string.format(
    "# topic: %s  %s\n- model: %s\n- temperature: %s\n- top_p: %s\n",
    topic, mode_tag(), MODEL, TEMPERATURE, TOP_P
  )
end

-- Update the header line of an existing chat buffer to reflect the current mode.
local function refresh_header_mode(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  -- Replace or append the mode tag
  local updated = first:gsub("%[agent%]", ""):gsub("%[chat%]", "")
  updated = vim.trim(updated) .. "  " .. mode_tag()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { updated })
end

local function init_chat_buffer(buf, topic)
  local header = build_header(topic)
  local init_lines = vim.split(header .. "---\n\n## user\n\n", "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)
  set_chat_buf_options(buf)
end

local function parse_messages(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local messages = {}
  local found_header_end = false
  local current_role = nil
  local current_content = {}

  local function flush()
    if current_role then
      local content = vim.trim(table.concat(current_content, "\n"))
      if content ~= "" then
        table.insert(messages, { role = current_role, content = content })
      end
    end
  end

  for i, line in ipairs(lines) do
    if not found_header_end then
      if line:match("^%-%-%-") and i > 1 then
        found_header_end = true
      end
    else
      if line:match("^## user%s*$") then
        flush()
        current_role = "user"
        current_content = {}
      elseif line:match("^## assistant%s*$") or line:match("^## jenova%s*$") then
        flush()
        current_role = "assistant"
        current_content = {}
      elseif current_role then
        table.insert(current_content, line)
      end
    end
  end

  flush()
  return messages
end

-- ── File I/O ──────────────────────────────────────────────────────────────────

local function save_chat(buf)
  if not is_chat_buf(buf) then return end
  local path = chat_filepath(buf)
  if not path then return end

  -- Resolve the relative path within the Workspace for the Proxy API.
  -- e.g., /home/user/Workspaces/default/Chats/foo.md -> default/Chats/foo.md
  local rel_path = path:sub(#WORKSPACE_ROOT + 2)
  if rel_path == "" then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local url = ep().storage_url(rel_path)

  -- Use vim.system (async) to POST to the Proxy. This ensures the UI doesn't hang
  -- and the Proxy can trigger RAG re-indexing.
  vim.system({ "curl", "-s", "-X", "POST", "--data-binary", "@-", url }, {
    stdin = content,
    detach = true,
  }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        vim.notify("Failed to save chat to Proxy: " .. (obj.stderr or "Unknown error"), vim.log.levels.ERROR, { title = "Jenova" })
      end)
    else
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
        end
      end)
    end
  end)
end

-- ── Scroll ────────────────────────────────────────────────────────────────────

local function scroll_to_bottom(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
  end
end

-- ── Window management ─────────────────────────────────────────────────────────

local function open_chat_split(path)
  -- Pin the source buffer NOW, before vsplit shifts the current window.
  -- This is the file the user is actually working on; the agent context
  -- functions will use it to inject the full file content.
  do
    local src = vim.api.nvim_get_current_buf()
    local src_name = vim.api.nvim_buf_get_name(src)
    if src_name ~= ""
      and vim.bo[src].buftype == ""
      and not src_name:match("/jenova/chats/")
    then
      local ok, ctx = pcall(require, "jenova.agent.context")
      if ok then ctx.set_workspace_buf(src) end
    end
  end
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, CHAT_WIDTH)

  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    local new_path = path or new_chat_filename()
    vim.cmd("edit " .. vim.fn.fnameescape(new_path))
    local buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_line_count(buf) <= 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      init_chat_buffer(buf)
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  set_chat_buf_options(buf)

  if not vim.b[buf]._jenova_chat_autocmd then
    local group = vim.api.nvim_create_augroup("JenovaChatAutoSave_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        if vim.bo[buf].modified then
          save_chat(buf)
        end
        apply_chat_highlights(buf)
      end,
    })
    -- Kill any in-flight agent when the buffer is wiped, so it doesn't keep
    -- running silently in the background writing files and making API calls.
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = group,
      buffer = buf,
      callback = function() stop_generation() end,
    })
    vim.b[buf]._jenova_chat_autocmd = true
  end

  scroll_to_bottom(buf)

  toggle_buf = buf
  toggle_win = win
  return buf, win
end

-- ── Generation control ────────────────────────────────────────────────────────

stop_generation = function()
  if active_job then
    active_job:kill(9)
    active_job = nil
  end
  -- Also signal the agent to abort.
  local ok, agent = pcall(require, "jenova.agent")
  if ok and agent then
    pcall(agent.stop)
  end
end

-- ── Buffer helpers ────────────────────────────────────────────────────────────

local function append_user_section(buf, msg_text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = lines[#lines] or ""

  local new_lines = {}
  local needs_user_header = true
  for i = #lines, math.max(1, #lines - 5), -1 do
    if lines[i] and lines[i]:match("^## user%s*$") then
      local has_content = false
      for j = i + 1, #lines do
        if vim.trim(lines[j]) ~= "" then
          has_content = true
          break
        end
      end
      if not has_content then
        needs_user_header = false
      end
      break
    end
  end

  if needs_user_header then
    if vim.trim(last) ~= "" then
      table.insert(new_lines, "")
    end
    table.insert(new_lines, "## user")
    table.insert(new_lines, "")
  end

  for _, l in ipairs(vim.split(msg_text, "\n", { plain = true })) do
    table.insert(new_lines, l)
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
end

-- ── Agent response (agent mode) ───────────────────────────────────────────────

-- Spinner frames for the thinking indicator
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function agent_respond(buf, prompt, on_done, history)
  local ok, agent = pcall(require, "jenova.agent")
  if not ok or not agent then
    vim.notify(
      "Embedded agent not available — run: make sync-modules && make install",
      vim.log.levels.WARN, { title = "Jenova" })
    return false
  end

  -- ── State ───────────────────────────────────────────────────────────────
  -- We render assistant output by maintaining a single mutable "transient"
  -- line at the bottom of the buffer that displays either the spinner or a
  -- ⚙ tool badge. Permanent content (assistant text, completed ✓/✗ tool
  -- badges, error rows) is committed ABOVE the transient line. Treating the
  -- transient row as a single in-place slot prevents the mid-stream tearing
  -- and stale "thinking…" lines that the previous renderer left behind.

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## jenova", "" })
  apply_chat_highlights(buf)

  local transient_lnum = nil   -- 1-based row of the live spinner/badge, or nil
  local stream_lines   = nil   -- accumulator for the current text run
  local stream_start   = nil   -- 1-based row where the current stream begins
  local active_tool    = nil   -- { name = ..., lnum = ... } when a tool is running
  local spinner_idx    = 0
  local spinner_timer  = nil

  local function buf_append(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    apply_chat_highlights(buf)
  end

  local function clear_transient()
    if not transient_lnum then return end
    if not vim.api.nvim_buf_is_valid(buf) then transient_lnum = nil; return end
    pcall(vim.api.nvim_buf_set_lines, buf,
      transient_lnum - 1, transient_lnum, false, {})
    transient_lnum = nil
  end

  local function commit_stream()
    -- Stream rows are already in the buffer (text was written in place);
    -- just drop the accumulator so the next run starts fresh.
    stream_lines = nil
    stream_start = nil
  end

  local function stop_spinner()
    if spinner_timer then
      pcall(function() spinner_timer:stop(); spinner_timer:close() end)
      spinner_timer = nil
    end
  end

  local function spinner_label()
    spinner_idx = (spinner_idx % #SPINNER) + 1
    if active_tool then
      return string.format("%s %s…", SPINNER[spinner_idx], active_tool.name)
    end
    return string.format("%s thinking…", SPINNER[spinner_idx])
  end

  local function ensure_transient()
    if transient_lnum then return end
    buf_append({ spinner_label() })
    transient_lnum = vim.api.nvim_buf_line_count(buf)
  end

  local function start_spinner()
    ensure_transient()
    if spinner_timer then return end
    spinner_timer = (vim.uv or vim.loop).new_timer()
    if not spinner_timer then return end
    spinner_timer:start(0, 100, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buf) then stop_spinner(); return end
      if not transient_lnum then return end
      pcall(vim.api.nvim_buf_set_lines, buf,
        transient_lnum - 1, transient_lnum, false, { spinner_label() })
    end))
  end

  -- Module statusline state
  M._agent_running = true
  M._agent_tool    = nil
  M._agent_turn    = (M._agent_turn or 0) + 1

  start_spinner()

  local function append_text(text)
    if not vim.api.nvim_buf_is_valid(buf) or text == "" then return end
    -- Replace the transient line with a fresh empty stream row before the
    -- first chunk arrives, so streamed text grows in place where the
    -- spinner used to sit.
    if not stream_start then
      if transient_lnum then
        pcall(vim.api.nvim_buf_set_lines, buf,
          transient_lnum - 1, transient_lnum, false, { "" })
        stream_start   = transient_lnum
        transient_lnum = nil
      else
        buf_append({ "" })
        stream_start = vim.api.nvim_buf_line_count(buf)
      end
      stream_lines = { "" }
    end

    if not stream_lines then return end
    local pieces = vim.split(text, "\n", { plain = true })
    stream_lines[#stream_lines] = stream_lines[#stream_lines] .. pieces[1]
    for i = 2, #pieces do table.insert(stream_lines, pieces[i]) end

    pcall(vim.api.nvim_buf_set_lines, buf,
      stream_start - 1,
      stream_start - 1 + #stream_lines,
      false, stream_lines)
    scroll_to_bottom(buf)
  end

  agent.query(prompt, {
    on_text = function(text)
      vim.schedule(function() append_text(text) end)
    end,

    on_thinking = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        active_tool = nil
        M._agent_tool = nil
        ensure_transient()
      end)
    end,

    on_compact = function(dropped)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        commit_stream()
        clear_transient()
        buf_append({ string.format(
          "<!-- compacted %d earlier message(s) into session digest -->",
          dropped) })
        ensure_transient()
        scroll_to_bottom(buf)
      end)
    end,

    on_tool_use = function(name, input)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        commit_stream()
        clear_transient()
        active_tool = { name = name, input = input }
        M._agent_tool = name
        -- Append a fresh transient row that the spinner will animate.
        ensure_transient()
        active_tool.lnum = transient_lnum
        scroll_to_bottom(buf)
      end)
    end,

    on_tool_result = function(name, result)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local success = not (type(result) == "table" and result.error)
        local icon    = success and "✓" or "✗"
        local row     = active_tool and active_tool.lnum or transient_lnum
        -- Build a concise badge that includes the operand the user cares
        -- about (file path, glob pattern, command, etc.) so the chat log
        -- shows what actually happened, not just the tool name.
        local input   = active_tool and active_tool.input or nil
        local detail  = ""
        if type(input) == "table" then
          local d = input.file_path or input.path or input.pattern
              or input.command or input.query or input.url
          if type(d) == "string" and #d > 0 then
            detail = " " .. d:sub(1, 200)
          end
        end
        local suffix = ""
        if success and type(result) == "table" then
          if result.num_lines then
            suffix = string.format(" (%d lines)", result.num_lines)
          elseif result.num_files then
            suffix = string.format(" (%d files)", result.num_files)
          end
        elseif not success and type(result) == "table" and result.error then
          suffix = " — " .. tostring(result.error):sub(1, 120)
        end
        if row and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false,
            { string.format("%s %s%s%s", icon, name, detail, suffix) })
        end
        if transient_lnum == row then transient_lnum = nil end
        active_tool = nil
        M._agent_tool = nil
        -- Spinner timer keeps running; ensure_transient appends a new line
        -- below the now-permanent badge.
        ensure_transient()
        scroll_to_bottom(buf)
      end)
    end,

    on_error = function(msg)
      vim.schedule(function()
        stop_spinner()
        commit_stream()
        clear_transient()
        active_tool = nil
        M._agent_running = false
        M._agent_tool    = nil
        if vim.api.nvim_buf_is_valid(buf) then
          buf_append({ "✗ Error: " .. clean_err(msg) })
          buf_append({ "", "## user", "" })
          save_chat(buf)
          scroll_to_bottom(buf)
          vim.cmd("startinsert!")
        end
        if on_done then on_done() end
      end)
    end,

    on_done = function(usage)
      vim.schedule(function()
        stop_spinner()
        commit_stream()
        clear_transient()
        active_tool = nil
        M._agent_running = false
        M._agent_tool    = nil

        if vim.api.nvim_buf_is_valid(buf) then
          if usage and (usage.input or 0) + (usage.output or 0) > 0 then
            M._agent_tokens_in  = usage.input  or 0
            M._agent_tokens_out = usage.output or 0
            M._agent_cost       = usage.cost   or 0.0
            local cost_line
            if usage.cost and usage.cost > 0 then
              cost_line = string.format(
                "> turn %d  in:%d out:%d  $%.4f",
                M._agent_turn, usage.input, usage.output, usage.cost)
            else
              cost_line = string.format(
                "> turn %d  in:%d out:%d",
                M._agent_turn, usage.input, usage.output)
            end
            buf_append({ "", cost_line })
          end
          buf_append({ "", "## user", "" })
          save_chat(buf)
          scroll_to_bottom(buf)
          vim.cmd("startinsert!")
        end
        if on_done then on_done() end
      end)
    end,
  }, buf, history)
  return true
end

-- ── Slash command dispatcher ───────────────────────────────────────────────────

local function dispatch_slash(buf, cmd_line)
  local cmd = (cmd_line:match("^/(%S+)") or ""):lower()
  local arg = (cmd_line:match("^/%S+%s+(.*)") or ""):match("^%s*(.-)%s*$")
  local function info(line)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "<!-- " .. line .. " -->", "" })
    scroll_to_bottom(buf)
  end
  if cmd == "clear" then
    local ok, agent = pcall(require, "jenova.agent")
    if ok and agent then agent.clear() end
    M._agent_turn = 0
    -- Physically wipe the buffer from the header down
    local header_lines = 4
    vim.api.nvim_buf_set_lines(buf, header_lines, -1, false, { "---", "", "## user", "" })
    vim.notify("Session cleared", vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "reset" then

    local ok, agent = pcall(require, "jenova.agent")
    if ok and agent then agent.reset() end
    M._agent_turn = 0
    -- Wipe the buffer so old turns aren't re-injected as history on the next
    -- query.  agent.reset() sets _just_reset as a belt-and-suspenders guard,
    -- but clearing the buffer keeps the visual state consistent too.
    local header_lines = 4
    vim.api.nvim_buf_set_lines(buf, header_lines, -1, false, { "---", "", "## user", "" })
    vim.notify("Agent reset — fresh context on next query",
      vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "stop" then
    M.stop()

  elseif cmd == "history" then
    local ok, agent = pcall(require, "jenova.agent")
    local msgs = ok and agent and agent.get_messages() or {}
    local lines = { "", "<!-- /history -->", string.format("  %d messages in context:", #msgs) }
    for i, m in ipairs(msgs) do
      local snippet = (m.content or ""):sub(1, 80):gsub("\n", " ")
      table.insert(lines, string.format("  [%d] %s: %s%s",
        i, m.role, snippet, #(m.content or "") > 80 and "…" or ""))
    end
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "debug" then
    local ok, agent = pcall(require, "jenova.agent")
    local usage = ok and agent and agent.get_usage() or {}
    local state = {
      running  = M._agent_running,
      turn     = M._agent_turn,
      tool     = M._agent_tool,
      tokens_in  = usage.input_tokens  or 0,
      tokens_out = usage.output_tokens or 0,
      cost     = usage.total_cost_usd  or 0,
    }
    local encoded = vim.json.encode(state)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false,
      { "", "<!-- /debug -->", "```json", encoded, "```", "" })
    scroll_to_bottom(buf)

  elseif cmd == "memory" or cmd == "mem" then
    -- /memory                   — show top facts in scope (workspace + global)
    -- /memory recall <query>    — preview what would be injected for <query>
    -- /memory forget <id>       — delete a fact
    -- /memory clear             — wipe workspace facts (keeps global)
    -- /memory clear all         — wipe everything
    local sub_word, sub_arg = arg:match("^(%S+)%s*(.*)$")
    sub_word = sub_word and sub_word:lower() or ""
    local lines = { "", "<!-- /memory -->" }
    local ok, memory = pcall(require, "jenova.agent.memory")
    if not ok or not memory then
      table.insert(lines, "  (memory module not available)")
    elseif sub_word == "recall" then
      local q = sub_arg or ""
      local facts = memory.recall(q, 10)
      if #facts == 0 then
        table.insert(lines, "  (no facts matched: " .. q .. ")")
      else
        table.insert(lines, string.format("  recall(\"%s\"):", q))
        for _, f in ipairs(facts) do
          table.insert(lines, string.format("    [%s] %s", f.id, f.text))
        end
      end
    elseif sub_word == "forget" then
      local id = sub_arg
      if not id or id == "" then
        table.insert(lines, "  usage: /memory forget <id>")
      elseif memory.forget(id) then
        table.insert(lines, "  forgot " .. id)
      else
        table.insert(lines, "  no fact with id " .. id)
      end
    elseif sub_word == "clear" then
      if sub_arg == "all" then
        memory.clear(false)
        table.insert(lines, "  cleared ALL memory facts (workspace + global)")
      else
        memory.clear(true)
        table.insert(lines, "  cleared workspace memory facts (global preserved)")
      end
    else
      local stats = memory.stats()
      table.insert(lines, string.format(
        "  facts: %d total  (%d workspace, %d global)",
        stats.total, stats.workspace, stats.global))
      table.insert(lines, "  scope: " .. stats.scope)
      local facts = memory.list(15)
      if #facts > 0 then
        table.insert(lines, "")
        table.insert(lines, "  most-recent (top 15):")
        for _, f in ipairs(facts) do
          local snippet = f.text:gsub("\n", " ")
          if #snippet > 100 then snippet = snippet:sub(1, 100) .. "…" end
          table.insert(lines, string.format("    [%s] %s", f.id, snippet))
        end
      end
      table.insert(lines, "")
      table.insert(lines, "  /memory recall <query>  preview prompt injection")
      table.insert(lines, "  /memory forget <id>     delete a fact")
      table.insert(lines, "  /memory clear [all]     wipe workspace [or all]")
    end
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "compact" then
    -- /compact            — force-compact the engine's current message log
    -- /compact status     — show how many messages are currently held
    local sub = arg:lower()
    local lines = { "", "<!-- /compact -->" }
    local ok_a, agent = pcall(require, "jenova.agent")
    local ok_c, compactor = pcall(require, "jenova.agent.compactor")
    if not ok_a or not agent or not agent._engine then
      table.insert(lines, "  (no active engine — issue a query first)")
    elseif sub == "status" then
      local n = #(agent._engine.messages or {})
      table.insert(lines, string.format("  %d messages currently in context", n))
    elseif ok_c and compactor then
      local before = #(agent._engine.messages or {})
      local new_msgs, dropped = compactor.compact(agent._engine.messages, { keep_recent = 4 })
      agent._engine.messages = new_msgs
      table.insert(lines, string.format(
        "  compacted: %d → %d messages (folded %d into a digest)",
        before, #new_msgs, dropped))
    else
      table.insert(lines, "  (compactor unavailable)")
    end
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "learning" or cmd == "learn" then
    -- /learning            — show per-tool aggregate stats from the
    --                        persistent database
    -- /learning session    — show only the current session's calls
    -- /learning reset      — wipe the per-session repetition cache
    local sub = arg:lower()
    local lines = { "", "<!-- /learning -->" }
    local ok, learning = pcall(require, "jenova.agent.learning")
    if not ok or not learning then
      table.insert(lines, "  (learning module not available)")
    elseif sub == "reset" then
      learning.reset_session()
      table.insert(lines, "  session repetition cache cleared")
    elseif sub == "session" then
      local summary = learning.session_summary()
      if #summary == 0 then
        table.insert(lines, "  (no calls in this session yet)")
      else
        table.insert(lines, "  this session:")
        for _, s in ipairs(summary) do
          table.insert(lines, string.format(
            "    %-14s ok:%-3d fail:%-3d (last %d)",
            s.name, s.ok, s.fail, s.recent))
        end
      end
    else
      local stats = learning.stats()
      local names = {}
      for name, _ in pairs(stats or {}) do table.insert(names, name) end
      table.sort(names)
      if #names == 0 then
        table.insert(lines, "  (no recorded tool history)")
      else
        table.insert(lines, "  persistent stats:")
        for _, name in ipairs(names) do
          local s = stats[name]
          local total = (s.success or 0) + (s.failure or 0)
          local rate  = total > 0
            and string.format("%.0f%%", 100 * (s.success or 0) / total)
            or "—"
          local top_err, top_n = nil, 0
          for k, v in pairs(s.errors or {}) do
            if v > top_n then top_err, top_n = k, v end
          end
          local err_part = top_err
            and string.format(" top-err:%s(%d)", top_err, top_n) or ""
          table.insert(lines, string.format(
            "    %-14s ok:%-4d fail:%-4d rate:%s%s",
            name, s.success or 0, s.failure or 0, rate, err_part))
        end
        table.insert(lines, "")
        table.insert(lines, "  /learning session  show calls in this chat")
        table.insert(lines, "  /learning reset    clear repetition cache")
      end
    end
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "diag" then
    local diags = vim.diagnostic.get(nil)
    local lines = { "", "<!-- /diag -->",
      string.format("  %d diagnostics across all buffers:", #diags) }
    local counts = { [1]=0,[2]=0,[3]=0,[4]=0 }
    for _, d in ipairs(diags) do counts[d.severity] = (counts[d.severity] or 0) + 1 end
    table.insert(lines, string.format("  E:%d W:%d I:%d H:%d",
      counts[1], counts[2], counts[3], counts[4]))
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "tools" then
    -- /tools                — list registered tools
    -- /tools on | enable    — re-enable tool dispatch
    -- /tools off | disable  — strip tools, plain chat replies only
    -- /tools status         — show whether tools are currently enabled
    local sub = arg:lower()
    if sub == "on" or sub == "enable" then
      vim.g.jenova_tools_enabled = true
      info("/tools enabled — model can call tools")
      return
    elseif sub == "off" or sub == "disable" then
      vim.g.jenova_tools_enabled = false
      info("/tools disabled — replies will be plain chat (no tools)")
      return
    elseif sub == "status" then
      local enabled = vim.g.jenova_tools_enabled ~= false
      info("/tools status: " .. (enabled and "enabled" or "disabled"))
      return
    end
    local ok, reg = pcall(require, "jenova.agent.registry")
    local lines = { "", "<!-- /tools -->" }
    if ok and reg then
      for _, name in ipairs(reg.list()) do
        local tool = reg.get(name)
        table.insert(lines, string.format("  • %s — %s",
          name, (tool.description or ""):sub(1, 60)))
      end
    else
      table.insert(lines, "  (registry not available)")
    end
    table.insert(lines, "  ──")
    table.insert(lines, "  /tools on|off    toggle tool dispatch")
    table.insert(lines, "  /tools status    show current state")
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "permissions" or cmd == "perm" then
    -- /permissions [default|auto|plan|yolo]
    local sub = arg:lower()
    local mode_map = {
      default = "default",
      ask     = "default",
      auto    = "auto",
      plan    = "plan",
      yolo    = "bypass",
      bypass  = "bypass",
    }
    if sub == "" then
      local mode = vim.g.jenova_permission_mode or "default"
      info("permission mode: " .. mode .. "  (use /permissions default|auto|plan|yolo)")
      return
    end
    local mode = mode_map[sub]
    if not mode then
      info("unknown mode '" .. sub .. "' (try: default, auto, plan, yolo)")
      return
    end
    vim.g.jenova_permission_mode = mode
    info("permission mode → " .. mode)

  elseif cmd == "tool-choice" or cmd == "toolchoice" then
    -- /tool-choice [auto|required|none]
    local sub = arg:lower()
    if sub == "" then
      local choice = vim.g.jenova_tool_choice or "auto"
      info("tool_choice: " .. choice .. "  (use /tool-choice auto|required)")
      return
    end
    if sub ~= "auto" and sub ~= "required" and sub ~= "none" then
      info("invalid tool_choice (use: auto, required, none)")
      return
    end
    vim.g.jenova_tool_choice = sub
    info("tool_choice → " .. sub)

  elseif cmd == "model" then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false,
      { "", string.format("<!-- /model: %s -->", MODEL), "" })
    scroll_to_bottom(buf)

  elseif cmd == "thinking" then
    vim.notify("Thinking mode toggle not yet supported for this model",
      vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "help" then
    local lines = {
      "",
      "<!-- /help -->",
      "  /clear              clear session history (keep engine)",
      "  /reset              destroy engine, rebuild on next query",
      "  /stop               abort in-flight generation",
      "  /history            show message context summary",
      "  /debug              show engine state as JSON",
      "  /diag               show LSP diagnostics summary",
      "  /learning [session] tool-usage stats; 'reset' clears repetition cache",
      "  /memory [recall|forget|clear]  semantic memory inspect / manage",
      "  /compact [status]   force-compact the engine's message history",
      "  /tools [on|off]     list / toggle tool dispatch",
      "  /tool-choice MODE   auto | required | none",
      "  /permissions MODE   default | auto | plan | yolo",
      "  /model              show current model",
      "  /thinking           toggle extended thinking (if supported)",
      "  /help               this reference",
      "",
    }
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  else
    vim.notify("Unknown slash command: /" .. cmd .. "  (try /help)",
      vim.log.levels.WARN, { title = "Jenova" })
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open_chat(path)
  return open_chat_split(path)
end

function M.toggle_chat()
  if toggle_win and vim.api.nvim_win_is_valid(toggle_win) then
    vim.api.nvim_win_close(toggle_win, true)
    toggle_win = nil
    return
  end

  if toggle_buf and vim.api.nvim_buf_is_valid(toggle_buf) and is_chat_buf(toggle_buf) then
    local path = chat_filepath(toggle_buf)
    if path then
      return open_chat_split(path)
    end
  end

  local latest = nil
  local latest_time = 0
  ensure_chat_dir()
  local files = vim.fn.glob(CHAT_DIR .. "/*.md", false, true)
  for _, fpath in ipairs(files) do
    local mtime = vim.fn.getftime(fpath)
    if mtime > latest_time then
      latest_time = mtime
      latest = fpath
    end
  end

  if latest then
    return open_chat_split(latest)
  else
    return open_chat_split()
  end
end

-- Toggle between agent mode and plain conversation mode.
function M.toggle_mode()
  agent_mode = not agent_mode
  vim.g.jenova_tools_enabled = agent_mode
  local label = agent_mode and "Agent mode (tools + context)" or "Conversation mode (plain stream)"
  vim.notify(label, vim.log.levels.INFO, { title = "Jenova" })

  -- Update header in all open chat buffers.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_chat_buf(buf) then
      refresh_header_mode(buf)
      save_chat(buf)
    end
  end
end

function M.respond()
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova" })
    return
  end

  local messages = parse_messages(buf)
  if #messages == 0 then
    vim.notify("No messages to send", vim.log.levels.WARN, { title = "Jenova" })
    return
  end

  -- Extract last user message
  local prompt = ""
  local history = {}
  for i, m in ipairs(messages) do
    if i == #messages and m.role == "user" then
      prompt = m.content
    else
      table.insert(history, m)
    end
  end

  -- Multi-line continuation: if prompt ends with backslash, wait for more input
  if prompt:match("\\%s*$") then
    vim.notify("Multi-line: remove trailing \\ and send again to submit",
      vim.log.levels.INFO, { title = "Jenova" })
    return
  end

  -- Slash command dispatch
  if prompt:match("^/") then
    dispatch_slash(buf, prompt)
    -- Instead of risky line deletion, just append a fresh user header
    -- to signal the end of the command processing and readiness for new input.
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## user", "" })
    save_chat(buf)
    scroll_to_bottom(buf)
    vim.cmd("startinsert!")
    return
  end

  agent_respond(buf, prompt, nil, history)
end

function M.send_message(text, prefix)
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    local chat_buf = M.toggle_chat()
    if not chat_buf then return end
    buf = chat_buf --[[@as integer]]
  end

  local msg = prefix and (prefix .. text) or text
  append_user_section(buf, msg)
  save_chat(buf)
  scroll_to_bottom(buf)
end

function M.visual_chat()
  local src_buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local path = vim.api.nvim_buf_get_name(src_buf)
  local rel = vim.fn.fnamemodify(path, ":~:.")

  local buf = open_chat_split()
  if not buf then return end

  -- Use metadata. context.lua will extract this range for the prompt.
  local context = string.format("## Active Selection: %s (lines %d-%d)\n\n", rel, start_line, end_line)

  append_user_section(buf, context)
  save_chat(buf)
  scroll_to_bottom(buf)
  vim.cmd("startinsert!")
end

local function strip_code_fences(text)
  local stripped = text
  stripped = stripped:gsub("^%s*", "")
  if stripped:match("^```") then
    stripped = stripped:gsub("^```[^\n]*\n", "")
    stripped = stripped:gsub("\n?```%s*$", "")
  end
  return stripped
end

local function do_rewrite(src_buf, start_ln, end_ln, instruction, selection, ft)
  if vim.fn.executable("curl") ~= 1 then
    vim.notify("curl not found. Install curl to enable rewrite.", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  local user_msg = string.format(
    "Visual Rewrite: %s\n\nI have the following selection:\n```%s\n%s\n```",
    instruction, ft, selection
  )

  local messages = {
    { role = "user", content = user_msg },
  }

  local url = ep().proxy_url()
  local payload = vim.json.encode({
    model = MODEL,
    messages = messages,
    temperature = TEMPERATURE,
    top_p = TOP_P,
    stream = true,
    max_tokens = 16384,
  })

  local tmpfile = vim.fn.tempname() .. ".json"
  if vim.fn.writefile({ payload }, tmpfile) ~= 0 then
    vim.notify("Failed to create temp file", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  local response_text = ""
  local sse_buf = ""

  vim.notify("Rewriting...", vim.log.levels.INFO, { title = "Jenova" })

  active_job = vim.system(
    {
      "curl", "--no-buffer", "-s", "-N",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " .. SECRET,
      "-d", "@" .. tmpfile,
      url,
    },
    {
      stdout = function(_, data)
        if not data then return end
        data = type(data) == "string" and data or tostring(data)
        sse_buf = sse_buf .. data
        while true do
          local nl = sse_buf:find("\n")
          if not nl then break end
          local line = sse_buf:sub(1, nl - 1):gsub("\r$", "")
          sse_buf = sse_buf:sub(nl + 1)
          if line:sub(1, 6) == "data: " and line ~= "data: [DONE]" then
            local ok, parsed = pcall(vim.json.decode, line:sub(7))
            if ok and parsed and parsed.choices and parsed.choices[1] then
              local delta = parsed.choices[1].delta
              if delta and type(delta.content) == "string" then
                response_text = response_text .. delta.content
              end
            end
          end
        end
      end,
    },
    function(result)
      vim.schedule(function()
        active_job = nil
        pcall(os.remove, tmpfile)
        if vim.api.nvim_buf_is_valid(src_buf) and response_text ~= "" then
          local cleaned = strip_code_fences(response_text)
          local new_lines = vim.split(cleaned, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(src_buf, start_ln - 1, end_ln, false, new_lines)
          vim.notify("Rewrite applied", vim.log.levels.INFO, { title = "Jenova" })
        elseif response_text == "" then
          if result.code ~= 0 then
            vim.notify("Rewrite failed: connection error (is the backend running?)",
              vim.log.levels.ERROR, { title = "Jenova" })
          else
            vim.notify("Rewrite failed: empty response from backend",
              vim.log.levels.ERROR, { title = "Jenova" })
          end
        end
      end)
    end
  )
end

function M.visual_rewrite()
  local src_buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local lines = vim.api.nvim_buf_get_lines(src_buf, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local ft = vim.bo[src_buf].filetype or ""

  vim.ui.input({ prompt = "Rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end
    do_rewrite(src_buf, start_line, end_line, instruction, selection, ft)
  end)
end

function M.web_search()
  vim.ui.input({ prompt = "Web search: " }, function(query)
    if not query or query == "" then return end

    local buf = open_chat_split()
    if not buf then return end

    local msg = "Web Search: " .. query
    append_user_section(buf, msg)
    save_chat(buf)
    scroll_to_bottom(buf)
    vim.cmd("startinsert!")
  end)
end

function M.chat_with_context()
  local src_buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(src_buf)
  local rel = vim.fn.fnamemodify(path, ":~:.")

  local buf = open_chat_split()
  if not buf then return end

  -- Hardware the context as metadata. The context builder (context.lua)
  -- will detect this tag and pull the buffer into the system prompt.
  local context = string.format("## Active Context: %s\n\n", rel)

  append_user_section(buf, context)
  save_chat(buf)
  scroll_to_bottom(buf)
  vim.cmd("startinsert!")
end

function M.fresh_chat()
  stop_generation()
  vim.fn.delete(CHAT_DIR, "rf")
  vim.fn.mkdir(CHAT_DIR, "p")
  return open_chat_split()
end

function M.delete_chat()
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova" })
    return
  end
  stop_generation()
  local path = chat_filepath(buf)
  if path then
    os.remove(path)
  end
  if toggle_buf == buf then
    toggle_buf = nil
    toggle_win = nil
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.notify("Chat deleted", vim.log.levels.INFO, { title = "Jenova" })
end

function M.inline_rewrite()
  local src_buf = vim.api.nvim_get_current_buf()
  local lnum = vim.fn.line(".")
  local line = vim.api.nvim_get_current_line()
  local ft = vim.bo[src_buf].filetype or ""

  vim.ui.input({ prompt = "Inline rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end
    do_rewrite(src_buf, lnum, lnum, instruction, line, ft)
  end)
end

function M.stop()
  stop_generation()
  vim.notify("Generation stopped", vim.log.levels.INFO, { title = "Jenova" })
end

function M.agent_reset()
  local ok, agent = pcall(require, "jenova.agent")
  if ok and agent then
    agent.reset()
    M._agent_turn = 0
    -- Wipe the active chat buffer so old turns aren't re-injected as history.
    local buf = vim.api.nvim_get_current_buf()
    if is_chat_buf(buf) then
      local header_lines = 4
      vim.api.nvim_buf_set_lines(buf, header_lines, -1, false, { "---", "", "## user", "" })
    end
    vim.notify("Agent reset — fresh context on next query", vim.log.levels.INFO, { title = "Jenova" })
  end
end

local _setup_done = false

function M.setup()
  if _setup_done then return end
  _setup_done = true

  -- Architectural mandate: All chat persistence must flow through the Proxy (8080)
  -- to ensure structural unification and automated RAG re-indexing.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = WORKSPACE_ROOT .. "/**/*.md",
    callback = function(ev)
      if is_chat_buf(ev.buf) then
        save_chat(ev.buf)
      else
        -- Fallback for non-chat markdown in Workspaces (if any)
        vim.api.nvim_buf_call(ev.buf, function()
          vim.cmd("silent! write! " .. vim.fn.fnameescape(ev.file))
        end)
      end
    end,
  })

  vim.api.nvim_create_user_command("JenovaChat",        function() M.toggle_chat() end,   { desc = "Toggle Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatNew",     function() M.open_chat() end,     { desc = "New Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatRespond", function() M.respond() end,       { desc = "Send chat message" })
  vim.api.nvim_create_user_command("JenovaChatDelete",  function() M.delete_chat() end,   { desc = "Delete current chat" })
  vim.api.nvim_create_user_command("JenovaChatFresh",   function() M.fresh_chat() end,    { desc = "Fresh chat (wipe all)" })
  vim.api.nvim_create_user_command("JenovaChatStop",    function() M.stop() end,          { desc = "Stop generation" })
  vim.api.nvim_create_user_command("JenovaWebSearch",   function() M.web_search() end,    { desc = "Web search" })
  vim.api.nvim_create_user_command("JenovaChatContext", function() M.chat_with_context() end, { desc = "Chat with file context" })
  vim.api.nvim_create_user_command("JenovaToggleMode",  function() M.toggle_mode() end,   { desc = "Toggle agent/conversation mode" })
  vim.api.nvim_create_user_command("JenovaAgentReset",  function() M.agent_reset() end,   { desc = "Reset agent context" })

  local function opts(desc)
    return { noremap = true, silent = true, nowait = true, desc = "Jenova: " .. desc }
  end

  vim.keymap.set("v", "<leader>ae", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    M.visual_chat()
  end, opts("Visual Chat"))

  vim.keymap.set("n", "<leader>ac", function() M.chat_with_context() end, opts("Chat with Buffer Context"))
  vim.keymap.set("n", "<leader>aF", function() M.fresh_chat() end, opts("New Chat (Fresh Context)"))
  vim.keymap.set("n", "<leader>at", function() M.toggle_chat() end, opts("Toggle Chat"))
  vim.keymap.set("n", "<leader>ar", function() M.respond() end, opts("Chat Respond"))
  vim.keymap.set("n", "<leader>ad", function() M.delete_chat() end, opts("Delete Chat"))
  vim.keymap.set("n", "<leader>an", function() M.open_chat() end, opts("New Chat"))
  vim.keymap.set("n", "<leader>am", function() M.toggle_mode() end, opts("Toggle Agent/Conversation Mode"))
  vim.keymap.set("n", "<leader>aR", function() M.agent_reset() end, opts("Reset Agent Context"))

  vim.keymap.set("v", "<leader>aw", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    M.visual_rewrite()
  end, opts("Visual Rewrite"))

  vim.keymap.set("n", "<leader>as", function() M.web_search() end, opts("Web Search"))
  vim.keymap.set("n", "<leader>ai", function() M.inline_rewrite() end, opts("Inline Rewrite"))
  vim.keymap.set("n", "<leader>ax", function() M.stop() end, opts("Stop Generation"))

  vim.keymap.set("n", "<leader>aa", function() M.toggle_chat() end, opts("Open / focus chat"))

  vim.keymap.set("n", "<leader>af", function()
    local src_buf = vim.api.nvim_get_current_buf()
    local diags = vim.diagnostic.get(src_buf)
    if #diags == 0 then
      vim.notify("No diagnostics in current buffer", vim.log.levels.INFO, { title = "Jenova" })
      return
    end
    local lines = {}
    for _, d in ipairs(diags) do
      table.insert(lines, string.format("  line %d: [%s] %s",
        d.lnum + 1,
        vim.diagnostic.severity[d.severity] or "?",
        d.message))
    end
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src_buf), ":t")
    local prompt = string.format(
      "Fix all LSP diagnostics in `%s`:\n%s\n\nApply fixes directly.",
      fname, table.concat(lines, "\n"))
    local cbuf = M.toggle_chat()
    if cbuf then
      append_user_section(cbuf, prompt)
      save_chat(cbuf)
      scroll_to_bottom(cbuf)
      M.respond()
    end
  end, opts("Fix diagnostics in current buffer"))
end

return M
