-- jvim.notify — native notification queue rendered in stacked floating
-- windows in the bottom-right of the editor. Replaces rcarriga/nvim-notify
-- and is installed as `vim.notify` from `runtime/plugin/jvim_ui.lua`.
--
-- API:
--   require("jvim.notify").notify(msg, level, opts)
--     msg   : string | string[] message body (newlines split into lines)
--     level : vim.log.levels.* (defaults to INFO)
--     opts  : { title = "..." , timeout = ms (default 4000) }
--   require("jvim.notify").history()        -- returns past notifications
--   :JvimMessages                            -- opens a scrollable history pane
--
-- Design notes:
--   * Each notification is a transient floating window pinned to the
--     bottom-right of the editor. Active windows stack upward.
--   * When a notification expires, every window above it shifts down to
--     close the gap.
--   * No external dependencies — uses libuv timers + nvim_open_win.

local M = {}

local LEVEL_NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "OFF" }
local LEVEL_HL = {
  ERROR = "JvimNotifyError",
  WARN  = "JvimNotifyWarn",
  INFO  = "JvimNotifyInfo",
  HINT  = "JvimNotifyHint",
  DEBUG = "JvimNotifyHint",
  TRACE = "JvimNotifyHint",
}
local LEVEL_ICON = {
  ERROR = "", WARN = "", INFO = "", HINT = "", DEBUG = "", TRACE = "",
}

local NS = vim.api.nvim_create_namespace("jvim_notify")
local MAX_HISTORY = 200

-- Active stack and history.
local _active = {}    -- list of { buf, win, expires_at, height }
local _history = {}   -- list of { msg, level, title, ts }
local _next_id = 0

local function uv() return vim.uv or vim.loop end
local function now_ns() return uv().hrtime() end

local function level_name(level)
  if type(level) == "string" then return level:upper() end
  if type(level) == "number" then
    return LEVEL_NAMES[level + 1] or "INFO"
  end
  return "INFO"
end

local function split_lines(msg)
  if type(msg) == "table" then
    -- Normalise table inputs (typical `vim.notify({"a","b"})` form, but
    -- also defensively handle non-string elements / nested tables).
    local out = {}
    for _, item in ipairs(msg) do
      local s = type(item) == "string" and item or tostring(item)
      for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
    end
    if #out > 0 and out[#out] == "" then table.remove(out) end
    if #out == 0 then out = { "" } end
    return out
  end
  if type(msg) ~= "string" then msg = tostring(msg) end
  local lines = {}
  for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then lines = { "" } end
  return lines
end

local function _config_win(win, lvl)
  local hl = LEVEL_HL[lvl] or "JvimNotifyInfo"
  vim.wo[win].winhighlight = "Normal:JvimNotifyBody,FloatBorder:" .. hl
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].foldenable = false
end

local function _layout()
  -- Bottom-right anchor; stack notifications upward.
  local total_rows = vim.o.lines
  local total_cols = vim.o.columns
  -- Reserve 1 row for cmdline; clamp.
  local bottom = total_rows - 2
  local right = total_cols - 2
  local row = bottom
  for _, n in ipairs(_active) do
    row = row - n.height - 2
    n.row = row
  end
  for _, n in ipairs(_active) do
    if n.win and vim.api.nvim_win_is_valid(n.win) then
      pcall(vim.api.nvim_win_set_config, n.win, {
        relative = "editor",
        anchor = "SE",
        row = n.row + n.height + 2,
        col = right,
        width = n.width,
        height = n.height,
      })
    end
  end
  return bottom, right
end

local function _expire(id)
  for i, n in ipairs(_active) do
    if n.id == id then
      if n.timer then pcall(function() n.timer:close() end) end
      if n.win and vim.api.nvim_win_is_valid(n.win) then
        pcall(vim.api.nvim_win_close, n.win, true)
      end
      if n.buf and vim.api.nvim_buf_is_valid(n.buf) then
        pcall(vim.api.nvim_buf_delete, n.buf, { force = true })
      end
      table.remove(_active, i)
      _layout()
      return
    end
  end
