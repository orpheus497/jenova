-- jvim.diagnostics_list — bottom-docked workspace diagnostics list. Replaces
-- folke/trouble.nvim. Pulls from vim.diagnostic.get(nil) so it covers every
-- attached LSP server's diagnostics as well as any we set ourselves.
--
-- Public API:
--   require("jvim.diagnostics_list").open([opts])
--   require("jvim.diagnostics_list").close()
--   require("jvim.diagnostics_list").toggle([opts])
--   require("jvim.diagnostics_list").is_open()
--   opts.scope = "workspace"|"buffer"   (default "workspace")
--   opts.bufnr = N                       (used when scope=="buffer")

local M = {}

local NS = vim.api.nvim_create_namespace("jvim_diag_list")

local SEV_LABEL = { [1] = "E", [2] = "W", [3] = "I", [4] = "H" }
local SEV_HL    = {
  [1] = "DiagnosticError", [2] = "DiagnosticWarn",
  [3] = "DiagnosticInfo",  [4] = "DiagnosticHint",
}

local state = {
  buf = nil,
  win = nil,
  scope = "workspace",
  scope_buf = nil,
  rows = {},     -- list of { d, file, display }
  height = 12,
}

local function gather()
  local diags
  if state.scope == "buffer" then
    diags = vim.diagnostic.get(state.scope_buf or 0)
  else
    diags = vim.diagnostic.get(nil)
  end
  -- Sort by file -> line -> severity.
  table.sort(diags, function(a, b)
    if a.bufnr ~= b.bufnr then
      return vim.api.nvim_buf_get_name(a.bufnr) < vim.api.nvim_buf_get_name(b.bufnr)
    end
    if a.lnum ~= b.lnum then return (a.lnum or 0) < (b.lnum or 0) end
    return (a.severity or 4) < (b.severity or 4)
  end)
  return diags
end

local function rebuild()
  state.rows = {}
  local diags = gather()
  if #diags == 0 then
    state.rows[1] = { display = "  No diagnostics", header = true }
    return
  end
  local cur_file = nil
  for _, d in ipairs(diags) do
    local fname = vim.api.nvim_buf_get_name(d.bufnr)
    if fname == "" then fname = "[No Name #" .. d.bufnr .. "]" end
    if fname ~= cur_file then
      state.rows[#state.rows + 1] = {
        header = true,
        display = " " .. vim.fn.fnamemodify(fname, ":~:."),
      }
      cur_file = fname
    end
    state.rows[#state.rows + 1] = {
      d = d,
      display = string.format("    %s  %4d:%-3d  %s",
        SEV_LABEL[d.severity] or "?",
        (d.lnum or 0) + 1, (d.col or 0) + 1,
        (d.message or ""):gsub("\n", " ")),
    }
  end
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  rebuild()
  local lines = {}
  for i, r in ipairs(state.rows) do lines[i] = r.display end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for i, r in ipairs(state.rows) do
    if r.header then
      vim.api.nvim_buf_set_extmark(state.buf, NS, i - 1, 0, {
        end_row = i - 1, end_col = #r.display, hl_group = "JvimDiagListFile",
      })
    elseif r.d then
      local sev_hl = SEV_HL[r.d.severity] or "DiagnosticInfo"
      vim.api.nvim_buf_set_extmark(state.buf, NS, i - 1, 0, {
        end_row = i - 1, end_col = math.min(7, #r.display), hl_group = sev_hl,
      })
      vim.api.nvim_buf_set_extmark(state.buf, NS, i - 1, 7, {
        end_row = i - 1, end_col = math.min(20, #r.display), hl_group = "JvimDiagListLine",
      })
    end
  end
end

local function row_at_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local l = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.rows[l]
end

local function jump()
  local r = row_at_cursor()
  if not r or not r.d then return end
  local d = r.d
  -- Find a non-list window to jump in.
  local target
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= state.win and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "jvimdiaglist" then
      target = w
      break
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_set_current_buf(d.bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { (d.lnum or 0) + 1, d.col or 0 })
  end
end

local function setup_keymaps(buf)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  k("<CR>", jump, "Jump to diagnostic")
  k("o",    jump, "Jump to diagnostic")
  k("q",    function() M.close() end, "Close")
  k("R",    render, "Refresh")
  k("b",    function() state.scope = "buffer";    state.scope_buf = vim.api.nvim_get_current_buf(); render() end, "Buffer scope")
  k("w",    function() state.scope = "workspace"; render() end, "Workspace scope")
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.open(opts)
  opts = opts or {}
  state.scope = opts.scope or state.scope
  state.scope_buf = opts.bufnr or vim.api.nvim_get_current_buf()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].filetype = "jvimdiaglist"
    vim.api.nvim_buf_set_name(state.buf, "[jvim-diagnostics]")
    setup_keymaps(state.buf)
  end
  if M.is_open() then M.focus(); render(); return end
  vim.cmd("botright " .. state.height .. "split")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = true
  wo.wrap = false
  wo.list = false
  wo.statuscolumn = ""
  wo.winfixheight = true
  render()
end

function M.close()
  if M.is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

function M.toggle(opts) if M.is_open() then M.close() else M.open(opts) end end

function M.focus()
  if M.is_open() then vim.api.nvim_set_current_win(state.win) end
end

function M.setup()
  vim.api.nvim_create_user_command("JvimDiagnostics", function(o)
    M.toggle({ scope = o.args ~= "" and o.args or "workspace" })
  end, { nargs = "?", complete = function() return { "workspace", "buffer" } end,
        desc = "Toggle jvim diagnostics list" })
  -- Live update when diagnostics change.
  local group = vim.api.nvim_create_augroup("JvimDiagList", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function()
      if M.is_open() then render() end
    end,
  })
end

return M
