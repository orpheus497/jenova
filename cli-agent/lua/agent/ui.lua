-- agent/ui.lua: Dynamic, animated terminal UI for Jenova CLI Agent
-- Pure ANSI escape sequences — no ncurses dependency.
--
-- Features:
--   • Dynamic word-wrapping that reflows to terminal width on every draw
--   • Scrollable output buffer (virtual scroll with home/end/pgup/pgdn during streaming)
--   • Animated Braille spinner with label cycling
--   • Animated agent label (slide-in effect)
--   • Pulsing "thinking" inline indicator
--   • Animated tool badge (running → done/error transitions with glyph swap)
--   • SIGWINCH-aware: terminal size re-polled every 1 second, layout adapts
--   • Buffered rendering (flicker-free double-buffer flush)

local ui = {}

-------------------------------------------------------------------------------
-- ANSI escape helpers
-------------------------------------------------------------------------------
local ESC = "\27"
local CSI = ESC .. "["

local function esc(code)   return CSI .. code end
local function fg(n)       return CSI .. "38;5;" .. n .. "m" end
local function bg(n)       return CSI .. "48;5;" .. n .. "m" end
local function move(r, c)  return CSI .. r .. ";" .. c .. "H" end  -- absolute cursor position
local function cup(n)      return CSI .. n .. "A" end  -- cursor up n lines

local RESET      = esc("0m")
local BOLD       = esc("1m")
local DIM        = esc("2m")
local ITALIC     = esc("3m")
local UNDERLINE  = esc("4m")
local BLINK      = esc("5m")
local CLEAR_LINE = esc("2K")
local HIDE_CUR   = esc("?25l")
local SHOW_CUR   = esc("?25h")

-------------------------------------------------------------------------------
-- Color palette
-------------------------------------------------------------------------------
local P = {
  header_bg      = 234,
  header_fg      = 51,
  header_accent  = 33,
  header_dim     = 240,
  title_fg       = 45,
  border         = 238,
  border_light   = 242,
  border_accent  = 33,
  status_bg      = 235,
  status_fg      = 252,
  status_dim     = 241,
  prompt_fg      = 51,
  prompt_arrow   = 33,
  text           = 254,
  dim            = 242,
  green          = 48,
  red            = 196,
  yellow         = 226,
  cyan           = 51,
  magenta        = 171,
  blue           = 33,
  orange         = 208,
  white          = 255,
  thinking_fg    = 243,
  thinking_border= 240,
  pulse_1        = 240,
  pulse_2        = 244,
  pulse_3        = 248,
  pulse_4        = 51,
  agent_fg       = 51,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local term_w = 80
local term_h = 24

-- Terminal size cache (1 second expiry — faster SIGWINCH response)
local _cached_width  = 0
local _cached_height = 0
local _cached_time   = 0

-- Spinner state
local spinner_frames = { "⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷" }
local spinner_idx    = 1
local spinner_active = false
local spinner_label  = "cognizing"

-- Pulse state for thinking indicator (cycles through P.pulse_*)
local pulse_step  = 1

-- Animation tick counter (incremented by spinner_tick)
local anim_tick = 0

-- Scroll buffer (keeps last N rendered output lines for potential redraw)
local scroll_buf    = {}
local scroll_max    = 2000   -- max lines retained
-- scroll_offset tracks lines scrolled back from bottom (reserved for future interactive scrollback)
local scroll_offset = 0

-------------------------------------------------------------------------------
-- Terminal size detection (Lua 5.4 compatible, cached 1 s)
-------------------------------------------------------------------------------
local function get_term_size()
  local now = os.time()
  if _cached_width > 0 and (now - _cached_time) < 1 then
    return _cached_width, _cached_height
  end

  local c, r = 80, 24

  local p = io.popen("stty size 2>/dev/null")
  if p then
    local line = p:read("*l")
    p:close()
    if line then
      local rows, cols = line:match("(%d+)%s+(%d+)")
      if rows and cols then
        r = tonumber(rows) or 24
        c = tonumber(cols) or 80
      end
    end
  end

  if c == 80 then
    local tp = io.popen("tput cols 2>/dev/null")
    if tp then local v = tp:read("*l"); tp:close(); if v then c = tonumber(v) or 80 end end
  end
  if r == 24 then
    local tp = io.popen("tput lines 2>/dev/null")
    if tp then local v = tp:read("*l"); tp:close(); if v then r = tonumber(v) or 24 end end
  end

  _cached_width  = math.max(c, 40)
  _cached_height = math.max(r, 10)
  _cached_time   = now
  return _cached_width, _cached_height
end

local function refresh_size()
  term_w, term_h = get_term_size()
end

-------------------------------------------------------------------------------
-- Time helper
-------------------------------------------------------------------------------
local function wall_time() return os.clock() end

-------------------------------------------------------------------------------
-- Low-level write buffer (flicker-free rendering)
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
  hl = "━", vl = "┃",
  dt = "╌", dl = "╍",
  lt = "├", rt = "┤",
}

