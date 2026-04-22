-- jvim.indent_guides — native indent guide rendering via extmarks.
-- Replaces lukas-reineke/indent-blankline.nvim with no third-party
-- dependency. Designed for typical editing workloads (well below the
-- ~5k-line / large-file threshold the rest of jvim uses to back off).

local M = {}

local NS = vim.api.nvim_create_namespace("jvim_indent_guides")

-- Buffers we have already filtered out (non-files, big files, opt-out).
local _disabled = {}

-- ##Function: should-render predicate for a buffer.
local function eligible(buf)
  if _disabled[buf] then return false end
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local bt = vim.bo[buf].buftype
  if bt ~= "" then return false end
  local ft = vim.bo[buf].filetype
  if ft == "" or ft == "help" or ft == "man" or ft == "qf"
      or ft == "TelescopePrompt" or ft == "jvimdashboard"
      or ft == "jvimmessages" then
    return false
  end
  if vim.api.nvim_buf_line_count(buf) > 5000 then
    _disabled[buf] = true
    return false
  end
  return true
end

local function shiftwidth(buf)
  local sw = vim.bo[buf].shiftwidth
  if sw and sw > 0 then return sw end
  local ts = vim.bo[buf].tabstop
  return (ts and ts > 0) and ts or 4
end

local function leading_indent_cols(line, expandtab, tabstop)
  -- Returns the number of display columns of leading whitespace and the
  -- byte index just past that whitespace.
  local cols, i = 0, 1
  while i <= #line do
    local b = line:byte(i)
    if b == 0x20 then
      cols = cols + 1
      i = i + 1
    elseif b == 0x09 then
      cols = cols + (tabstop - (cols % tabstop))
      i = i + 1
    else
      break
    end
  end
  return cols, i
end

-- ##Function: Render guides for the visible region of `buf`. We clear the
-- whole buffer namespace and only emit extmarks for lines that are
-- currently visible in any window displaying `buf`. WinScrolled /
-- CursorMoved re-render so off-screen lines get repainted as they come
-- into view; this keeps each render call O(window-height) rather than
-- O(buffer-length).
function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not eligible(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local sw = shiftwidth(buf)
  local expandtab = vim.bo[buf].expandtab
  local tabstop = vim.bo[buf].tabstop
  if not tabstop or tabstop <= 0 then tabstop = sw end

  local line_count = vim.api.nvim_buf_line_count(buf)

  -- Compute the union of visible regions across windows showing this
  -- buffer. We pad by one screen-height on each side so quick scrolls
  -- between renders don't reveal an unpainted band.
  local top, bot = math.huge, 0
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local h = math.max(info.height or 20, 20)
      local t = math.max(1, (info.topline or 1) - h)
      local b = math.min(line_count, (info.botline or line_count) + h)
      if t < top then top = t end
      if b > bot then bot = b end
    end
  end
  if top == math.huge then return end

  -- Read just the slice we need (plus a small look-back/look-ahead window
  -- for blank-line inheritance). Vim line numbers are 1-based; nvim_buf_get_lines
  -- is 0-based with [start, end).
  local LOOK = 64
  local slice_start = math.max(1, top - LOOK)
  local slice_end = math.min(line_count, bot + LOOK)
  local lines = vim.api.nvim_buf_get_lines(buf, slice_start - 1, slice_end, false)
  local function line_at(absidx)
    return lines[absidx - slice_start + 1]
  end

  -- Track active guide column for "active block" highlighting using cursor
  -- position. `active_indent` may be nil if cursor is on a no-indent line.
  local active_indent
  do
    local cur_buf = vim.api.nvim_get_current_buf()
    if cur_buf == buf then
      local cur_line = vim.api.nvim_win_get_cursor(0)[1]
      local l = line_at(cur_line) or ""
      local cols = leading_indent_cols(l, expandtab, tabstop)
      if l:match("^%s*$") then
        -- Blank line: inherit indentation of nearest non-blank line above.
        for i = cur_line - 1, math.max(1, cur_line - LOOK), -1 do
          local li = line_at(i)
          if li and not li:match("^%s*$") then
            cols = leading_indent_cols(li, expandtab, tabstop)
            break
          end
        end
      end
      if cols > 0 then
        active_indent = math.floor((cols - 1) / sw) * sw
      end
    end
  end

  for i = top, bot do
    local l = line_at(i) or ""
    local cols
    if l:match("^%s*$") then
      -- Blank lines inherit indentation from the nearest non-blank line in
      -- either direction so guides remain visually continuous through
      -- vertical whitespace. Inheritance lookups are bounded by LOOK.
      local prev = 0
      for j = i - 1, math.max(1, i - LOOK), -1 do
        local lj = line_at(j)
        if lj and not lj:match("^%s*$") then
          prev = leading_indent_cols(lj, expandtab, tabstop)
          break
        end
      end
      local next_c = 0
      for j = i + 1, math.min(line_count, i + LOOK) do
        local lj = line_at(j)
        if lj and not lj:match("^%s*$") then
          next_c = leading_indent_cols(lj, expandtab, tabstop)
          break
        end
      end
      cols = math.min(prev, next_c)
    else
      cols = leading_indent_cols(l, expandtab, tabstop)
    end
    if cols and cols > 0 then
      -- Render one guide per indent level: a line indented exactly
      -- `n * sw` columns gets `n` guides at columns 0, sw, 2*sw, ...
      local stops = math.floor(cols / sw)
      for s = 0, stops - 1 do
        local at = s * sw
        local hl = (active_indent and at == active_indent)
                   and "JvimIndentGuideActive" or "JvimIndentGuide"
        -- Use a virt_text overlay at virt_text_win_col so the guide is
        -- painted into whitespace without altering buffer content.
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, {
          virt_text = { { "│", hl } },
          virt_text_win_col = at,
          hl_mode = "combine",
          priority = 1,
        })
      end
    end
  end
end

local _scheduled = {}
local function schedule(buf)
  if _scheduled[buf] then return end
  _scheduled[buf] = true
  vim.schedule(function()
    _scheduled[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then M.render(buf) end
  end)
end

-- ##Function: Public setup hook called from runtime/plugin/jvim_ui.lua.
function M.setup()
  local group = vim.api.nvim_create_augroup("JvimIndentGuides", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufEnter", "BufWritePost", "TextChanged", "TextChangedI",
    "CursorMoved", "WinScrolled", "FileType",
  }, {
    group = group,
    callback = function(ev) schedule(ev.buf or vim.api.nvim_get_current_buf()) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev) _disabled[ev.buf] = nil end,
  })
end

return M
