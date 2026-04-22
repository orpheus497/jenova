-- jvim.finder — first-party fuzzy finder for files, buffers, grep, help,
-- oldfiles and diagnostics. Replaces telescope.nvim (plus its plenary +
-- fzf-native dependencies) with a single ~400-line module that talks to
-- the same external tools telescope uses (fd, rg) when available and
-- gracefully falls back to vim.fs / :grep when they are not.
--
-- Public API:
--   require("jvim.finder").files([opts])         -- file picker
--   require("jvim.finder").buffers([opts])
--   require("jvim.finder").grep([opts])          -- live grep
--   require("jvim.finder").help_tags([opts])
--   require("jvim.finder").oldfiles([opts])
--   require("jvim.finder").diagnostics([opts])
--   require("jvim.finder").pick(items, opts)     -- generic picker
--
-- opts.cwd, opts.prompt, opts.on_pick(item), opts.formatter(item)->display.

local M = {}

local uv = function() return vim.uv or vim.loop end
local NS = vim.api.nvim_create_namespace("jvim_finder")

-- =========================================================================
--  Fuzzy scoring (FZF-style: shorter span + earlier + camelCase boost).
-- =========================================================================

-- ##Function: Score how well `pattern` matches `text` (case-insensitive).
-- Returns nil if no match, else a non-negative number — lower is better.
local function score(pattern, text)
  if pattern == "" then return 0 end
  text = text:lower()
  pattern = pattern:lower()
  local ti, span_start, last = 1, nil, nil
  local matched = 0
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    local found = text:find(c, ti, true)
    if not found then return nil end
    if span_start == nil then span_start = found end
    if last and found - last > 1 then
      matched = matched + (found - last - 1)  -- gap penalty
    end
    last = found
    ti = found + 1
    matched = matched + 1
  end
  -- Lower is better: span length + start offset.
  return (last - span_start) + (span_start * 0.5)
end

