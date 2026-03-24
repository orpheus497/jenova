-- ui.lua: Polished terminal UI for coder-agent
-- Pure ANSI escape sequences — no ncurses dependency, works on any terminal.
-- Provides: header with ASCII art, structured output regions, status bar,
--           styled input prompt, scrollback buffer, terminal resize handling.

local ffi = require("ffi")
local ffi_defs = require("ffi_defs")

local ui = {}

-------------------------------------------------------------------------------
-- ANSI escape helpers
-------------------------------------------------------------------------------
local ESC = "\27"
local CSI = ESC .. "["

local function esc(code)      return CSI .. code end
local function move(row, col) return CSI .. row .. ";" .. col .. "H" end
local function fg(n)          return CSI .. "38;5;" .. n .. "m" end
local function bg(n)          return CSI .. "48;5;" .. n .. "m" end

local RESET     = esc("0m")
local BOLD      = esc("1m")
local DIM       = esc("2m")
local ITALIC    = esc("3m")
local UNDERLINE = esc("4m")
local CLEAR_LINE = esc("2K")
local CLEAR_DOWN = esc("J")
local HIDE_CURSOR = esc("?25l")
local SHOW_CURSOR = esc("?25h")
local SAVE_CURSOR = ESC .. "7"
local RESTORE_CURSOR = ESC .. "8"
local ALT_SCREEN = esc("?1049h")
local MAIN_SCREEN = esc("?1049l")
local SCROLL_RESET = esc("r")

