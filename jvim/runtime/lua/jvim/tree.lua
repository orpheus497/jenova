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
--   ?        show keymap help

local M = {}

local icons = require("jvim.icons")
local NS = vim.api.nvim_create_namespace("jvim_tree")

local DEFAULT_WIDTH = 32

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

-- ##Function: Render rows into the tree buffer with extmark highlights.
local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  rebuild_rows()
  local lines = {}
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
    local glyph = icons.get(r.name, { is_directory = r.kind == "dir", is_open = r.expanded })
    lines[#lines + 1] = " " .. indent .. twig .. glyph .. " " .. r.name
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(state.buf, NS, 0, 0, {
    end_row = 0, end_col = #lines[1], hl_group = "JvimTreeRoot",
  })
  for i, r in ipairs(state.rows) do
    local line = lines[i + 1]
    local _, glyph_hl = icons.get(r.name, { is_directory = r.kind == "dir", is_open = r.expanded })
    -- Highlight the glyph (3 bytes wide for nerd font) and the name.
    local glyph_byte_start = #(" " .. string.rep("  ", r.depth) .. (r.kind == "dir" and " " or "  "))
    local glyph_byte_end = glyph_byte_start + 4
    if glyph_hl then
      vim.api.nvim_buf_set_extmark(state.buf, NS, i, glyph_byte_start, {
        end_row = i, end_col = math.min(glyph_byte_end, #line),
        hl_group = glyph_hl,
      })
    end
    local name_start = math.min(glyph_byte_end + 1, #line)
    local name_hl = r.kind == "dir" and "JvimTreeDir" or "JvimTreeFile"
    if r.path == vim.api.nvim_buf_get_name(0) then
      name_hl = "JvimTreeOpened"
    end
    if name_start < #line then
      vim.api.nvim_buf_set_extmark(state.buf, NS, i, name_start, {
        end_row = i, end_col = #line, hl_group = name_hl,
      })
    end
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
    "  q              close tree",
    "  ?              this help",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"; vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local w, h = 50, #lines
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
end

return M