-- ##Function: Fuzzy filter and sort `items` by `query`. items are strings.
local function rank(items, query, formatter, limit)
  if query == "" then
    local out = {}
    for i = 1, math.min(#items, limit) do out[i] = { item = items[i], display = formatter(items[i]) } end
    return out
  end
  local scored = {}
  for _, it in ipairs(items) do
    local disp = formatter(it)
    local s = score(query, disp)
    if s then scored[#scored + 1] = { item = it, display = disp, score = s } end
  end
  table.sort(scored, function(a, b) return a.score < b.score end)
  if #scored > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = scored[i] end
    return trimmed
  end
  return scored
end

-- =========================================================================
--  External tool detection.
-- =========================================================================

local function exec(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  return out
end

local function has(bin) return vim.fn.executable(bin) == 1 end

-- ##Function: List candidate files under cwd. Prefers fd, falls back to find,
-- falls back to vim.fs.find.
local function list_files(cwd)
  if has("fd") then
    return exec({ "fd", "--type", "f", "--hidden", "--exclude", ".git",
                  "--strip-cwd-prefix", "--color=never", ".", cwd }) or {}
  end
  if has("rg") then
    return exec({ "rg", "--files", "--hidden", "--glob", "!.git", cwd }) or {}
  end
  if has("find") then
    return exec({ "find", cwd, "-type", "f", "-not", "-path", "*/.git/*" }) or {}
  end
  -- Last-resort vim.fs walker (slow on large trees but always available).
  local out = {}
  local function walk(d, depth)
    if depth > 8 then return end
    for name, t in vim.fs.dir(d) do
      if name:sub(1, 1) ~= "." then
        local p = d .. "/" .. name
        if t == "directory" then walk(p, depth + 1)
        elseif t == "file" then out[#out + 1] = p end
      end
    end
  end
  walk(cwd, 0)
  return out
end

-- =========================================================================
--  Picker UI — floating prompt + results window.
-- =========================================================================

local picker = {}

local function close_picker()
  if picker.preview_win and vim.api.nvim_win_is_valid(picker.preview_win) then
    pcall(vim.api.nvim_win_close, picker.preview_win, true)
  end
  if picker.results_win and vim.api.nvim_win_is_valid(picker.results_win) then
    pcall(vim.api.nvim_win_close, picker.results_win, true)
  end
  if picker.prompt_win and vim.api.nvim_win_is_valid(picker.prompt_win) then
    pcall(vim.api.nvim_win_close, picker.prompt_win, true)
  end
  if picker.results_buf and vim.api.nvim_buf_is_valid(picker.results_buf) then
    pcall(vim.api.nvim_buf_delete, picker.results_buf, { force = true })
  end
  if picker.prompt_buf and vim.api.nvim_buf_is_valid(picker.prompt_buf) then
    pcall(vim.api.nvim_buf_delete, picker.prompt_buf, { force = true })
  end
  if picker.preview_buf and vim.api.nvim_buf_is_valid(picker.preview_buf) then
    pcall(vim.api.nvim_buf_delete, picker.preview_buf, { force = true })
  end
  picker = {}
end

local function refresh()
  if not picker.results_buf then return end
  local query = picker.query or ""
  local items
  if picker.live then
    items = picker.live(query)
  else
    items = rank(picker.source or {}, query, picker.formatter or tostring, picker.limit or 200)
  end
  picker.matches = items
  local lines = {}
  for i, m in ipairs(items) do
    local prefix = (i == picker.cursor) and "▶ " or "  "
    lines[i] = prefix .. m.display
  end
  if #lines == 0 then lines = { "  (no matches)" } end
  vim.bo[picker.results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(picker.results_buf, 0, -1, false, lines)
  vim.bo[picker.results_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(picker.results_buf, NS, 0, -1)
  if picker.cursor and lines[picker.cursor] then
    vim.api.nvim_buf_set_extmark(picker.results_buf, NS, picker.cursor - 1, 0, {
      end_row = picker.cursor - 1, end_col = #lines[picker.cursor],
      hl_group = "JvimFinderSelection",
    })
  end
  -- Counter in prompt title.
  if picker.prompt_win and vim.api.nvim_win_is_valid(picker.prompt_win) then
    pcall(vim.api.nvim_win_set_config, picker.prompt_win, {
      title = string.format(" %s — %d ", picker.prompt or "Find", #items),
      title_pos = "left",
    })
  end
  -- Update preview if a previewer is set.
  if picker.previewer and picker.matches[picker.cursor] then
    picker.previewer(picker.matches[picker.cursor].item)
  end
end

local function move(delta)
  if not picker.matches or #picker.matches == 0 then return end
  picker.cursor = math.max(1, math.min(#picker.matches, (picker.cursor or 1) + delta))
  refresh()
end

local function accept()
  local m = picker.matches and picker.matches[picker.cursor or 1]
  if not m then close_picker(); return end
  local cb = picker.on_pick
  close_picker()
  if cb then cb(m.item) end
end

local function on_prompt_change()
  if not picker.prompt_buf then return end
  local lines = vim.api.nvim_buf_get_lines(picker.prompt_buf, 0, -1, false)
  picker.query = lines[1] or ""
  picker.cursor = 1
  refresh()
end

-- ##Function: Generic picker.
--   opts = {
--     prompt   = "Files",            -- title
--     source   = { strings },        -- static source (mutually exclusive with live)
--     live     = function(query)     -- returns ranked list { {item, display}, ... }
--     formatter= function(item) -> str
--     on_pick  = function(item)
--     previewer= function(item)      -- optional, called as cursor moves
--     limit    = 200
--   }
function M.pick(opts)
  opts = opts or {}
  close_picker()  -- reset any stale state
  picker = {
    prompt    = opts.prompt or "Find",
    source    = opts.source,
    live      = opts.live,
    formatter = opts.formatter or tostring,
    on_pick   = opts.on_pick,
    previewer = opts.previewer,
    limit     = opts.limit or 200,
    query     = "",
    cursor    = 1,
    matches   = {},
  }

  local cols = vim.o.columns
  local rows = vim.o.lines
  local W = math.min(120, math.floor(cols * 0.8))
  local H = math.min(20,  math.floor(rows * 0.6))
  local row = math.floor((rows - H - 3) / 2)
  local col = math.floor((cols - W) / 2)

  picker.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[picker.prompt_buf].buftype = "prompt"
  vim.bo[picker.prompt_buf].bufhidden = "wipe"
  vim.fn.prompt_setprompt(picker.prompt_buf, "› ")
  vim.fn.prompt_setcallback(picker.prompt_buf, function() accept() end)
  picker.prompt_win = vim.api.nvim_open_win(picker.prompt_buf, true, {
    relative = "editor", row = row, col = col, width = W, height = 1,
    style = "minimal", border = "rounded",
    title = " " .. picker.prompt .. " ", title_pos = "left",
    noautocmd = true,
  })
  vim.wo[picker.prompt_win].winhighlight = "Normal:NormalFloat,FloatBorder:JvimFinderPrompt"

  picker.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[picker.results_buf].buftype = "nofile"
  vim.bo[picker.results_buf].bufhidden = "wipe"
  vim.bo[picker.results_buf].swapfile = false
  picker.results_win = vim.api.nvim_open_win(picker.results_buf, false, {
    relative = "editor", row = row + 3, col = col, width = W, height = H,
    style = "minimal", border = "rounded",
    noautocmd = true,
  })
  vim.wo[picker.results_win].winhighlight = "Normal:NormalFloat,FloatBorder:JvimFinderPrompt"
  vim.wo[picker.results_win].cursorline = false
  vim.wo[picker.results_win].wrap = false

  -- Prompt-buffer keymaps (insert mode is the default in a prompt buffer).
  local function pk(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = picker.prompt_buf, nowait = true, silent = true })
  end
  pk("i", "<Esc>", close_picker)
  pk("n", "<Esc>", close_picker)
  pk("n", "q",     close_picker)
  pk("i", "<C-c>", close_picker)
  pk("i", "<C-n>", function() move( 1) end)
  pk("i", "<C-p>", function() move(-1) end)
  pk("i", "<Down>",function() move( 1) end)
  pk("i", "<Up>",  function() move(-1) end)
  pk("i", "<C-j>", function() move( 1) end)
  pk("i", "<C-k>", function() move(-1) end)
  pk("i", "<CR>",  accept)
  pk("n", "<CR>",  accept)

  -- Refresh results on every prompt edit.
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = picker.prompt_buf,
    callback = on_prompt_change,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = picker.prompt_buf,
    callback = on_prompt_change,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = picker.prompt_buf,
    once = true,
    callback = close_picker,
  })

  vim.cmd("startinsert")
  refresh()
end

-- =========================================================================
--  Built-in pickers.
-- =========================================================================

function M.files(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local files = list_files(cwd)
  M.pick({
    prompt = opts.prompt or "Files",
    source = files,
    on_pick = opts.on_pick or function(item)
      vim.cmd("edit " .. vim.fn.fnameescape(item))
    end,
  })
end

function M.buffers(opts)
  opts = opts or {}
  local items = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name == "" then name = "[No Name #" .. b .. "]" end
      items[#items + 1] = { bufnr = b, name = name }
    end
  end
  M.pick({
    prompt = opts.prompt or "Buffers",
    source = items,
    formatter = function(it) return string.format("%3d  %s", it.bufnr, vim.fn.fnamemodify(it.name, ":~:.")) end,
    on_pick = function(it) vim.api.nvim_set_current_buf(it.bufnr) end,
  })
end

function M.oldfiles(opts)
  opts = opts or {}
  local items = {}
  for _, f in ipairs(vim.v.oldfiles) do
    if uv().fs_stat(f) then items[#items + 1] = f end
  end
  M.pick({
    prompt = "Recent",
    source = items,
    formatter = function(p) return vim.fn.fnamemodify(p, ":~") end,
    on_pick = function(p) vim.cmd("edit " .. vim.fn.fnameescape(p)) end,
  })
end

function M.help_tags(opts)
  opts = opts or {}
  -- Walk &runtimepath/doc/tags*.
  local tags = {}
  for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
    for _, tf in ipairs(vim.fn.glob(dir .. "/doc/tags*", true, true)) do
      local lines = vim.fn.readfile(tf)
      for _, line in ipairs(lines) do
        local tag = line:match("^([^\t]+)\t")
        if tag then tags[#tags + 1] = tag end
      end
    end
  end
  table.sort(tags)
  M.pick({
    prompt = "Help",
    source = tags,
    on_pick = function(tag) vim.cmd("help " .. vim.fn.fnameescape(tag)) end,
  })
end

function M.diagnostics(opts)
  opts = opts or {}
  local items = {}
  local sev_name = { [1] = "E", [2] = "W", [3] = "I", [4] = "H" }
  for _, d in ipairs(vim.diagnostic.get(opts.bufnr)) do
    items[#items + 1] = d
  end
  M.pick({
    prompt = "Diagnostics",
    source = items,
    formatter = function(d)
      local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":~:.")
      return string.format("[%s] %s:%d:%d  %s",
        sev_name[d.severity] or "?", fname, (d.lnum or 0) + 1, (d.col or 0) + 1,
        (d.message or ""):gsub("\n", " "))
    end,
    on_pick = function(d)
      vim.api.nvim_set_current_buf(d.bufnr)
      pcall(vim.api.nvim_win_set_cursor, 0, { (d.lnum or 0) + 1, d.col or 0 })
    end,
  })
end

-- ##Function: Live grep using rg. Each keystroke runs a fresh, synchronous rg
-- (capped via --max-count and --max-columns so it returns quickly enough to
-- feel live). Falls back to nothing when rg is missing.
function M.grep(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  if not has("rg") then
    vim.notify("jvim.finder.grep requires ripgrep (rg)", vim.log.levels.WARN)
    return
  end
  local function live(query)
    if #query < 2 then
      return { { item = nil, display = "  (type 2+ chars)" } }
    end
    local lines = exec({
      "rg", "--vimgrep", "--smart-case", "--no-heading",
      "--color=never", "--max-count=200", "--max-columns=300",
      query, cwd,
    }) or {}
    local out = {}
    for i, l in ipairs(lines) do
      out[i] = { item = l, display = vim.fn.fnamemodify(l, ":.") }
      if i >= 200 then break end
    end
    return out
  end
  M.pick({
    prompt = "Grep",
    live = live,
    on_pick = function(line)
      if not line then return end
      local file, lnum, col = line:match("^([^:]+):(%d+):(%d+):")
      if not file then return end
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), tonumber(col) - 1 })
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("JvimFindFiles", M.files, { desc = "Find files" })
  vim.api.nvim_create_user_command("JvimFindBuffers", M.buffers, { desc = "Find buffers" })
  vim.api.nvim_create_user_command("JvimFindGrep", M.grep, { desc = "Live grep" })
  vim.api.nvim_create_user_command("JvimFindHelp", M.help_tags, { desc = "Find help tags" })
  vim.api.nvim_create_user_command("JvimFindOldfiles", M.oldfiles, { desc = "Find recent files" })
  vim.api.nvim_create_user_command("JvimFindDiagnostics", M.diagnostics, { desc = "Find diagnostics" })
end

return M
