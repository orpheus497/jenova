-- jvim.keyhelp — native which-key-style popup.
-- Replaces folke/which-key.nvim with no third-party dependency.
--
-- Behaviour:
--   * After `vim.o.timeoutlen` of pending keystrokes that look like a
--     prefix into a known mapping, a floating popup lists every mapping
--     whose lhs starts with that prefix, grouped by user-registered
--     section labels.
--   * Group labels are registered via require("jvim.keyhelp").register({...}).
--   * The popup auto-closes when the next real keystroke is consumed.

local M = {}

-- ##Subsection: state.
local _groups = {}              -- map prefix -> { name = "Group" }
local _popup = { win = nil, buf = nil }
local _timer = nil
local _showing_for = nil        -- the prefix the popup is currently rendered for
local _seq = ""                 -- accumulated keystrokes since the last full sequence

local function uv() return vim.uv or vim.loop end

-- ##Function: User-facing registration. Each spec entry is a table:
--   { "<leader>g", group = "Git" }
function M.register(specs)
  for _, s in ipairs(specs or {}) do
    if s[1] and s.group then
      _groups[s[1]] = { name = s.group }
    end
  end
end

-- ##Function: Translate a typed sequence (raw bytes from vim.on_key) into the
-- canonical lhs form used by nvim_get_keymap (e.g. " gg" -> "<leader>gg" when
-- mapleader is " "). We perform a simple replacement for <leader> only — that
-- covers the common case for which-key style hints.
local function normalise(seq)
  local leader = vim.g.mapleader or "\\"
  if seq:sub(1, #leader) == leader then
    return "<leader>" .. seq:sub(#leader + 1)
  end
  return seq
end

-- ##Function: Collect mappings whose lhs starts with `prefix` for the given mode.
local function collect(mode, prefix)
  local hits = {}
  local function visit(maps)
    for _, m in ipairs(maps) do
      if m.lhs and m.lhs ~= prefix and m.lhs:sub(1, #prefix) == prefix then
        local desc = m.desc or m.rhs or ""
        hits[#hits + 1] = { lhs = m.lhs, desc = tostring(desc) }
      end
    end
  end
  visit(vim.api.nvim_get_keymap(mode))
  visit(vim.api.nvim_buf_get_keymap(0, mode))
  table.sort(hits, function(a, b) return a.lhs < b.lhs end)
  return hits
end

local function close_popup()
  if _popup.win and vim.api.nvim_win_is_valid(_popup.win) then
    pcall(vim.api.nvim_win_close, _popup.win, true)
  end
  if _popup.buf and vim.api.nvim_buf_is_valid(_popup.buf) then
    pcall(vim.api.nvim_buf_delete, _popup.buf, { force = true })
  end
  _popup.win, _popup.buf = nil, nil
  _showing_for = nil
end

local function open_popup(prefix, hits)
  close_popup()
  local group = _groups[prefix]
  local title = group and (" " .. group.name .. " (" .. prefix .. ") ")
                or (" " .. prefix .. " ")

  -- Compose lines. Format: "  <suffix>   <desc>"
  local key_w = 0
  for _, h in ipairs(hits) do
    local suffix = h.lhs:sub(#prefix + 1)
    if #suffix > key_w then key_w = #suffix end
  end
  key_w = math.min(math.max(key_w, 3), 18)

  local lines = {}
  for _, h in ipairs(hits) do
    local suffix = h.lhs:sub(#prefix + 1)
    lines[#lines + 1] = string.format("  %-" .. key_w .. "s   %s", suffix, h.desc)
  end

  -- Truncate to terminal height.
  local max_h = math.max(3, math.floor(vim.o.lines * 0.5))
  if #lines > max_h then
    local cut = #lines - max_h + 1
    lines = vim.list_slice(lines, 1, max_h - 1)
    lines[#lines + 1] = string.format("  ... %d more", cut)
  end

  local width = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    if w > width then width = w end
  end
  width = math.min(math.max(width, #title + 2, 28),
                   math.floor(vim.o.columns * 0.6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local NS = vim.api.nvim_create_namespace("jvim_keyhelp")
  for i, l in ipairs(lines) do
    -- Highlight the key portion (chars 3..3+key_w).
    vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 2, {
      end_row = i - 1, end_col = math.min(2 + key_w, #l),
      hl_group = "JvimKeyhelpKey",
    })
    if #l > 2 + key_w + 3 then
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 2 + key_w + 3, {
        end_row = i - 1, end_col = #l, hl_group = "JvimKeyhelpDesc",
      })
    end
  end

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", anchor = "SE",
    row = vim.o.lines - 2, col = vim.o.columns - 2,
    width = width, height = #lines,
    style = "minimal", border = "rounded", focusable = false,
    noautocmd = true, zindex = 50,
    title = title, title_pos = "left",
  })
  vim.wo[win].winhighlight =
    "Normal:NormalFloat,FloatBorder:JvimKeyhelpGroup,FloatTitle:JvimKeyhelpGroup"
  _popup.buf, _popup.win = buf, win
  _showing_for = prefix
end

-- ##Function: Schedule a popup for `prefix` after `vim.o.timeoutlen` ms.
local function schedule_popup(mode, prefix)
  if _timer then pcall(function() _timer:close() end) end
  _timer = uv().new_timer()
  if not _timer then return end
  local delay = math.max(50, vim.o.timeoutlen or 300)
  _timer:start(delay, 0, vim.schedule_wrap(function()
    if not _timer then return end
    pcall(function() _timer:close() end)
    _timer = nil
    -- Compare the normalised in-flight sequence against the normalised
    -- prefix we scheduled with so leader-prefixed sequences (e.g. " " vs
    -- "<leader>") still match.
    if normalise(_seq) ~= prefix then return end
    local hits = collect(mode, prefix)
    if #hits == 0 then close_popup(); return end
    open_popup(prefix, hits)
  end))
end

-- ##Function: vim.on_key tap — track the in-flight key sequence and pop up
-- the help when it looks like an unfinished mapping prefix.
local function on_key(_, typed)
  if not typed or typed == "" then return end
  -- Only react in normal/visual modes — popups during insert would be noisy.
  local mode = vim.api.nvim_get_mode().mode
  if not (mode == "n" or mode == "v" or mode == "V") then
    _seq = ""
    if _popup.win then close_popup() end
    return
  end

  -- A control char (escape, CR, etc.) ends the in-flight sequence.
  if typed:byte(1) <= 0x1F then
    _seq = ""
    close_popup()
    return
  end

  _seq = _seq .. typed
  local norm = normalise(_seq)

  -- If the sequence is itself a complete mapping, the popup is unnecessary.
  -- We let Neovim resolve it; clear state on the next keystroke.
  local maps = vim.api.nvim_get_keymap(mode)
  local exact, has_extension = false, false
  for _, m in ipairs(maps) do
    if m.lhs == norm then exact = true end
    if m.lhs ~= norm and m.lhs:sub(1, #norm) == norm then has_extension = true end
  end
  if exact and not has_extension then
    _seq = ""
    close_popup()
    return
  end
  if not has_extension then
    _seq = ""
    close_popup()
    return
  end

  -- Reschedule popup (cancels previous timer).
  schedule_popup(mode, norm)
end

-- ##Function: Public setup hook called from runtime/plugin/jvim_ui.lua.
function M.setup(opts)
  opts = opts or {}
  if opts.groups then M.register(opts.groups) end
  vim.o.timeout = true
  if not vim.o.timeoutlen or vim.o.timeoutlen <= 0 then
    vim.o.timeoutlen = 300
  end
  local NS = vim.api.nvim_create_namespace("jvim_keyhelp_onkey")
  vim.on_key(on_key, NS)
end

return M