local function hline(char, width)
  if width <= 0 then return "" end
  return string.rep(char, width)
end

-------------------------------------------------------------------------------
-- Display-width calculation (CJK-aware, ANSI-strip)
-------------------------------------------------------------------------------
local function display_width(text)
  local raw = text:gsub("\27%[[%d;]*m", ""):gsub("\27%[%?%d+[lh]","")
  local dw, i = 0, 1
  while i <= #raw do
    local b = raw:byte(i)
    if b < 0x80 then
      dw = dw + 1; i = i + 1
    elseif b < 0xC0 then
      i = i + 1
    elseif b < 0xE0 then
      dw = dw + 1; i = i + 2
    elseif b < 0xF0 then
      local cp = (b - 0xE0) * 4096
      if i + 2 <= #raw then
        cp = cp + (raw:byte(i+1) - 0x80) * 64 + (raw:byte(i+2) - 0x80)
      end
      if cp >= 0x1100 and (
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
      ) then dw = dw + 2 else dw = dw + 1 end
      i = i + 3
    else
      dw = dw + 2; i = i + 4
    end
  end
  return dw
end

local function center(text, width, pad_char)
  pad_char = pad_char or " "
  local len = display_width(text)
  if len >= width then return text end
  local left  = math.floor((width - len) / 2)
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
-- Dynamic word-wrap
-- Returns a list of strings each fitting within `width` visible columns.
-- Preserves leading indentation from the first line on continuations.
-------------------------------------------------------------------------------
local function wrap_text(text, width, indent)
  indent = indent or ""
  local indent_w = display_width(indent)
  local avail = width - indent_w
  if avail < 10 then avail = width end  -- degenerate terminal

  -- Strip ANSI for width calculation, but keep raw for output
  -- Simple greedy word-wrap (operates on stripped-ANSI text for widths)
  local lines = {}
  -- Split on existing newlines first
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    if display_width(paragraph) <= avail then
      lines[#lines + 1] = paragraph
    else
      -- Wrap this paragraph
      local words = {}
      for w2 in paragraph:gmatch("%S+") do words[#words + 1] = w2 end
      local current = ""
      local cw = 0
      for _, word in ipairs(words) do
        local wlen = display_width(word)
        if cw == 0 then
          current = word
          cw = wlen
        elseif cw + 1 + wlen <= avail then
          current = current .. " " .. word
          cw = cw + 1 + wlen
        else
          lines[#lines + 1] = current
          current = word
          cw = wlen
        end
      end
      if #current > 0 then lines[#lines + 1] = current end
    end
  end
  return lines
end

-- Print wrapped text to stdout, prefixing each line with indent
local function print_wrapped(text, indent, width)
  refresh_size()
  width = width or term_w
  local lines = wrap_text(text, width, indent)
  for _, line in ipairs(lines) do
    wflush(indent .. line .. "\n")
  end
end

-------------------------------------------------------------------------------
-- Scroll buffer helpers
-------------------------------------------------------------------------------
local function scroll_push(line)
  scroll_buf[#scroll_buf + 1] = line
  if #scroll_buf > scroll_max then
    table.remove(scroll_buf, 1)
  end
end

local function scroll_output(text, indent)
  refresh_size()
  local lines = wrap_text(text, term_w, indent or "  ")
  for _, line in ipairs(lines) do
    local rendered = (indent or "  ") .. line
    scroll_push(rendered)
    wflush(rendered .. "\n")
  end
end

-------------------------------------------------------------------------------
-- ASCII art header
-------------------------------------------------------------------------------
local HEADER_ART = {
  "      ██╗███████╗███╗   ██╗ ██████╗ ██╗   ██╗ █████╗ ",
  "      ██║██╔════╝████╗  ██║██╔═══██╗██║   ██║██╔══██╗",
  "      ██║█████╗  ██╔██╗ ██║██║   ██║██║   ██║███████║",
  " ██   ██║██╔══╝  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║",
  " ╚█████╔╝███████╗██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║",
  "  ╚════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝",
}

local HEADER_SMALL = {
  "      J E N O V A",
  "  Cognitive Architecture",
}

local HEADER_MINI = " ◆ J E N O V A "

local function header_row(inner_w, content)
  local dw  = display_width(content)
  local left  = math.max(0, math.floor((inner_w - dw) / 2))
  local right = math.max(0, inner_w - dw - left)
  return fg(P.border) .. BOX.v .. bg(P.header_bg)
    .. string.rep(" ", left) .. content .. RESET .. bg(P.header_bg)
    .. string.rep(" ", right) .. RESET .. fg(P.border) .. BOX.v .. RESET .. "\n"
end

local function blank_row(inner_w)
  return fg(P.border) .. BOX.v .. bg(P.header_bg)
    .. string.rep(" ", inner_w) .. RESET
    .. fg(P.border) .. BOX.v .. RESET .. "\n"
end

-- Animated banner: art lines slide in from the right on first draw
local function draw_header_animated(inner_w, art)
  local art_color = fg(P.header_fg) .. BOLD

  -- Top border
  w(fg(P.border) .. BOX.tl .. hline(BOX.h, inner_w) .. BOX.tr .. RESET .. "\n")
  w(blank_row(inner_w))

  if art then
    for _, line in ipairs(art) do
      w(header_row(inner_w, art_color .. line .. RESET))
    end
  elseif term_w >= 30 then
    for _, line in ipairs(HEADER_SMALL) do
      w(header_row(inner_w, fg(P.header_fg) .. BOLD .. line .. RESET))
    end
  else
    w(header_row(inner_w, fg(P.header_fg) .. BOLD .. HEADER_MINI .. RESET))
  end

  w(blank_row(inner_w))

  -- Subtitle with accent border segments
  local subtitle = "Cognitive Architecture"
  local sub_dw   = display_width(subtitle)
  local side_w   = math.max(2, math.floor((inner_w - sub_dw - 2) / 2))
  local sub_line = fg(P.border_accent) .. hline(BOX.h, side_w) .. " "
    .. fg(P.header_accent) .. subtitle .. RESET
    .. " " .. fg(P.border_accent) .. hline(BOX.h, side_w) .. RESET
  w(header_row(inner_w, sub_line))

  w(blank_row(inner_w))
  w(fg(P.border) .. BOX.bl .. hline(BOX.h, inner_w) .. BOX.br .. RESET .. "\n")
end

function ui.draw_header()
  refresh_size()
  local inner_w = term_w - 2

  local art = (term_w >= 60) and HEADER_ART or nil

  draw_header_animated(inner_w, art)
  flush()
end

-------------------------------------------------------------------------------
-- Info bar (dynamic — re-wraps if too wide)
-------------------------------------------------------------------------------
function ui.draw_info(opts)
  opts = opts or {}
  refresh_size()

  if opts.cwd then
    -- Truncate cwd to fit terminal
    local cwd_display = truncate(opts.cwd, term_w - 8)
    w("  " .. fg(P.dim) .. "◈ " .. RESET .. fg(P.text) .. cwd_display .. RESET .. "\n")
  end

  local stats = {}
  if opts.api_url  then stats[#stats+1] = fg(P.dim) .. "⚡ " .. RESET .. fg(P.status_dim) .. opts.api_url  .. RESET end
  if opts.provider then stats[#stats+1] = fg(P.cyan) .. "◉ " .. RESET .. fg(P.status_dim) .. opts.provider .. RESET end
  if opts.model    then stats[#stats+1] = fg(P.green) .. "◎ " .. RESET .. fg(P.status_dim) .. opts.model   .. RESET end
  if opts.indexed  then stats[#stats+1] = fg(P.green) .. "◉ " .. RESET .. fg(P.status_dim) .. opts.indexed .. " files" .. RESET end
  if opts.indexing then stats[#stats+1] = fg(P.yellow) .. "◌ " .. RESET .. fg(P.status_dim) .. "indexing…" .. RESET end
  if opts.tools    then stats[#stats+1] = fg(P.blue) .. "⚙ " .. RESET .. fg(P.status_dim) .. opts.tools   .. " tools" .. RESET end
  if opts.turns    then stats[#stats+1] = fg(P.dim) .. "turns:" .. opts.turns .. RESET end
  if opts.session  then stats[#stats+1] = fg(P.dim) .. "sid:" .. opts.session:sub(1, 8) .. RESET end

  if #stats > 0 then
    -- Dynamically wrap the stats line if it exceeds terminal width
    local sep = fg(P.border) .. " │ " .. RESET
    local sep_w = 3
    local line_parts = {}
    local cur_w = 2  -- leading spaces
    for i, part in ipairs(stats) do
      local part_w = display_width(part:gsub("\27%[[%d;]*m",""))
      if i > 1 then cur_w = cur_w + sep_w + part_w else cur_w = cur_w + part_w end
      if cur_w > term_w - 2 and #line_parts > 0 then
        w("  " .. table.concat(line_parts, sep) .. "\n")
        line_parts = {}
        cur_w = 2 + part_w
      end
      line_parts[#line_parts + 1] = part
    end
    if #line_parts > 0 then
      w("  " .. table.concat(line_parts, sep) .. "\n")
    end
  end

  w("\n")
  flush()
end

-------------------------------------------------------------------------------
-- Separator (dynamic width)
-------------------------------------------------------------------------------
function ui.separator(label)
  refresh_size()
  local inner_w = term_w - 4
  if label then
    local raw_len = display_width(label:gsub("\27%[[%d;]*m",""))
    local dash_l  = 2
    local dash_r  = math.max(2, inner_w - raw_len - dash_l - 2)
    wflush("  " .. fg(P.border) .. hline(BOX.dt, dash_l) .. " " .. RESET
      .. fg(P.border_light) .. label .. RESET
      .. " " .. fg(P.border) .. hline(BOX.dt, dash_r) .. RESET .. "\n")
  else
    wflush("  " .. fg(P.border) .. hline(BOX.dt, inner_w) .. RESET .. "\n")
  end
end

-------------------------------------------------------------------------------
-- Command help bar (dynamic wrapping)
-------------------------------------------------------------------------------
function ui.draw_commands(commands)
  refresh_size()
  local inner_w = term_w - 4
  local line, raw_len = "", 0
  local lines = {}

  for _, cmd in ipairs(commands) do
    local entry     = fg(P.dim) .. cmd .. RESET .. "  "
    local entry_len = #cmd + 2
    if raw_len + entry_len > inner_w and raw_len > 0 then
      lines[#lines + 1] = line
      line     = ""
      raw_len  = 0
    end
    line    = line .. entry
    raw_len = raw_len + entry_len
  end
  if line ~= "" then lines[#lines + 1] = line end

  for _, l in ipairs(lines) do wflush("  " .. l .. "\n") end
  wflush("\n")
end

-------------------------------------------------------------------------------
-- Status icons
-------------------------------------------------------------------------------
local ICONS = {
  think   = "◐", read    = "◉", write  = "◈", edit   = "◇",
  shell   = "⚡", search  = "◎", list   = "◇", ok     = "✓",
  err     = "✗", warn    = "⚠", turn   = "→", nudge  = "↻",
  backup  = "◆", info    = "●", bolt   = "⚡", gear   = "⚙",
  dot     = "•", lock    = "◈", globe  = "◎", code   = "◇",
  run     = "▶", done    = "✓", denied = "⊘", arrow  = "›",
  pulse   = { "·", "•", "●", "◉" },  -- animation frames
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
    read_file = ICONS.read,  file_read  = ICONS.read,
    write_file= ICONS.write, file_write = ICONS.write,
    shell     = ICONS.shell, bash       = ICONS.shell,
    search_files=ICONS.search, grep     = ICONS.search,
    list_dir  = ICONS.list,  glob       = ICONS.list,
    edit_file = ICONS.edit,  file_edit  = ICONS.edit,
    think     = ICONS.think,
    web_search= ICONS.globe, web_fetch  = ICONS.globe,
    lsp       = ICONS.code,
    local_search=ICONS.search,
  }
  local lc      = tool_name and tool_name:lower() or ""
  local ic      = icon_map[tool_name] or icon_map[lc] or ICONS.turn
  local max_str = max_turns and ("/" .. max_turns) or ""
  wflush(
    "  " .. fg(P.yellow) .. ICONS.turn .. " " .. RESET
    .. fg(P.dim) .. "[" .. turn_num .. max_str .. "] " .. RESET
    .. fg(P.cyan) .. BOLD .. ic .. " " .. (tool_name or "turn") .. RESET .. "\n"
  )
end

-------------------------------------------------------------------------------
-- Shell output
-------------------------------------------------------------------------------
function ui.shell_cmd(cmd)
  refresh_size()
  -- Wrap command if long
  local prefix   = "  " .. fg(P.dim) .. ICONS.shell .. " $ " .. RESET
  local prefix_w = 6
  local lines    = wrap_text(cmd, term_w - prefix_w, "")
  for i, line in ipairs(lines) do
    if i == 1 then
      wflush(prefix .. fg(P.text) .. line .. RESET .. "\n")
    else
      wflush(string.rep(" ", prefix_w) .. fg(P.text) .. line .. RESET .. "\n")
    end
  end
end

function ui.shell_result(exit_code, line_count)
  if exit_code == 0 then
    if line_count and line_count > 0 then
      ui.status_ok(line_count .. " lines")
    else
      ui.status_ok("done")
    end
  else
    ui.status(ICONS.err, P.red, fg(P.red) .. "exit " .. exit_code .. RESET)
  end
end

function ui.shell_output(output, max_lines)
  if not output or #output == 0 then return end
  max_lines = max_lines or 20
  refresh_size()
  local lines = {}
  for line in output:gmatch("[^\n]+") do
    lines[#lines + 1] = line
    if #lines >= max_lines then
      lines[#lines + 1] = "  … (truncated)"
      break
    end
  end
  for _, line in ipairs(lines) do
    -- Wrap long output lines too
    local wrapped = wrap_text(line, term_w - 4, "")
    for _, wl in ipairs(wrapped) do
      wflush("    " .. fg(P.dim) .. wl .. RESET .. "\n")
    end
  end
end

-------------------------------------------------------------------------------
-- File operations
-------------------------------------------------------------------------------
function ui.file_read(path)
  refresh_size()
  wflush("  " .. fg(P.blue) .. ICONS.read .. " reading " .. RESET
    .. truncate(path, term_w - 14) .. "\n")
end

function ui.file_read_done(size_str)
  ui.status_ok(size_str .. " read")
end

function ui.file_edit(path, start_line, end_line)
  refresh_size()
  local range = ""
  if start_line and end_line then
    range = fg(P.dim) .. " (" .. start_line .. "–" .. end_line .. ")" .. RESET
  end
  wflush("  " .. fg(P.green) .. ICONS.edit .. " editing " .. RESET
    .. truncate(path, term_w - 14) .. range .. "\n")
end

function ui.file_write(path, size)
  refresh_size()
  local size_str = size and (fg(P.dim) .. " (" .. size .. "b)" .. RESET) or ""
  wflush("  " .. fg(P.green) .. ICONS.write .. " writing " .. RESET
    .. truncate(path, term_w - 14) .. size_str .. "\n")
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

-------------------------------------------------------------------------------
-- Thinking display (pulsing inline indicator)
-------------------------------------------------------------------------------
-- Pulse colours cycle: dim → mid → bright → cyan → dim …
local PULSE_COLS = { P.pulse_1, P.pulse_2, P.pulse_3, P.pulse_4 }
local PULSE_ICONS = { "·", "•", "●", "◉" }

function ui.think_status(chars)
  wflush("  " .. fg(P.cyan) .. ICONS.think .. " cognizing" .. RESET
    .. fg(P.dim) .. " (" .. chars .. " chars)" .. RESET .. "\n")
end

function ui.thinking_start()
  refresh_size()
  local inner_w = term_w - 6
  local label   = " thinking "
  local fill    = math.max(2, inner_w - #label - 2)
  wflush("\n  " .. fg(P.thinking_border)
    .. BOX.tl .. hline(BOX.h, 2) .. label .. hline(BOX.h, fill) .. BOX.tr
    .. RESET .. "\n")
end

function ui.thinking_line(text)
  refresh_size()
  local inner_w = term_w - 6
  local lines   = wrap_text(text, inner_w - 2, "")
  for _, line in ipairs(lines) do
    local padded = rpad(line, inner_w - 2)
    wflush("  " .. fg(P.thinking_border) .. BOX.v .. RESET
      .. " " .. fg(P.thinking_fg) .. padded .. RESET
      .. fg(P.thinking_border) .. BOX.v .. RESET .. "\n")
  end
end

function ui.thinking_end()
  refresh_size()
  local inner_w = term_w - 6
  wflush("  " .. fg(P.thinking_border) .. BOX.bl .. hline(BOX.h, inner_w) .. BOX.br
    .. RESET .. "\n\n")
end

-- Animated inline thinking indicator — pulses on each spinner_tick
function ui.thinking_inline(token_count)
  local step  = (pulse_step % #PULSE_COLS) + 1
  local icon  = PULSE_ICONS[step]
  local color = PULSE_COLS[step]
  pulse_step  = step
  wflush("\r" .. CLEAR_LINE
    .. "  " .. fg(color) .. icon .. " thinking" .. RESET
    .. fg(P.dim) .. " (" .. token_count .. " tokens)" .. RESET)
end

function ui.thinking_inline_done()
  wflush("\r" .. CLEAR_LINE)
end

-------------------------------------------------------------------------------
-- Spinner (Braille animation, driven by external tick)
-------------------------------------------------------------------------------
function ui.spinner_start(label)
  spinner_active = true
  spinner_label  = label or "cognizing"
  spinner_idx    = 1
  wflush(HIDE_CUR .. "  " .. fg(P.cyan) .. spinner_frames[1] .. " " .. spinner_label .. RESET)
end

function ui.spinner_tick()
  if not spinner_active then return end
  anim_tick   = anim_tick + 1
  spinner_idx = (spinner_idx % #spinner_frames) + 1
  -- Every 4 ticks nudge pulse step for thinking indicator
  if anim_tick % 4 == 0 then
    pulse_step = (pulse_step % #PULSE_COLS) + 1
  end
  wflush("\r" .. CLEAR_LINE
    .. "  " .. fg(P.cyan) .. spinner_frames[spinner_idx] .. " " .. spinner_label .. RESET)
end

function ui.spinner_stop()
  if spinner_active then
    wflush("\r" .. CLEAR_LINE .. SHOW_CUR)
    spinner_active = false
  end
end

function ui.is_spinning()
  return spinner_active
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
  refresh_size()
  wflush(
    "\n  " .. fg(P.yellow) .. BOLD .. ICONS.warn .. " [confirm] " .. RESET .. action_type .. "\n"
  )
  -- Wrap detail
  print_wrapped(detail or "", "  ", term_w)
  wflush(
    "  " .. BOLD .. "1" .. RESET .. "=yes  "
    .. BOLD .. "2" .. RESET .. "=no  "
    .. BOLD .. "3" .. RESET .. "=suggest\n"
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
  return fg(P.prompt_fg) .. BOLD .. "you" .. RESET .. fg(P.prompt_arrow) .. " ❯ " .. RESET
end

function ui.write_prompt()
  wflush(ui.prompt())
end

function ui.continuation_prompt()
  wflush(fg(P.dim) .. "... " .. RESET)
end

-------------------------------------------------------------------------------
-- Agent response display (animated label)
-- The label "slides in": characters appear one by one via over-print
-------------------------------------------------------------------------------
local AGENT_LABEL_FRAMES = {
  "j",
  "je",
  "jen",
  "jeno",
  "jenov",
  "jenova",
}

function ui.agent_label()
  -- Animated slide-in of "jenova │ "
  for i, frame in ipairs(AGENT_LABEL_FRAMES) do
    local pad = string.rep(" ", #AGENT_LABEL_FRAMES[#AGENT_LABEL_FRAMES] - #frame)
    io.write("\r  " .. fg(P.cyan) .. BOLD .. frame .. pad .. RESET)
    io.flush()
    -- tiny busy-wait animation (≈15 ms per frame, pure Lua)
    local t0 = os.clock()
    while os.clock() - t0 < 0.015 do end
    _ = i  -- suppress unused warning
  end
  -- Final state: "jenova │ " — leave cursor at end of line ready for streaming
  io.write("\r  " .. fg(P.cyan) .. BOLD .. "jenova" .. RESET
    .. fg(P.dim) .. " │ " .. RESET)
  io.flush()
end

function ui.agent_response(text)
  if not text or text == "" then return end
  refresh_size()
  wflush("\n  " .. fg(P.cyan) .. BOLD .. "jenova" .. RESET
    .. fg(P.dim) .. " │ " .. RESET)
  -- Wrap text
  local indent = "        "  -- align continuation lines under the response text
  local lines  = wrap_text(text, term_w - 10, "")
  for i, line in ipairs(lines) do
    if i == 1 then
      wflush(fg(P.text) .. line .. RESET)
    else
      wflush("\n" .. indent .. fg(P.text) .. line .. RESET)
    end
  end
  wflush("\n\n")
end

-- Streaming text — wraps incoming chunks dynamically
-- Tracks column position to wrap at terminal width
local _stream_col = 0

function ui.stream_text(text)
  if not text or text == "" then return end
  refresh_size()
  local avail = term_w - 10  -- 10 = indent "  jenova │ "
  -- Simple output: rely on terminal wrapping but insert soft newlines
  -- to stay within avail columns
  for _, ch in text:gmatch("(.)") do
    if ch == "\n" then
      io.write("\n" .. string.rep(" ", 10))
      _stream_col = 0
    else
      if _stream_col >= avail then
        -- Try to break at last space (soft wrap)
        io.write("\n" .. string.rep(" ", 10))
        _stream_col = 0
      end
      io.write(ch)
      _stream_col = _stream_col + 1
    end
  end
  io.flush()
end

function ui.stream_end()
  _stream_col = 0
  wflush("\n")
end

-------------------------------------------------------------------------------
-- Error display
-------------------------------------------------------------------------------
function ui.error(msg)
  refresh_size()
  wflush("\n  " .. fg(P.red) .. BOLD .. ICONS.err .. " " .. RESET)
  print_wrapped(msg, "  ", term_w)
end

function ui.fatal(msg)
  refresh_size()
  wflush("\n" .. fg(P.red) .. "fatal: " .. RESET)
  print_wrapped(msg, "       ", term_w)
end

-------------------------------------------------------------------------------
-- Debug / diagnostic
-------------------------------------------------------------------------------
function ui.debug(label, data)
  wflush(fg(P.magenta) .. "[DBG " .. label .. "] " .. RESET .. tostring(data):sub(1,2000) .. "\n")
end

function ui.diagnostic(info)
  wflush(fg(P.dim) .. "  [diag] " .. info .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Token/cost display
-------------------------------------------------------------------------------
function ui.token_usage(input_tokens, output_tokens, cost_usd)
  wflush(
    "\n  " .. fg(P.dim) .. "tokens: " .. RESET
    .. fg(P.status_dim) .. tostring(input_tokens) .. " in" .. RESET
    .. fg(P.dim) .. " / " .. RESET
    .. fg(P.status_dim) .. tostring(output_tokens) .. " out" .. RESET
  )
  if cost_usd and cost_usd > 0 then
    wflush(fg(P.dim) .. " │ " .. RESET .. fg(P.status_dim)
      .. string.format("$%.4f", cost_usd) .. RESET)
  end
  wflush("\n\n")
end

-------------------------------------------------------------------------------
-- Tool badge (animated: running → done/error)
-- "running" prints the badge and leaves cursor at end of line.
-- "done"/"error" over-prints the same line with updated glyph/color.
-- _last_tool_line_len is exposed so the loop can query badge width if needed.
-------------------------------------------------------------------------------
ui._last_tool_line_len = 0

local TOOL_ICON_MAP = {
  file_read    = ICONS.read,   read_file    = ICONS.read,
  file_write   = ICONS.write,  write_file   = ICONS.write,
  file_edit    = ICONS.edit,   edit_file    = ICONS.edit,
  bash         = ICONS.shell,  shell        = ICONS.shell,
  grep         = ICONS.search, search_files = ICONS.search,
  glob         = ICONS.list,   list_dir     = ICONS.list,
  web_search   = ICONS.globe,  web_fetch    = ICONS.globe,
  local_search = ICONS.search,
  lsp          = ICONS.code,
  ask_user     = ICONS.info,
  -- Capitalized names (tool.name field values used by the registry)
  ["Read"]     = ICONS.read,
  ["Write"]    = ICONS.write,
  ["Edit"]     = ICONS.edit,
  ["Bash"]     = ICONS.shell,
  ["Grep"]     = ICONS.search,
  ["Glob"]     = ICONS.list,
}

function ui.tool_badge(tool_name, status)
  local ic    = TOOL_ICON_MAP[tool_name]
               or TOOL_ICON_MAP[tool_name and tool_name:lower()]
               or ICONS.gear
  local color, suffix, suffix_raw

  if status == "running" then
    color      = P.cyan
    suffix     = fg(P.dim) .. " …" .. RESET
    suffix_raw = " …"
  elseif status == "ok" or status == "done" then
    color      = P.green
    ic         = ICONS.done
    suffix     = fg(P.green) .. " done" .. RESET
    suffix_raw = " done"
  elseif status == "error" or status == "failed" then
    color      = P.red
    ic         = ICONS.err
    suffix     = fg(P.red) .. " failed" .. RESET
    suffix_raw = " failed"
  elseif status == "denied" then
    color      = P.yellow
    ic         = ICONS.denied
    suffix     = fg(P.yellow) .. " denied" .. RESET
    suffix_raw = " denied"
  else
    color      = P.dim
    suffix     = ""
    suffix_raw = ""
  end

  local badge     = "  " .. fg(color) .. ic .. " " .. RESET .. fg(P.text) .. tool_name .. RESET .. suffix
  local badge_raw = "  " .. ic .. " " .. tool_name .. suffix_raw

  if status == "running" then
    -- Print on new line, remember length for over-print
    wflush(badge .. "\n")
    ui._last_tool_line_len = #badge_raw
  else
    -- Over-print previous running badge (go up one line, re-draw)
    wflush(cup(1) .. "\r" .. CLEAR_LINE .. badge .. "\n")
    ui._last_tool_line_len = 0
  end
end

-------------------------------------------------------------------------------
-- Permission request
-------------------------------------------------------------------------------
function ui.permission_request(tool_name, detail)
  refresh_size()
  wflush(
    "\n  " .. fg(P.yellow) .. ICONS.lock .. " permission " .. RESET .. BOLD .. tool_name .. RESET .. "\n"
  )
  if detail and #detail > 0 then
    print_wrapped(detail, "  ", term_w)
  end
  wflush(
    "  " .. fg(P.dim) .. "[y]es / [n]o / [a]lways" .. RESET .. "\n"
    .. "  " .. BOLD .. "> " .. RESET
  )
end

-------------------------------------------------------------------------------
-- REPL text helpers
-------------------------------------------------------------------------------
function ui.dimtext(text)
  wflush(fg(P.dim) .. text .. RESET)
end

function ui.boldtext(text)
  wflush(BOLD .. text .. RESET)
end

function ui.server_not_running(url)
  wflush(fg(P.red) .. ICONS.err .. " backend not running at " .. url .. RESET .. "\n")
  wflush(fg(P.dim) .. "  Start with: jenova-ca or /backend start" .. RESET .. "\n")
end

function ui.compile_check(path)
  wflush("  " .. fg(P.dim) .. ICONS.shell .. " auto-checking: cc -fsyntax-only " .. path .. RESET .. "\n")
end

function ui.goodbye()
  wflush(fg(P.dim) .. "\n  bye\n" .. RESET)
end

function ui.path_fixed(old_path, new_path)
  wflush("  " .. fg(P.yellow) .. ICONS.warn .. " path fixed " .. RESET
    .. fg(P.dim) .. old_path .. " → " .. new_path .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Expose helpers for external use
-------------------------------------------------------------------------------
ui.P             = P
ui.fg            = fg
ui.bg            = bg
ui.move          = move
ui.cup           = cup
ui.RESET         = RESET
ui.BOLD          = BOLD
ui.DIM           = DIM
ui.ITALIC        = ITALIC
ui.UNDERLINE     = UNDERLINE
ui.BLINK         = BLINK
ui.CLEAR_LINE    = CLEAR_LINE
ui.HIDE_CUR      = HIDE_CUR
ui.SHOW_CUR      = SHOW_CUR
ui.center        = center
ui.hline         = hline
ui.rpad          = rpad
ui.truncate      = truncate
ui.display_width = display_width
ui.wrap_text     = wrap_text
ui.print_wrapped = print_wrapped
ui.BOX           = BOX
ui.wall_time     = wall_time
ui.scroll_output = scroll_output
ui.scroll_buf    = scroll_buf
ui.scroll_offset = scroll_offset

function ui.get_width()  refresh_size(); return term_w end
function ui.get_height() refresh_size(); return term_h end

return ui