-------------------------------------------------------------------------------
-- Color palette — cool, professional tones
-------------------------------------------------------------------------------
local P = {
  header_bg    = 235,
  header_fg    = 75,
  header_accent = 117,
  header_dim   = 241,
  title_fg     = 153,
  border       = 240,
  border_light = 245,
  status_bg    = 236,
  status_fg    = 250,
  status_dim   = 243,
  prompt_fg    = 75,
  prompt_arrow = 117,
  text         = 253,
  dim          = 243,
  green        = 114,
  red          = 203,
  yellow       = 221,
  cyan         = 117,
  magenta      = 176,
  blue         = 75,
  orange       = 215,
  white        = 255,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local term_w = 80
local term_h = 24
local is_tty = false
local use_alt_screen = false
local header_lines = 0
local output_lines = {}
local status_text = ""
local turn_info = { turn = 0, max_turns = 25, actions = 0 }
local spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local spinner_idx = 0
local spinner_label = ""
local spinner_active = false
local original_termios = nil

local TIOCGWINSZ = 0x40087468  -- FreeBSD

-------------------------------------------------------------------------------
-- Terminal size detection
-------------------------------------------------------------------------------
local function get_term_size()
  local ws = ffi.new("unsigned short[4]")
  local ok = ffi.C.ioctl(1, TIOCGWINSZ, ws)
  if ok == 0 and ws[0] > 0 and ws[1] > 0 then
    return ws[1], ws[0]  -- cols, rows
  end
  local p = io.popen("tput cols 2>/dev/null")
  local c = p and tonumber(p:read("*l")) or 80
  if p then p:close() end
  p = io.popen("tput lines 2>/dev/null")
  local r = p and tonumber(p:read("*l")) or 24
  if p then p:close() end
  return c, r
end

local function refresh_size()
  term_w, term_h = get_term_size()
  if term_w < 40 then term_w = 40 end
  if term_h < 10 then term_h = 10 end
end

-------------------------------------------------------------------------------
-- Low-level write
-------------------------------------------------------------------------------
local write_buf = {}

local function w(s)
  write_buf[#write_buf + 1] = s
end

local function flush()
  if #write_buf > 0 then
    io.write(table.concat(write_buf))
    io.flush()
    write_buf = {}
  end
end

local function wflush(s)
  io.write(s)
  io.flush()
end

-------------------------------------------------------------------------------
-- Box drawing helpers
-------------------------------------------------------------------------------
local BOX = {
  tl = "╭", tr = "╮", bl = "╰", br = "╯",
  h  = "─", v  = "│",
  hl = "━",   -- heavy horizontal
  vl = "┃",   -- heavy vertical
  dt = "╌",   -- dashed
}

local function hline(char, width)
  return string.rep(char, width)
end

local function display_width(text)
  local raw = text:gsub("\27%[[%d;]*m", "")
  local w = 0
  local i = 1
  while i <= #raw do
    local b = raw:byte(i)
    if b < 0x80 then
      w = w + 1; i = i + 1
    elseif b < 0xC0 then
      i = i + 1
    elseif b < 0xE0 then
      w = w + 1; i = i + 2
    elseif b < 0xF0 then
      local cp = (b - 0xE0) * 4096
      if i + 2 <= #raw then
        cp = cp + (raw:byte(i+1) - 0x80) * 64 + (raw:byte(i+2) - 0x80)
      end
      if (cp >= 0x2580 and cp <= 0x259F)     -- block elements
        or (cp >= 0x2500 and cp <= 0x257F)   -- box drawing
        or (cp >= 0x2550 and cp <= 0x256C)   -- box drawing double
        or (cp >= 0x2588 and cp <= 0x259F)   -- block elements full
        or (cp >= 0x2800 and cp <= 0x28FF)   -- braille
        or (cp >= 0x25A0 and cp <= 0x25FF)   -- geometric shapes
        or (cp >= 0x2600 and cp <= 0x26FF)   -- misc symbols
        or (cp >= 0x2700 and cp <= 0x27BF)   -- dingbats
        or (cp >= 0x2190 and cp <= 0x21FF)   -- arrows
        or (cp >= 0xE000 and cp <= 0xF8FF)   -- private use
        or (cp >= 0x2580 and cp <= 0x25FF)   -- blocks + geo
      then
        w = w + 1
      elseif cp >= 0x1100 and (
        (cp <= 0x115F) or cp == 0x2329 or cp == 0x232A
        or (cp >= 0x2E80 and cp <= 0x303E)
        or (cp >= 0x3040 and cp <= 0x33BF)
        or (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0x4E00 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7AF)
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE6F)
        or (cp >= 0xFF01 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
      ) then
        w = w + 2
      else
        w = w + 1
      end
      i = i + 3
    else
      w = w + 2; i = i + 4
    end
  end
  return w
end

local function center(text, width, pad_char)
  pad_char = pad_char or " "
  local len = display_width(text)
  if len >= width then return text end
  local left = math.floor((width - len) / 2)
  local right = width - len - left
  return string.rep(pad_char, left) .. text .. string.rep(pad_char, right)
end

local function rpad(text, width)
  local len = display_width(text)
  if len >= width then return text end
  return text .. string.rep(" ", width - len)
end

local function truncate(text, width)
  local len = display_width(text)
  if len <= width then return text end
  local raw = text:gsub("\27%[[%d;]*m", "")
  return raw:sub(1, width - 1) .. "…"
end

-------------------------------------------------------------------------------
-- ASCII art header
-------------------------------------------------------------------------------
local HEADER_ART = {
  "  ██████╗ ██████╗ ██████╗ ███████╗██████╗ ",
  " ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗",
  " ██║     ██║   ██║██║  ██║█████╗  ██████╔╝",
  " ██║     ██║   ██║██║  ██║██╔══╝  ██╔══██╗",
  " ╚██████╗╚██████╔╝██████╔╝███████╗██║  ██║",
  "  ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝",
}

local HEADER_SMALL = {
  " ▄████▄  ▒█████  ▓█████▄ ▓█████  ██▀███  ",
  "▒██▀ ▀█ ▒██▒  ██▒▒██▀ ██▌▓█   ▀ ▓██ ▒ ██▒",
  "▒▓█    ▄▒██░  ██▒░██   █▌▒███   ▓██ ░▄█ ▒",
  "▒▓▓▄ ▄██▒██   ██░░▓█▄   ▌▒▓█  ▄ ▒██▀▀█▄  ",
  "▒ ▓███▀ ░ ████▓▒░░▒████▓ ░▒████▒░██▓ ▒██▒",
  "░ ░▒ ▒  ░ ▒░▒░▒░  ▒▒▓  ▒ ░░ ▒░ ░░ ▒▓ ░▒▓░",
}

local HEADER_MINI = " ◆ C O D E R "

local function header_row(inner_w, content)
  local dw = display_width(content)
  local left = math.floor((inner_w - dw) / 2)
  local right = inner_w - dw - left
  if left < 0 then left = 0 end
  if right < 0 then right = 0 end
  return fg(P.border) .. BOX.v .. bg(P.header_bg)
    .. string.rep(" ", left) .. content .. RESET .. bg(P.header_bg)
    .. string.rep(" ", right) .. RESET .. fg(P.border) .. BOX.v .. RESET .. "\n"
end

local function blank_row(inner_w)
  return fg(P.border) .. BOX.v .. bg(P.header_bg) .. string.rep(" ", inner_w) .. RESET .. fg(P.border) .. BOX.v .. RESET .. "\n"
end

function ui.draw_header()
  refresh_size()
  local inner_w = term_w - 2
  header_lines = 0

  local art = HEADER_ART
  if term_w < 52 then
    art = nil
  end

  -- Top border
  w(fg(P.border) .. BOX.tl .. hline(BOX.h, inner_w) .. BOX.tr .. RESET .. "\n")
  header_lines = header_lines + 1

  -- Blank line
  w(blank_row(inner_w))
  header_lines = header_lines + 1

  -- ASCII art
  if art then
    for _, line in ipairs(art) do
      w(header_row(inner_w, fg(P.header_fg) .. BOLD .. line .. RESET))
      header_lines = header_lines + 1
    end
  else
    w(header_row(inner_w, fg(P.header_fg) .. BOLD .. HEADER_MINI .. RESET))
    header_lines = header_lines + 1
  end

  -- Blank line
  w(blank_row(inner_w))
  header_lines = header_lines + 1

  -- Subtitle
  w(header_row(inner_w, fg(P.header_accent) .. "FreeBSD Local Coding Agent" .. RESET))
  header_lines = header_lines + 1

  -- Blank line
  w(blank_row(inner_w))
  header_lines = header_lines + 1

  -- Bottom border
  w(fg(P.border) .. BOX.bl .. hline(BOX.h, inner_w) .. BOX.br .. RESET .. "\n")
  header_lines = header_lines + 1

  flush()
end

-------------------------------------------------------------------------------
-- Info bar (right below header)
-------------------------------------------------------------------------------
function ui.draw_info(opts)
  opts = opts or {}
  local inner_w = term_w - 4

  local parts = {}
  if opts.cwd then
    parts[#parts + 1] = fg(P.dim) .. "  ◈ " .. RESET .. fg(P.text) .. opts.cwd .. RESET
  end

  -- Second line: connection + stats
  local stats = {}
  if opts.api_url then stats[#stats + 1] = fg(P.dim) .. "⚡ " .. RESET .. fg(P.status_dim) .. opts.api_url .. RESET end
  if opts.indexed then stats[#stats + 1] = fg(P.green) .. "◉ " .. RESET .. fg(P.status_dim) .. opts.indexed .. " files" .. RESET end
  if opts.embed then stats[#stats + 1] = fg(P.cyan) .. "◎ " .. RESET .. fg(P.status_dim) .. "embed:" .. opts.embed .. RESET end
  if opts.turns then stats[#stats + 1] = fg(P.dim) .. "turns:" .. opts.turns .. RESET end
  if opts.timeout then stats[#stats + 1] = fg(P.dim) .. "timeout:" .. opts.timeout .. "s" .. RESET end
  if opts.session then stats[#stats + 1] = fg(P.dim) .. "sid:" .. opts.session:sub(1,8) .. RESET end

  for _, p in ipairs(parts) do
    w(p .. "\n")
  end
  if #stats > 0 then
    w("  " .. table.concat(stats, fg(P.border) .. " │ " .. RESET) .. "\n")
  end
  w("\n")
  flush()
end

-------------------------------------------------------------------------------
-- Separator
-------------------------------------------------------------------------------
function ui.separator(label)
  local inner_w = term_w - 4
  if label then
    local raw_len = #(label:gsub("\27%[[%d;]*m", ""))
    local dash_left = 2
    local dash_right = inner_w - raw_len - dash_left - 2
    if dash_right < 2 then dash_right = 2 end
    wflush("  " .. fg(P.border) .. hline(BOX.dt, dash_left) .. " " .. RESET .. fg(P.border_light) .. label .. RESET .. " " .. fg(P.border) .. hline(BOX.dt, dash_right) .. RESET .. "\n")
  else
    wflush("  " .. fg(P.border) .. hline(BOX.dt, inner_w) .. RESET .. "\n")
  end
end

-------------------------------------------------------------------------------
-- Command help bar
-------------------------------------------------------------------------------
function ui.draw_commands(commands)
  local inner_w = term_w - 4
  local line = ""
  local raw_len = 0
  local lines = {}

  for _, cmd in ipairs(commands) do
    local entry = fg(P.dim) .. cmd .. RESET .. "  "
    local entry_len = #cmd + 2
    if raw_len + entry_len > inner_w then
      lines[#lines + 1] = line
      line = ""
      raw_len = 0
    end
    line = line .. entry
    raw_len = raw_len + entry_len
  end
  if line ~= "" then lines[#lines + 1] = line end

  for _, l in ipairs(lines) do
    wflush("  " .. l .. "\n")
  end
  wflush("\n")
end

-------------------------------------------------------------------------------
-- Status messages (replaces agent.lua's status())
-------------------------------------------------------------------------------
local ICONS = {
  think  = "◐", read  = "◉", write  = "◈", edit   = "◇",
  shell  = "⚡", search = "◎", list   = "◇", ok     = "✓",
  err    = "✗", warn  = "⚠", turn   = "→", nudge  = "↻",
  backup = "◆", info  = "●", bolt   = "⚡", gear   = "⚙",
  dot    = "•",
}

ui.ICONS = ICONS

function ui.status(icon, color_code, msg)
  wflush("  " .. fg(color_code) .. icon .. " " .. RESET .. msg .. "\n")
end

function ui.status_ok(msg)
  ui.status(ICONS.ok, P.green, fg(P.dim) .. msg .. RESET)
end

function ui.status_err(msg)
  ui.status(ICONS.err, P.red, fg(P.red) .. msg .. RESET)
end

function ui.status_warn(msg)
  ui.status(ICONS.warn, P.yellow, fg(P.yellow) .. msg .. RESET)
end

function ui.status_info(msg)
  ui.status(ICONS.dot, P.dim, fg(P.dim) .. msg .. RESET)
end

-------------------------------------------------------------------------------
-- Turn indicator
-------------------------------------------------------------------------------
function ui.status_turn(turn_num, max_turns, tool_name)
  local icon_map = {
    read_file = ICONS.read, write_file = ICONS.write, shell = ICONS.shell,
    search_files = ICONS.search, list_dir = ICONS.list, edit_file = ICONS.edit,
    think = ICONS.think,
  }
  local ic = icon_map[tool_name] or ICONS.turn
  wflush(
    "  " .. fg(P.yellow) .. ICONS.turn .. " " .. RESET
    .. fg(P.dim) .. "[" .. turn_num .. "/" .. max_turns .. "] " .. RESET
    .. fg(P.cyan) .. BOLD .. ic .. " " .. tool_name .. RESET .. "\n"
  )
end

-------------------------------------------------------------------------------
-- Shell output display
-------------------------------------------------------------------------------
function ui.shell_cmd(cmd)
  wflush("  " .. fg(P.dim) .. ICONS.shell .. " $ " .. cmd .. RESET .. "\n")
end

function ui.shell_result(exit_code, line_count)
  if exit_code == 0 then
    ui.status_ok(line_count .. " lines")
  else
    ui.status(ICONS.err, P.red, fg(P.red) .. "exit " .. exit_code .. RESET)
  end
end

-------------------------------------------------------------------------------
-- File operations display
-------------------------------------------------------------------------------
function ui.file_read(path)
  wflush("  " .. fg(P.blue) .. ICONS.read .. " reading " .. RESET .. path .. "\n")
end

function ui.file_read_done(size_str)
  ui.status_ok(size_str .. " read")
end

function ui.file_edit(path, old_len, new_len)
  wflush(
    "  " .. fg(P.green) .. ICONS.edit .. " editing " .. RESET .. path
    .. fg(P.dim) .. " (-" .. old_len .. "b +" .. new_len .. "b)" .. RESET .. "\n"
  )
end

function ui.file_write(path, size)
  wflush("  " .. fg(P.green) .. ICONS.write .. " writing " .. RESET .. path .. fg(P.dim) .. " (" .. size .. "b)" .. RESET .. "\n")
end

function ui.file_backup(path)
  wflush("  " .. fg(P.yellow) .. ICONS.backup .. " backup " .. RESET .. fg(P.dim) .. path .. RESET .. "\n")
end

function ui.file_search(query)
  wflush("  " .. fg(P.magenta) .. ICONS.search .. " search " .. RESET .. fg(P.dim) .. query .. RESET .. "\n")
end

function ui.file_list(path)
  wflush("  " .. fg(P.dim) .. ICONS.list .. " listing " .. path .. RESET .. "\n")
end

function ui.think_status(chars)
  wflush("  " .. fg(P.cyan) .. ICONS.think .. " thinking" .. RESET .. fg(P.dim) .. " (" .. chars .. " chars)" .. RESET .. "\n")
end

function ui.compile_check(path)
  wflush("  " .. fg(P.dim) .. ICONS.shell .. " auto-checking: cc -fsyntax-only " .. path .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Spinner
-------------------------------------------------------------------------------
function ui.spinner_start(label)
  spinner_active = true
  spinner_label = label or "thinking"
  spinner_idx = 1
  wflush("  " .. fg(P.cyan) .. spinner_frames[1] .. " " .. spinner_label .. RESET)
end

function ui.spinner_stop()
  if spinner_active then
    wflush("\r" .. CLEAR_LINE)
    spinner_active = false
  end
end

function ui.nonblocking_wait(seconds, label)
  local start_time = ffi_defs.wall_time()
  local last_spinner_update = 0
  spinner_active = true
  spinner_label = label or "waiting"
  spinner_idx = 1

  while ffi_defs.wall_time() - start_time < seconds do
    if ffi_defs.wall_time() - last_spinner_update > 0.1 then
      spinner_idx = (spinner_idx % #spinner_frames) + 1
      wflush("\r" .. CLEAR_LINE .. "  " .. fg(P.cyan) .. spinner_frames[spinner_idx] .. " " .. spinner_label .. RESET)
      last_spinner_update = ffi_defs.wall_time()
    end
    -- Efficiently sleep for 0.1 seconds without busy-waiting
    local tv = ffi.new("struct timeval")
    tv.tv_sec = 0
    tv.tv_usec = 100000 -- 100ms
    ffi.C.select(0, nil, nil, nil, tv)
  end
  ui.spinner_stop()
end
-------------------------------------------------------------------------------
-- Nudge display
-------------------------------------------------------------------------------
function ui.nudge(count, max, reason)
  wflush(
    "  " .. fg(P.yellow) .. ICONS.nudge .. " nudge " .. count .. "/" .. max .. RESET
    .. fg(P.dim) .. " (" .. reason .. ")" .. RESET .. "\n"
  )
end

-------------------------------------------------------------------------------
-- Confirmation prompt
-------------------------------------------------------------------------------
function ui.confirm(action_type, detail)
  wflush(
    "\n  " .. fg(P.yellow) .. BOLD .. ICONS.warn .. " [confirm] " .. RESET .. action_type .. "\n"
    .. "  " .. fg(P.dim) .. detail .. RESET .. "\n"
    .. "  " .. BOLD .. "1" .. RESET .. "=yes  " .. BOLD .. "2" .. RESET .. "=no  " .. BOLD .. "3" .. RESET .. "=suggest\n"
    .. "  " .. BOLD .. "> " .. RESET
  )
  local choice = io.read("*l")
  if not choice then return "no", nil end
  choice = choice:match("^%s*(.-)%s*$")
  if choice == "1" or choice:lower() == "y" or choice:lower() == "yes" then
    return "yes", nil
  elseif choice == "3" then
    wflush("  " .. BOLD .. "suggestion> " .. RESET)
    return "suggest", io.read("*l")
  else
    return "no", nil
  end
end

-------------------------------------------------------------------------------
-- User prompt
-------------------------------------------------------------------------------
function ui.prompt()
  wflush(fg(P.prompt_fg) .. BOLD .. "you" .. RESET .. fg(P.prompt_arrow) .. " ❯ " .. RESET)
end

function ui.continuation_prompt()
  wflush(fg(P.dim) .. "... " .. RESET)
end

-------------------------------------------------------------------------------
-- Agent response display
-------------------------------------------------------------------------------
function ui.agent_response(text)
  if not text or text == "" then return end
  wflush(
    "\n  " .. fg(P.green) .. BOLD .. "coder" .. RESET .. fg(P.dim) .. " │ " .. RESET .. text .. "\n\n"
  )
end

-------------------------------------------------------------------------------
-- Error display (for fatal/system errors)
-------------------------------------------------------------------------------
function ui.error(msg)
  wflush("\n  " .. fg(P.red) .. BOLD .. ICONS.err .. " " .. RESET .. fg(P.red) .. msg .. RESET .. "\n")
end

function ui.fatal(msg)
  wflush("\n" .. fg(P.red) .. "fatal: " .. msg .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Debug output
-------------------------------------------------------------------------------
function ui.debug(label, data)
  wflush(fg(P.magenta) .. "[DBG " .. label .. "] " .. RESET .. tostring(data):sub(1, 2000) .. "\n")
end

-------------------------------------------------------------------------------
-- Diagnostic line (for empty response)
-------------------------------------------------------------------------------
function ui.diagnostic(info)
  wflush(fg(P.dim) .. "  [diag] " .. info .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- REPL command output
-------------------------------------------------------------------------------
function ui.dimtext(text)
  wflush(fg(P.dim) .. text .. RESET)
end

function ui.boldtext(text)
  wflush(BOLD .. text .. RESET)
end

function ui.server_not_running(url)
  wflush(fg(P.red) .. ICONS.err .. " llama-server not running at " .. url .. RESET .. "\n")
  wflush(fg(P.dim) .. "  Start with: ./coder-server" .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Goodbye
-------------------------------------------------------------------------------
function ui.goodbye()
  wflush(fg(P.dim) .. "\n  bye\n" .. RESET)
end

-------------------------------------------------------------------------------
-- Path fix warning
-------------------------------------------------------------------------------
function ui.path_fixed(old_path, new_path)
  wflush("  " .. fg(P.yellow) .. ICONS.warn .. " path fixed " .. RESET .. fg(P.dim) .. old_path .. " → " .. new_path .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Expose palette and helpers for external use
-------------------------------------------------------------------------------
ui.P = P
ui.fg = fg
ui.bg = bg
ui.RESET = RESET
ui.BOLD = BOLD
ui.DIM = DIM
ui.center = center
ui.hline = hline
ui.BOX = BOX

function ui.get_width()
  refresh_size()
  return term_w
end

function ui.get_height()
  refresh_size()
  return term_h
end

return ui