end

function M.notify(msg, level, opts)
  opts = opts or {}
  local lvl = level_name(level)
  local title = opts.title
  local timeout = opts.timeout or 4000
  local lines = split_lines(msg)

  -- Record history (never mutate the user's lines).
  _history[#_history + 1] = {
    msg = lines, level = lvl, title = title, ts = os.time(),
  }
  while #_history > MAX_HISTORY do table.remove(_history, 1) end

  -- During startup or in headless mode, avoid touching floating windows.
  if vim.in_fast_event() then
    vim.schedule(function() M.notify(msg, level, opts) end)
    return
  end
  if vim.fn.has("vim_starting") == 1 or not vim.api.nvim_list_uis or #vim.api.nvim_list_uis() == 0 then
    -- Fall back to the native message line; still recorded above.
    pcall(vim.api.nvim_echo, {
      { (title and ("[" .. title .. "] ") or "") .. table.concat(lines, " | "),
        LEVEL_HL[lvl] or "Normal" },
    }, true, {})
    return
  end

  -- Compose buffer.
  local body = {}
  local icon = LEVEL_ICON[lvl] or ""
  if title then
    body[1] = "  " .. title
    body[2] = string.format("%s %s", icon, lines[1] or "")
    for i = 2, #lines do body[#body + 1] = "  " .. lines[i] end
  else
    body[1] = string.format("%s %s", icon, lines[1] or "")
    for i = 2, #lines do body[#body + 1] = "  " .. lines[i] end
  end

  local width = 0
  for _, l in ipairs(body) do
    local w = vim.fn.strdisplaywidth(l)
    if w > width then width = w end
  end
  width = math.min(math.max(width + 2, 24), math.floor(vim.o.columns * 0.5))
  local height = math.min(#body, math.floor(vim.o.lines * 0.4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  if title then
    vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, {
      end_row = 0, end_col = #body[1], hl_group = "JvimNotifyTitle",
    })
  end

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", anchor = "SE",
    row = vim.o.lines - 2, col = vim.o.columns - 2,
    width = width, height = height,
    style = "minimal", border = "rounded",
    focusable = false, noautocmd = true, zindex = 60,
  })
  _config_win(win, lvl)

  _next_id = _next_id + 1
  local entry = {
    id = _next_id, buf = buf, win = win,
    width = width, height = height,
  }
  table.insert(_active, 1, entry)
  _layout()

  if timeout and timeout > 0 then
    local t = uv().new_timer()
    entry.timer = t
    t:start(timeout, 0, vim.schedule_wrap(function() _expire(entry.id) end))
  end
end

function M.history()
  return vim.deepcopy(_history)
end

-- :JvimMessages — open a scratch buffer in a vertical split with the full
-- notification history (newest first).
function M.open_history()
  local lines = {}
  for i = #_history, 1, -1 do
    local h = _history[i]
    local stamp = os.date("%H:%M:%S", h.ts)
    local prefix = string.format("[%s] %-5s", stamp, h.level)
    if h.title then prefix = prefix .. " " .. h.title .. ":" end
    lines[#lines + 1] = prefix
    for _, l in ipairs(h.msg) do
      lines[#lines + 1] = "    " .. l
    end
    lines[#lines + 1] = ""
  end
  if #lines == 0 then lines = { "(no messages)" } end
  vim.cmd("botright vnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "jvimmessages"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- ##Function: Wire vim.notify to this module and create :JvimMessages.
function M.setup()
  vim.notify = function(msg, level, opts)
    M.notify(msg, level, opts)
  end
  vim.api.nvim_create_user_command("JvimMessages", function() M.open_history() end,
    { desc = "Open jvim notification history" })
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("JvimNotifyResize", { clear = true }),
    callback = function() _layout() end,
  })
end

return M
