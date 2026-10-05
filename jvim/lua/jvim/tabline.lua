-- jvim.tabline — first-party global tabline rendering listed buffers as tabs.
-- Replaces typical bufferline-style plugins. Activated via vim.o.tabline
-- (so it is window-agnostic) and refreshed whenever buffer listing changes.
--
-- Public API:
--   require("jvim.tabline").render()  -- statusline-style expression
--   require("jvim.tabline").setup()
--   require("jvim.tabline").goto_buf(idx)
--   require("jvim.tabline").close_buf(idx)

local M = {}

local icons = require("jvim.icons")

-- ##Function: List buflisted buffers in stable id order.
local function listed_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
        and vim.bo[b].buflisted
        and vim.bo[b].buftype == "" then
      out[#out + 1] = b
    end
  end
  return out
end

-- Cache of (buf -> render-index) so :JvimTabClose N is stable across redraws.
local _idx_to_buf = {}

local function buf_label(b)
  local name = vim.api.nvim_buf_get_name(b)
  if name == "" then return "[No Name]" end
  return vim.fn.fnamemodify(name, ":t")
end

-- ##Function: Build the tabline string with %#HL# colour escapes and %T
-- click handlers. Returns a string suitable for vim.o.tabline.
function M.render()
  local bufs = listed_buffers()
  _idx_to_buf = {}
  if #bufs == 0 then
    return "%#JvimTabFill# %#TabLineFill#"
  end
  local cur = vim.api.nvim_get_current_buf()
  local pieces = { "%#JvimTabFill# " }
  for i, b in ipairs(bufs) do
    _idx_to_buf[i] = b
    local active = b == cur
    local modified = vim.bo[b].modified
    local glyph, glyph_hl = icons.by_filetype(vim.bo[b].filetype)
    if vim.bo[b].filetype == "" then
      glyph, glyph_hl = icons.get(buf_label(b), {})
    end
    local body_hl = active and "JvimTabActive" or "JvimTabInactive"
    local glyph_group = active and glyph_hl or "JvimTabInactive"
    -- %nT = clickable region that switches to tab/buf n; we use a custom
    -- click handler via %@v:lua...
    pieces[#pieces + 1] = string.format(
      "%%@v:lua.require('jvim.tabline').click@" ..
      "%%#%s# %%#%s#%s %%#%s#%d %s%s %%X",
      body_hl, glyph_group, glyph,
      body_hl, i, buf_label(b),
      modified and " ●" or "")
    pieces[#pieces + 1] = "%#JvimTabSep#│"
  end
  pieces[#pieces] = "%#JvimTabFill#%T%="
  -- Right side: total buffer count.
  pieces[#pieces + 1] = string.format("%%#JvimTabInactive# %d buf %%#JvimTabFill# ", #bufs)
  return table.concat(pieces)
end

-- ##Function: Click handler bound via %@... in render(). Only left-click cycles
-- forward through the buffers (since %nT-style click resolution isn't sub-region
-- aware here, we just advance through the list).
function M.click(_, _, button, _)
  if button == "l" then
    vim.cmd("bnext")
  elseif button == "r" then
    vim.cmd("bprevious")
  elseif button == "m" then
    pcall(vim.cmd, "bdelete")
  end
end

function M.goto_buf(i)
  local b = _idx_to_buf[i]
  if b and vim.api.nvim_buf_is_valid(b) then
    vim.api.nvim_set_current_buf(b)
  end
end

function M.close_buf(i)
  local b = _idx_to_buf[i] or vim.api.nvim_get_current_buf()
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.cmd, "bdelete " .. b)
  end
end

function M.setup()
  vim.o.showtabline = 2
  vim.o.tabline = "%!v:lua.require('jvim.tabline').render()"
  -- Refresh on every event that can change the listed-buffer set.
  local group = vim.api.nvim_create_augroup("JvimTabline", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufAdd", "BufDelete", "BufWipeout",
    "BufEnter", "BufModifiedSet", "BufFilePost",
    "TermOpen", "TermClose",
  }, {
    group = group,
    callback = function() vim.cmd("redrawtabline") end,
  })
  -- 1..9 quick-jump mappings.
  for i = 1, 9 do
    vim.keymap.set("n", "<leader>" .. i, function() M.goto_buf(i) end,
      { silent = true, desc = "Go to buffer " .. i })
  end
end

return M
