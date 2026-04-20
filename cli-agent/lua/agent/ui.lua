-- agent/ui.lua: Polished terminal UI for Jenova CLI Agent
-- Pure ANSI escape sequences — no ncurses dependency, works on any terminal.
-- Provides: header with ASCII art, structured output regions, status bar,
--           styled input prompt, scrollback buffer, terminal resize handling.
--
-- Restored from the legacy-agent UI system with adaptations for Lua 5.4
-- (no LuaJIT FFI dependency). Uses io.popen/os.clock fallbacks.

local ui = {}

-------------------------------------------------------------------------------
-- ANSI escape helpers
-------------------------------------------------------------------------------
local ESC = "\27"
local CSI = ESC .. "["

local function esc(code)      return CSI .. code end
local function fg(n)          return CSI .. "38;5;" .. n .. "m" end
local function bg(n)          return CSI .. "48;5;" .. n .. "m" end

local RESET      = esc("0m")
local BOLD       = esc("1m")
local DIM        = esc("2m")
local ITALIC     = esc("3m")
local UNDERLINE  = esc("4m")
local CLEAR_LINE = esc("2K")

-------------------------------------------------------------------------------
-- Color palette — cool, professional tones
-------------------------------------------------------------------------------
local P = {
  header_bg     = 234,
  header_fg     = 51,
  header_accent = 33,
  header_dim    = 240,
  title_fg      = 45,
  border        = 238,
  border_light  = 242,
  status_bg     = 235,
  status_fg     = 252,
  status_dim    = 241,
  prompt_fg     = 51,
  prompt_arrow  = 33,
  text          = 254,
  dim           = 242,
  green         = 48,
  red           = 196,
  yellow        = 226,
  cyan          = 51,
  magenta       = 171,
  blue          = 33,
  orange        = 208,
  white         = 255,
  thinking_fg   = 243,
  thinking_border = 240,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local term_w = 80
local term_h = 24
local header_lines = 0
local spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local spinner_idx = 0
local spinner_label = ""
local spinner_active = false

-- Cached terminal size with expiry
local _cached_width = nil
local _cached_height = nil
local _cached_time = 0

-------------------------------------------------------------------------------
-- Terminal size detection (Lua 5.4 compatible)
-------------------------------------------------------------------------------
local function get_term_size()
  local now = os.time()
  if _cached_width and (now - _cached_time) < 3 then
    return _cached_width, _cached_height
  end

  local c, r = 80, 24

  -- Try stty first (works on FreeBSD and most POSIX)
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

  -- Fallback to tput
  if c == 80 then
    local tp = io.popen("tput cols 2>/dev/null")
    if tp then
      local val = tp:read("*l")
      tp:close()
      if val then c = tonumber(val) or 80 end
    end
  end
  if r == 24 then
    local tp = io.popen("tput lines 2>/dev/null")
    if tp then
      local val = tp:read("*l")
      tp:close()
      if val then r = tonumber(val) or 24 end
    end
  end

  _cached_width = c
  _cached_height = r
  _cached_time = now
  return c, r
end

local function refresh_size()
  term_w, term_h = get_term_size()
  if term_w < 40 then term_w = 40 end
  if term_h < 10 then term_h = 10 end
end

-------------------------------------------------------------------------------
-- High-resolution time (Lua 5.4 os.clock or jenova.system)
-------------------------------------------------------------------------------
local function wall_time()
  return os.clock()
end

-------------------------------------------------------------------------------
-- Low-level write (buffered for flicker-free rendering)
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
  hl = "━",
  vl = "┃",
  dt = "╌",
}

local function hline(char, width)
  return string.rep(char, width)
end

