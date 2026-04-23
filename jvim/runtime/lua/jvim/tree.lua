-- jvim.tree — native file explorer rendered into a left vertical split.
-- Replaces nvim-tree/nvim-tree.lua. Designed to be small, predictable,
-- and to share state with the bottom terminal + dashboard layout.
--
-- Public API:
--   require("jvim.tree").open([dir])
--   require("jvim.tree").close()
--   require("jvim.tree").toggle([dir])
--   require("jvim.tree").focus()
--   require("jvim.tree").reveal(path)        -- expand to + focus a path
--   require("jvim.tree").is_open()
--
-- Buffer keymaps (set on the tree buffer only):
--   <CR>     open file / toggle directory
--   o        same as <CR>
--   l        expand directory or open file
--   h        collapse directory (or move to parent)
--   <C-v>    open file in vertical split
--   <C-x>    open file in horizontal split
--   <C-t>    open file in new tab
--   a        create file/dir under cursor
--   d        delete entry under cursor
--   r        rename entry under cursor
--   R        refresh tree
--   .        toggle hidden files
--   q        close tree
--   ]e       jump to next entry with diagnostics
--   [e       jump to prev entry with diagnostics
--   ?        show keymap help

local M = {}

local icons = require("jvim.icons")
local NS = vim.api.nvim_create_namespace("jvim_tree")

local DEFAULT_WIDTH = 32

local SEV_HL = {
  [1] = "DiagnosticError",
  [2] = "DiagnosticWarn",
  [3] = "DiagnosticInfo",
  [4] = "DiagnosticHint",
}
local SEV_BADGE = { [1] = "E", [2] = "W", [3] = "I", [4] = "H" }

local state = {
  buf = nil,
  win = nil,
  root = nil,        -- absolute root directory string
  expanded = {},     -- map: abs_path -> true
  show_hidden = false,
  width = DEFAULT_WIDTH,
  -- Render cache: list of { path, name, depth, kind = "dir"|"file", expanded }
  rows = {},
}

local function uv() return vim.uv or vim.loop end

-- ##Function: Sort entries — directories first, then alphabetical.
local function sort_entries(a, b)
  if a.kind == b.kind then return a.name < b.name end
  return a.kind == "dir"
end

-- ##Function: Read directory. Returns sorted list of { name, path, kind }.
local function read_dir(dir)
  local out = {}
  local fs = uv().fs_scandir(dir)
  if not fs then return out end
  while true do
    local name, t = uv().fs_scandir_next(fs)
    if not name then break end
    if state.show_hidden or name:sub(1, 1) ~= "." then
      local p = dir .. "/" .. name
      local kind = (t == "directory") and "dir"
                   or (t == "link"
                       and (uv().fs_stat(p) and uv().fs_stat(p).type == "directory"
                            and "dir" or "file")
                       or "file")
      out[#out + 1] = { name = name, path = p, kind = kind }
    end
  end
  table.sort(out, sort_entries)
  return out
end

-- ##Function: Recompute the row list given the current expanded set.
local function rebuild_rows()
  state.rows = {}
  local function walk(dir, depth)
    local entries = read_dir(dir)
    for _, e in ipairs(entries) do
      local row = {
        path = e.path, name = e.name,
        depth = depth, kind = e.kind,
        expanded = e.kind == "dir" and state.expanded[e.path] or false,
      }
      state.rows[#state.rows + 1] = row
      if row.expanded then walk(e.path, depth + 1) end
    end
  end
  walk(state.root, 0)
end

-- ##Function: Gather workspace diagnostics, returning a map:
--   abs_path -> { max_severity, count }
local function gather_diag_map()
  local map = {}
  local all = vim.diagnostic.get(nil)
  for _, d in ipairs(all) do
    local path = vim.api.nvim_buf_get_name(d.bufnr)
    if path and path ~= "" then
      local entry = map[path]
      if not entry then
        map[path] = { severity = d.severity or 4, count = 1 }
      else
        if (d.severity or 4) < entry.severity then
          entry.severity = d.severity
        end
        entry.count = entry.count + 1
      end
    end
  end
  -- For directories: bubble up the worst severity of any child.
  -- We do a second pass over rows after rebuild_rows() in render().
  return map
end

-- ##Function: Render rows into the tree buffer with extmark highlights.
-- Preserves cursor position across re-renders.
local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  -- Save cursor before modifying buffer.
  local saved_cursor = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    saved_cursor = vim.api.nvim_win_get_cursor(state.win)
  end

  rebuild_rows()
  local diag_map = gather_diag_map()

  -- Bubble diagnostics up into expanded parent directories.
  local dir_diag = {}
  for _, r in ipairs(state.rows) do
    local entry = diag_map[r.path]
    if entry then
      -- Walk up and mark each parent directory.
      local parent = r.path:match("^(.*)/[^/]+$")
      while parent and parent ~= state.root do
        if not dir_diag[parent] then
          dir_diag[parent] = { severity = entry.severity, count = entry.count }
        else
          if entry.severity < dir_diag[parent].severity then
            dir_diag[parent].severity = entry.severity
          end
          dir_diag[parent].count = dir_diag[parent].count + entry.count
        end
        parent = parent:match("^(.*)/[^/]+$")
      end
    end
  end

  local lines = {}
  -- { glyph_hl, glyph_start, glyph_end, name_hl, name_start, diag_entry, badge_start } per row
  local meta = {}

  -- Header line shows the root with a folder icon.
  local root_short = vim.fn.fnamemodify(state.root, ":t")
  if root_short == "" then root_short = state.root end
  lines[1] = "  " .. root_short

  for _, r in ipairs(state.rows) do
    local indent = string.rep("  ", r.depth)
    local twig
    if r.kind == "dir" then
      twig = r.expanded and " " or " "
    else
      twig = "  "
    end
    local glyph, glyph_hl = icons.get(r.name, { is_directory = r.kind == "dir", is_open = r.expanded })

    -- Compute exact byte offsets using the actual prefix string length.
    local prefix    = " " .. indent .. twig
    local glyph_start = #prefix              -- byte offset of the icon glyph
    local glyph_end   = glyph_start + #glyph -- byte offset after the icon glyph
    local name_start  = glyph_end + 1        -- +1 for the space between glyph and name

    local name_hl = r.kind == "dir" and "JvimTreeDir" or "JvimTreeFile"
    if r.path == vim.api.nvim_buf_get_name(0) then
      name_hl = "JvimTreeOpened"
    end

    -- Diagnostic badge for this entry.
    local diag_entry = diag_map[r.path] or dir_diag[r.path]
    local badge = ""
    local badge_start = 0
    if diag_entry then
      badge = "  " .. SEV_BADGE[diag_entry.severity] .. " " .. diag_entry.count
    end

    local line = prefix .. glyph .. " " .. r.name .. badge
    badge_start = #(prefix .. glyph .. " " .. r.name) -- byte offset of badge

    lines[#lines + 1] = line
    meta[#meta + 1] = {
      glyph_hl    = glyph_hl,
      glyph_start = glyph_start,
      glyph_end   = glyph_end,
      name_hl     = name_hl,
      name_start  = name_start,
      diag_entry  = diag_entry,
      badge_start = badge_start,
    }
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  -- Header highlight.
  vim.api.nvim_buf_set_extmark(state.buf, NS, 0, 0, {
    end_row = 0, end_col = #lines[1], hl_group = "JvimTreeRoot",
  })

  -- Per-row highlights (0-based row index = i, because lines[1] is header at row 0,
  -- and meta[i] / state.rows[i] correspond to lines[i+1] at 0-based row i).
  for i, m in ipairs(meta) do
    local row_0 = i          -- 0-based line index
    local line  = lines[i + 1]
    if not line then break end

    if m.glyph_hl then
      vim.api.nvim_buf_set_extmark(state.buf, NS, row_0, m.glyph_start, {
        end_row = row_0,
        end_col = math.min(m.glyph_end, #line),
        hl_group = m.glyph_hl,
      })
    end

    if m.name_start <= #line then
      local name_end = m.diag_entry and m.badge_start or #line
      vim.api.nvim_buf_set_extmark(state.buf, NS, row_0, m.name_start, {
        end_row = row_0,
        end_col = math.min(name_end, #line),
        hl_group = m.name_hl,
      })
    end

    if m.diag_entry and m.badge_start < #line then
      local sev_hl = SEV_HL[m.diag_entry.severity] or "DiagnosticInfo"
      vim.api.nvim_buf_set_extmark(state.buf, NS, row_0, m.badge_start, {
        end_row = row_0,
        end_col = #line,
        hl_group = sev_hl,
      })
    end
  end

  -- Restore cursor, clamped to new line count.
  if saved_cursor and state.win and vim.api.nvim_win_is_valid(state.win) then
    local total = vim.api.nvim_buf_line_count(state.buf)
    local row = math.min(saved_cursor[1], total)
    pcall(vim.api.nvim_win_set_cursor, state.win, { row, saved_cursor[2] })
  end
end

-- ##Function: Find the row for the cursor's current line (1-indexed).
local function row_at_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  if line == 1 then return nil end -- header
  return state.rows[line - 1]
end

-- ##Function: Find the first non-tree window to use for opening files.
local function pick_target_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= state.win and vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "" or vim.bo[b].filetype ~= "jvimterminal" then
        return w
      end
    end
  end
  return nil
end

local function open_path(path, how)
  if how == "vsplit" then vim.cmd("vsplit " .. vim.fn.fnameescape(path)); return end
  if how == "split"  then vim.cmd("split "  .. vim.fn.fnameescape(path)); return end
  if how == "tab"    then vim.cmd("tabedit " .. vim.fn.fnameescape(path)); return end
  local target = pick_target_win()
  if target then
    vim.api.nvim_set_current_win(target)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    -- No editor window — create one to the right of the tree.
    vim.cmd("wincmd l")
    vim.cmd("vsplit " .. vim.fn.fnameescape(path))
  end
end

local function activate(how)
  local r = row_at_cursor()
  if not r then return end
  if r.kind == "dir" then
    state.expanded[r.path] = not state.expanded[r.path]
    render()
  else
    open_path(r.path, how)
  end
end

local function collapse()
  local r = row_at_cursor()
  if not r then return end
  if r.kind == "dir" and state.expanded[r.path] then
    state.expanded[r.path] = nil
    render()
    return
  end
  -- Move cursor to parent.
  local parent = r.path:match("^(.*)/[^/]+$")
  if not parent then return end
  for i, row in ipairs(state.rows) do
    if row.path == parent then
      vim.api.nvim_win_set_cursor(state.win, { i + 1, 0 })
      return
    end
  end
end

local function refresh() render() end

local function toggle_hidden()
  state.show_hidden = not state.show_hidden
  render()
end

-- ##Function: Jump to the next/prev row that has diagnostics.
local function jump_diag(direction)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local diag_map = gather_diag_map()
  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  local n = #state.rows
  if n == 0 then return end
  local step = direction > 0 and 1 or -1
  local start = direction > 0 and (cur - 1) % n + 1 or (cur - 3 + n) % n + 1
  for _ = 1, n do
    local r = state.rows[start]
    if r and diag_map[r.path] then
      vim.api.nvim_win_set_cursor(state.win, { start + 1, 0 })
      return
    end
    start = (start - 1 + step + n) % n + 1
  end
end

local function create_entry()
  local r = row_at_cursor()
  local base
  if r then
    base = r.kind == "dir" and r.path or (r.path:match("^(.*)/[^/]+$") or state.root)
  else
    base = state.root
  end
  vim.ui.input({ prompt = "Create (end with / for dir): ", default = base .. "/" }, function(input)
    if not input or input == "" then return end
    if input:sub(-1) == "/" then
      vim.fn.mkdir(input:sub(1, -2), "p")
    else
      vim.fn.mkdir(vim.fn.fnamemodify(input, ":h"), "p")
      local fd = uv().fs_open(input, "w", 420)
      if fd then uv().fs_close(fd) end
    end
    if input:sub(-1) ~= "/" then
      state.expanded[base] = true
    end
    render()
  end)
end

local function delete_entry()
  local r = row_at_cursor()
  if not r then return end
  vim.ui.select({ "yes", "no" }, { prompt = "Delete " .. r.name .. "?" }, function(choice)
    if choice ~= "yes" then return end
    if r.kind == "dir" then
      vim.fn.delete(r.path, "rf")
    else
      vim.fn.delete(r.path)
    end
    state.expanded[r.path] = nil
    render()
  end)
end

local function rename_entry()
  local r = row_at_cursor()
  if not r then return end
  vim.ui.input({ prompt = "Rename to: ", default = r.path }, function(input)
    if not input or input == "" or input == r.path then return end
    vim.fn.mkdir(vim.fn.fnamemodify(input, ":h"), "p")
    uv().fs_rename(r.path, input)
    state.expanded[r.path] = nil
    render()
  end)
end

local function help_popup()
  local lines = {
    "jvim.tree keymaps",
    "",
    "  <CR> / o / l   open file or toggle directory",
    "  h              collapse directory or move to parent",
    "  <C-v>          open in vertical split",
    "  <C-x>          open in horizontal split",
    "  <C-t>          open in new tab",
    "  a              create file (end with / for directory)",
    "  d              delete entry",
    "  r              rename entry",
    "  R              refresh",
    "  .              toggle hidden files",
    "  ]e             next entry with diagnostics",
    "  [e             prev entry with diagnostics",
    "  q              close tree",
    "  ?              this help",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"; vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local w, h = 52, #lines
  vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
  })
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf, nowait = true })
end

local function setup_buf_keymaps(buf)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  k("<CR>", function() activate() end, "Open / toggle")
  k("o",    function() activate() end, "Open / toggle")
  k("l",    function() activate() end, "Open / toggle")
  k("h",    collapse, "Collapse / parent")
  k("<C-v>", function() activate("vsplit") end, "Open vsplit")
  k("<C-x>", function() activate("split")  end, "Open split")
  k("<C-t>", function() activate("tab")    end, "Open tab")
  k("a", create_entry, "Create")
  k("d", delete_entry, "Delete")
  k("r", rename_entry, "Rename")
  k("R", refresh,      "Refresh")
  k(".", toggle_hidden,"Toggle hidden")
  k("]e", function() jump_diag(1)  end, "Next diagnostic")
  k("[e", function() jump_diag(-1) end, "Prev diagnostic")
  k("q", function() M.close() end, "Close tree")
  k("?", help_popup,   "Help")
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.open(dir)
  if M.is_open() then M.focus(); return end
  state.root = dir or state.root or vim.fn.getcwd()
  state.root = vim.fn.fnamemodify(state.root, ":p"):gsub("/$", "")

  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].buflisted = false
    vim.bo[state.buf].filetype = "jvimtree"
    vim.api.nvim_buf_set_name(state.buf, "[jvim-tree]")
    setup_buf_keymaps(state.buf)
  end

  vim.cmd("topleft vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.api.nvim_win_set_width(state.win, state.width)
  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = true
  wo.wrap = false
  wo.list = false
  wo.foldenable = false
  wo.statuscolumn = ""
  wo.winfixwidth = true

  render()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

function M.toggle(dir)
  if M.is_open() then M.close() else M.open(dir) end
end

function M.focus()
  if not M.is_open() then return end
  vim.api.nvim_set_current_win(state.win)
end

function M.reveal(path)
  path = vim.fn.fnamemodify(path, ":p")
  if not path:find(state.root or "", 1, true) then return end
  M.open(state.root)
  -- Expand each parent directory between root and the file.
  local rel = path:sub(#state.root + 2)
  local accum = state.root
  for part in rel:gmatch("[^/]+") do
    accum = accum .. "/" .. part
    local stat = uv().fs_stat(accum)
    if stat and stat.type == "directory" then
      state.expanded[accum] = true
    end
  end
  render()
  for i, r in ipairs(state.rows) do
    if r.path == path then
      vim.api.nvim_win_set_cursor(state.win, { i + 1, 0 })
      break
    end
  end
end

function M.setup()
  vim.api.nvim_create_user_command("JvimTree", function(opts)
    M.toggle(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", complete = "dir", desc = "Toggle jvim file tree" })
  vim.api.nvim_create_user_command("JvimTreeReveal", function()
    M.reveal(vim.api.nvim_buf_get_name(0))
  end, { desc = "Reveal current file in jvim tree" })

  -- Auto-refresh diagnostic badges when LSP reports new diagnostics.
  local group = vim.api.nvim_create_augroup("JvimTreeDiag", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function()
      if M.is_open() then
        -- Debounce: schedule to avoid rapid successive renders during attach.
        vim.defer_fn(render, 150)
      end
    end,
  })
end

return M