local function display_width(text)
  local raw = text:gsub("\27%[[%d;]*m", "")
  local dw = 0
  local i = 1
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
      -- Full-width CJK detection
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
      ) then
        dw = dw + 2
      else
        dw = dw + 1
      end
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
  if term_w < 60 then
    art = nil
  end

  -- Top border
  w(fg(P.border) .. BOX.tl .. hline(BOX.h, inner_w) .. BOX.tr .. RESET .. "\n")
  header_lines = header_lines + 1

  -- Blank line
  w(blank_row(inner_w))
  header_lines = header_lines + 1

  -- ASCII art or fallback
  if art then
    for _, line in ipairs(art) do
      w(header_row(inner_w, fg(P.header_fg) .. BOLD .. line .. RESET))
      header_lines = header_lines + 1
    end
  elseif term_w >= 30 then
    for _, line in ipairs(HEADER_SMALL) do
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
  w(header_row(inner_w, fg(P.header_accent) .. "Cognitive Architecture" .. RESET))
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

  local parts = {}
  if opts.cwd then
    parts[#parts + 1] = fg(P.dim) .. "  ◈ " .. RESET .. fg(P.text) .. opts.cwd .. RESET
  end

  -- Second line: connection + stats
  local stats = {}
  if opts.api_url then stats[#stats + 1] = fg(P.dim) .. "⚡ " .. RESET .. fg(P.status_dim) .. opts.api_url .. RESET end
  if opts.provider then stats[#stats + 1] = fg(P.cyan) .. "◉ " .. RESET .. fg(P.status_dim) .. opts.provider .. RESET end
  if opts.model then stats[#stats + 1] = fg(P.green) .. "◎ " .. RESET .. fg(P.status_dim) .. opts.model .. RESET end
  if opts.indexed then stats[#stats + 1] = fg(P.green) .. "◉ " .. RESET .. fg(P.status_dim) .. opts.indexed .. " files" .. RESET end
  if opts.indexing then stats[#stats + 1] = fg(P.yellow) .. "◌ " .. RESET .. fg(P.status_dim) .. "indexing..." .. RESET end
  if opts.tools then stats[#stats + 1] = fg(P.blue) .. "⚙ " .. RESET .. fg(P.status_dim) .. opts.tools .. " tools" .. RESET end
  if opts.turns then stats[#stats + 1] = fg(P.dim) .. "turns:" .. opts.turns .. RESET end
  if opts.session then stats[#stats + 1] = fg(P.dim) .. "sid:" .. opts.session:sub(1, 8) .. RESET end

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
-- Status messages
-------------------------------------------------------------------------------
local ICONS = {
  think   = "◐", read   = "◉", write  = "◈", edit    = "◇",
  shell   = "⚡", search = "◎", list   = "◇", ok      = "✓",
  err     = "✗", warn   = "⚠", turn   = "→", nudge   = "↻",
  backup  = "◆", info   = "●", bolt   = "⚡", gear    = "⚙",
  dot     = "•", lock   = "◈", globe  = "◎", code    = "◇",
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
-- Turn indicator (per-tool icon + turn counter)
-------------------------------------------------------------------------------
function ui.status_turn(turn_num, max_turns, tool_name)
  local icon_map = {
    read_file    = ICONS.read,   file_read  = ICONS.read,
    write_file   = ICONS.write,  file_write = ICONS.write,
    shell        = ICONS.shell,  bash       = ICONS.shell,
    search_files = ICONS.search, grep       = ICONS.search,
    list_dir     = ICONS.list,   glob       = ICONS.list,
    edit_file    = ICONS.edit,   file_edit  = ICONS.edit,
    think        = ICONS.think,
    web_search   = ICONS.globe,  web_fetch  = ICONS.globe,
    lsp          = ICONS.code,
    local_search = ICONS.search,
  }
  local ic = icon_map[tool_name] or ICONS.turn
  local max_str = max_turns and ("/" .. max_turns) or ""
  wflush(
    "  " .. fg(P.yellow) .. ICONS.turn .. " " .. RESET
    .. fg(P.dim) .. "[" .. turn_num .. max_str .. "] " .. RESET
    .. fg(P.cyan) .. BOLD .. ic .. " " .. (tool_name or "turn") .. RESET .. "\n"
  )
end

-------------------------------------------------------------------------------
-- Shell output display
-------------------------------------------------------------------------------
function ui.shell_cmd(cmd)
  wflush("  " .. fg(P.dim) .. ICONS.shell .. " $ " .. RESET .. fg(P.text) .. cmd .. RESET .. "\n")
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
  local lines = {}
  for line in output:gmatch("[^\n]+") do
    lines[#lines + 1] = line
    if #lines >= max_lines then
      lines[#lines + 1] = "... (truncated)"
      break
    end
  end
  for _, line in ipairs(lines) do
    wflush("  " .. fg(P.dim) .. "  " .. line .. RESET .. "\n")
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

function ui.file_edit(path, start_line, end_line)
  local range = ""
  if start_line and end_line then
    range = fg(P.dim) .. " (lines " .. start_line .. "-" .. end_line .. ")" .. RESET
  end
  wflush(
    "  " .. fg(P.green) .. ICONS.edit .. " editing " .. RESET .. path .. range .. "\n"
  )
end

function ui.file_write(path, size)
  local size_str = ""
  if size then size_str = fg(P.dim) .. " (" .. size .. "b)" .. RESET end
  wflush("  " .. fg(P.green) .. ICONS.write .. " writing " .. RESET .. path .. size_str .. "\n")
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
-- Thinking display
-------------------------------------------------------------------------------
function ui.think_status(chars)
  wflush("  " .. fg(P.cyan) .. ICONS.think .. " cognizing" .. RESET .. fg(P.dim) .. " (" .. chars .. " chars)" .. RESET .. "\n")
end

-- Thinking panel: bordered box for extended thinking output
function ui.thinking_start()
  local inner_w = term_w - 6
  wflush("\n  " .. fg(P.thinking_border) .. BOX.tl .. hline(BOX.h, 2) .. " thinking " .. hline(BOX.h, inner_w - 12) .. BOX.tr .. RESET .. "\n")
end

function ui.thinking_line(text)
  local inner_w = term_w - 6
  -- Wrap long lines
  local lines = {}
  if #text > inner_w - 2 then
    local pos = 1
    while pos <= #text do
      lines[#lines + 1] = text:sub(pos, pos + inner_w - 3)
      pos = pos + inner_w - 2
    end
  else
    lines[1] = text
  end
  for _, line in ipairs(lines) do
    local padded = line .. string.rep(" ", math.max(0, inner_w - 2 - #line))
    wflush("  " .. fg(P.thinking_border) .. BOX.v .. RESET .. " " .. fg(P.thinking_fg) .. padded .. RESET .. fg(P.thinking_border) .. BOX.v .. RESET .. "\n")
  end
end

function ui.thinking_end()
  local inner_w = term_w - 6
  wflush("  " .. fg(P.thinking_border) .. BOX.bl .. hline(BOX.h, inner_w) .. BOX.br .. RESET .. "\n\n")
end

-- Compact thinking indicator (single line, self-replacing)
function ui.thinking_inline(token_count)
  wflush("\r" .. CLEAR_LINE .. "  " .. fg(P.cyan) .. ICONS.think .. " thinking" .. RESET .. fg(P.dim) .. " (" .. token_count .. " tokens)" .. RESET)
end

function ui.thinking_inline_done()
  wflush("\r" .. CLEAR_LINE)
end

-------------------------------------------------------------------------------
-- Spinner (Braille animation)
-------------------------------------------------------------------------------
function ui.spinner_start(label)
  spinner_active = true
  spinner_label = label or "cognizing"
  spinner_idx = 1
  wflush("  " .. fg(P.cyan) .. spinner_frames[1] .. " " .. spinner_label .. RESET)
end

function ui.spinner_tick()
  if not spinner_active then return end
  spinner_idx = (spinner_idx % #spinner_frames) + 1
  wflush("\r" .. CLEAR_LINE .. "  " .. fg(P.cyan) .. spinner_frames[spinner_idx] .. " " .. spinner_label .. RESET)
end

function ui.spinner_stop()
  if spinner_active then
    wflush("\r" .. CLEAR_LINE)
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
  return fg(P.prompt_fg) .. BOLD .. "you" .. RESET .. fg(P.prompt_arrow) .. " ❯ " .. RESET
end

function ui.write_prompt()
  wflush(ui.prompt())
end

function ui.continuation_prompt()
  wflush(fg(P.dim) .. "... " .. RESET)
end

-------------------------------------------------------------------------------
-- Agent response display
-------------------------------------------------------------------------------
function ui.agent_label()
  wflush("\n  " .. fg(P.cyan) .. BOLD .. "jenova" .. RESET .. fg(P.dim) .. " │ " .. RESET)
end

function ui.agent_response(text)
  if not text or text == "" then return end
  wflush(
    "\n  " .. fg(P.cyan) .. BOLD .. "jenova" .. RESET .. fg(P.dim) .. " │ " .. RESET .. text .. "\n\n"
  )
end

-- Streaming text output (no prefix, called per-chunk)
function ui.stream_text(text)
  wflush(text)
end

-- End streaming response with newline
function ui.stream_end()
  wflush("\n\n")
end

-------------------------------------------------------------------------------
-- Error display
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
-- Diagnostic line
-------------------------------------------------------------------------------
function ui.diagnostic(info)
  wflush(fg(P.dim) .. "  [diag] " .. info .. RESET .. "\n")
end

-------------------------------------------------------------------------------
-- Token/cost display
-------------------------------------------------------------------------------
function ui.token_usage(input_tokens, output_tokens, cost_usd)
  wflush(
    "  " .. fg(P.dim) .. "tokens: " .. RESET
    .. fg(P.status_dim) .. tostring(input_tokens) .. " in" .. RESET
    .. fg(P.dim) .. " / " .. RESET
    .. fg(P.status_dim) .. tostring(output_tokens) .. " out" .. RESET
  )
  if cost_usd and cost_usd > 0 then
    wflush(fg(P.dim) .. " │ " .. RESET .. fg(P.status_dim) .. string.format("$%.4f", cost_usd) .. RESET)
  end
  wflush("\n")
end

-------------------------------------------------------------------------------
-- Tool use badge (for streaming display)
-------------------------------------------------------------------------------
function ui.tool_badge(tool_name, status)
  local icon_map = {
    file_read  = ICONS.read,   read_file    = ICONS.read,
    file_write = ICONS.write,  write_file   = ICONS.write,
    file_edit  = ICONS.edit,   edit_file    = ICONS.edit,
    bash       = ICONS.shell,  shell        = ICONS.shell,
    grep       = ICONS.search, search_files = ICONS.search,
    glob       = ICONS.list,   list_dir     = ICONS.list,
    web_search = ICONS.globe,  web_fetch    = ICONS.globe,
    local_search = ICONS.search,
    lsp        = ICONS.code,
    ask_user   = ICONS.info,
  }
  local ic = icon_map[tool_name] or ICONS.gear

  local color = P.cyan
  local suffix = ""
  if status == "ok" or status == "done" then
    color = P.green
    suffix = fg(P.dim) .. " done" .. RESET
  elseif status == "error" or status == "failed" then
    color = P.red
    suffix = fg(P.red) .. " failed" .. RESET
  elseif status == "running" then
    suffix = fg(P.dim) .. " ..." .. RESET
  elseif status == "denied" then
    color = P.yellow
    suffix = fg(P.yellow) .. " denied" .. RESET
  end

  wflush("  " .. fg(color) .. ic .. " " .. RESET .. fg(P.text) .. tool_name .. RESET .. suffix .. "\n")
end

-------------------------------------------------------------------------------
-- Permission request display
-------------------------------------------------------------------------------
function ui.permission_request(tool_name, detail)
  wflush(
    "\n  " .. fg(P.yellow) .. ICONS.lock .. " permission " .. RESET .. BOLD .. tool_name .. RESET .. "\n"
    .. "  " .. fg(P.dim) .. (detail or "") .. RESET .. "\n"
    .. "  " .. fg(P.dim) .. "[y]es / [n]o / [a]lways" .. RESET .. "\n"
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

-------------------------------------------------------------------------------
-- Compile check
-------------------------------------------------------------------------------
function ui.compile_check(path)
  wflush("  " .. fg(P.dim) .. ICONS.shell .. " auto-checking: cc -fsyntax-only " .. path .. RESET .. "\n")
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
ui.ITALIC = ITALIC
ui.UNDERLINE = UNDERLINE
ui.CLEAR_LINE = CLEAR_LINE
ui.center = center
ui.hline = hline
ui.rpad = rpad
ui.truncate = truncate
ui.display_width = display_width
ui.BOX = BOX
ui.wall_time = wall_time

function ui.get_width()
  refresh_size()
  return term_w
end

function ui.get_height()
  refresh_size()
  return term_h
end

return ui
