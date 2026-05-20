-- ##Module purpose: Native built-in jvim dashboard / home screen.
--
-- This consolidates the legacy nvi-style intro (logo, version, attribution,
-- help hints) and the former alpha-nvim "IDE dashboard" (quick actions, AI,
-- git, diagnostics, config, backend status, navigation controls) into a
-- single home screen that ships with the jvim runtime — no third-party
-- plugin manager required.
--
-- Activation is handled by runtime/plugin/jvim_dashboard.lua, which opens
-- the dashboard at startup when jvim is launched without file arguments.

local M = {}

local AUGROUP = "JvimDashboard"
local FILETYPE = "jvimdashboard"
local NS = vim.api.nvim_create_namespace("jvim.dashboard")

-- ##Section purpose: Per-instance state. Only one dashboard buffer exists at a time.
local state = {
  buf = nil,
  win = nil,
  actions = {}, -- map of single-character key -> action descriptor
  -- Saved window-local options keyed by window id, so multiple windows can
  -- display the dashboard concurrently and each gets its own original options
  -- restored on BufWinLeave / BufWipeout. Treated as an always-present table.
  prev_wo = {},
}

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PROXY_PORT = 8080
local DEFAULT_LLAMA_PORT = 8081
local DEFAULT_EMBED_PORT = 8082

-- ##Function purpose: Detect host operating system in human form for the header.
-- Cached after the first call so VimResized/WinResized re-renders don't spawn
-- synchronous `uname -r` / `sw_vers` processes on every redraw. For FreeBSD and
-- Darwin we read the kernel release from `vim.uv.os_uname()` instead of
-- spawning external processes — that field is already populated by libuv. On
-- Darwin we additionally kick off an async `sw_vers -productVersion` probe to
-- upgrade the cached string from the kernel version (e.g. "23.4.0") to the
-- macOS marketing version (e.g. "14.4.1") without blocking startup.
local _os_info_cache = nil
local _os_macver_probed = false

local function _maybe_probe_macos_version()
  -- vim.system is only available on Neovim 0.10+. On older versions we keep
  -- the libuv kernel release (already cached in _os_info_cache) — that is the
  -- best we can do without spawning a synchronous external process.
  if _os_macver_probed then return end
  if vim.fn.has("nvim-0.10") ~= 1 or not vim.system then return end
  _os_macver_probed = true
  vim.system({ "sw_vers", "-productVersion" }, { text = true, timeout = 2000 }, function(obj)
    if not (obj and obj.code == 0 and obj.stdout) then return end
    local ver = (obj.stdout:match("^%s*(.-)%s*$")) or ""
    if ver == "" then return end
    vim.schedule(function()
      _os_info_cache = "macOS " .. ver
      if M and M.is_open and M.is_open() then
        pcall(M.redraw)
      end
    end)
  end)
end

local function detect_os()
  if _os_info_cache then return _os_info_cache end
  local uv = vim.uv or vim.loop
  local uname = (uv and uv.os_uname and uv.os_uname()) or {}
  local sysname = uname.sysname or "Unknown"
  local release = ""
  if sysname == "FreeBSD" then
    if uname.release and uname.release ~= "" then
      release = " " .. uname.release
    end
  elseif sysname == "Darwin" then
    if uname.release and uname.release ~= "" then
      release = " " .. uname.release
    end
    _maybe_probe_macos_version()
  elseif sysname == "Linux" then
    local ok, lines = pcall(vim.fn.readfile, "/etc/os-release")
    if ok then
      for _, line in ipairs(lines) do
        local name = line:match('^PRETTY_NAME="(.-)"')
        if name then
          release = " (" .. name .. ")"
          break
        end
      end
    end
  end
  _os_info_cache = sysname .. release
  return _os_info_cache
end

-- ##Function purpose: Resolve Jenova backend endpoint configuration with graceful
-- fallback when the optional jenova.monitor module is not present.
local function backend_endpoints()
  local ok, monitor = pcall(require, "jenova.monitor")
  if ok and monitor and monitor.get_endpoints then
    local ep = monitor.get_endpoints() or {}
    return {
      host = ep.host or DEFAULT_HOST,
      proxy_port = ep.proxy_port or DEFAULT_PROXY_PORT,
      llama_port = ep.llama_port or DEFAULT_LLAMA_PORT,
      embed_port = ep.embed_port or DEFAULT_EMBED_PORT,
    }
  end
  local host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or DEFAULT_HOST
  if host == "0.0.0.0" or host == "::" or host == "*" then host = DEFAULT_HOST end
  -- Honour the same env-var precedence as jenova.monitor / jenova.endpoints so
  -- the dashboard reports identical ports whether or not the monitor module
  -- has been loaded.
  return {
    host = host,
    proxy_port = tonumber(vim.env.JENOVA_PORT or "") or DEFAULT_PROXY_PORT,
    llama_port = tonumber(vim.env.JENOVA_LLAMA_PORT or "") or DEFAULT_LLAMA_PORT,
    embed_port = tonumber(vim.env.JENOVA_LLAMA_EMBED_PORT or vim.env.LLAMA_EMBED_PORT or "")
      or DEFAULT_EMBED_PORT,
  }
end

-- ##Function purpose: Centre a single line in `width` columns. Uses display width
-- so multi-byte glyphs (logo block characters) align correctly.
local function center(line, width)
  local w = vim.fn.strdisplaywidth(line)
  if w >= width then return line end
  return string.rep(" ", math.floor((width - w) / 2)) .. line
end

-- ##Function purpose: Pad a string to exactly `width` display columns on the
-- right with spaces. Used to align horizontal grids (multi-column sections,
-- controls grid) so nothing wraps when the terminal is wide enough.
local function pad_right(line, width)
  local w = vim.fn.strdisplaywidth(line)
  if w >= width then return line end
  return line .. string.rep(" ", width - w)
end

-- ##Function purpose: Render one section (title + items) into a list of lines
-- of fixed `col_width`. Returns the lines plus a list of {row_offset, key,
-- action} so the caller can attach extmarks/keymaps after composition.
local function render_section_block(sec, col_width)
  local lines = {}
  local meta = {}
  lines[#lines + 1] = pad_right("── " .. sec.title .. " ──", col_width)
  lines[#lines + 1] = ""
  for _, it in ipairs(sec.items) do
    local label
    if it.key then
      label = string.format("  [%s]  %s  %s", it.key, it.icon, it.label)
    else
      label = string.format("        %s  %s", it.icon, it.label)
    end
    lines[#lines + 1] = pad_right(label, col_width)
    if it.key then
      meta[#meta + 1] = { row = #lines, key = it.key, action = it.action }
    end
  end
  return lines, meta
end

-- ##Function purpose: Build the layout. Returns a list of row descriptors
-- (text + highlight kind + optional action key) and a key->action map. The
-- layout is a fixed-width "page" composed of:
--   1. JENOVA block ASCII banner (top)
--   2. Title / subtitle / attribution / OS info
--   3. Three-column grid of action sections (Quick Actions, AI/Jenova, Git,
--      Diagnostics, Config, Backend Status) — falls back to 2 / 1 column on
--      narrow terminals so nothing wraps.
--   4. Horizontal multi-column controls cheat-sheet
--   5. nvi-style JVIM small logo + legacy `:help / :checkhealth / :q` hints
local function build_layout(width)
  local v = vim.version()
  local jvim_version = string.format("JVIM v%d.%d.%d", v.major, v.minor, v.patch)
  local os_info = detect_os()
  local ep = backend_endpoints()

  -- ##Subsection: JENOVA block banner (centred, the "beautiful" header)
  local jenova_logo = {
    "       ██╗███████╗███╗   ██╗ ██████╗ ██╗   ██╗ █████╗  ",
    "       ██║██╔════╝████╗  ██║██╔═══██╗██║   ██║██╔══██╗ ",
    "       ██║█████╗  ██╔██╗ ██║██║   ██║██║   ██║███████║ ",
    "  ██   ██║██╔══╝  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║ ",
    "  ╚█████╔╝███████╗██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║ ",
    "   ╚════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝ ",
  }

  -- ##Subsection: nvi-style JVIM small logo (footer; preserves the historical
  -- intro_message ASCII so the legacy home screen identity is retained).
  local jvim_logo = {
    "       _ __   __ ___  __  __ ",
    "      | |\\ \\ / /|_ _||  \\/  |",
    "   _  | | \\ V /  | | | |\\/| |",
    "  | |_| |  | |   | | | |  | |",
    "   \\___/   |_|  |___||_|  |_|",
  }

  local rows = {}
  local function push(kind, text, opts)
    rows[#rows + 1] = vim.tbl_extend("force",
      { kind = kind, text = text or "" }, opts or {})
  end

  -- ##Subsection: Header (logo + identity + attribution)
  push("pad", "")
  for _, l in ipairs(jenova_logo) do push("logo", center(l, width)) end
  push("pad", "")
  push("title", center(jvim_version .. "  •  Cognitive Architecture Frontend", width))
  push("attr", center(os_info .. "  •  Unified Interface for the Jenova Cognitive Architecture", width))
  push("attr", center("https://github.com/orpheus497/jenova", width))

  local sep_w = math.min(width - 2, 100)
  local sep = string.rep("─", sep_w)
  push("pad", "")
  push("sep", center(sep, width))
  push("pad", "")

  -- ##Subsection: Action sections (rendered as side-by-side blocks)
  local sec_quick = {
    title = "Quick Actions",
    items = {
      { key = "e", icon = "", label = "New File",         action = "new_file" },
      { key = "f", icon = "", label = "Find File",        action = "find_files" },
      { key = "r", icon = "", label = "Recent Files",     action = "recent_files" },
      { key = "g", icon = "", label = "Live Grep",        action = "live_grep" },
      { key = "b", icon = "", label = "Buffers",          action = "buffers" },
      { key = "T", icon = "", label = "Toggle Terminal",  action = "terminal" },
      { key = "i", icon = "", label = "Open IDE Panels", action = "ide" },
    },
  }
  -- FIM state label: read from vim.g to reflect runtime state
  local fim_on = vim.g.jenova_fim_enabled
  -- Default to checking llama_config if the global hasn't been set yet
  if fim_on == nil then
    local cfg = vim.g.llama_config
    fim_on = cfg and cfg.auto_fim
  end
  local fim_label = fim_on and "FIM Auto [ON]" or "FIM Auto [OFF]"

  local sec_ai = {
    title = "Jenova AI",
    items = {
      { key = "c", icon = "", label = "Chat w/ Context",   action = "ai_chat_context" },
      { key = "t", icon = "", label = "Toggle Chat",        action = "ai_toggle" },
      { key = "n", icon = "", label = "Fresh Chat",         action = "ai_fresh_chat" },
      { key = "s", icon = "", label = "Web Search",         action = "ai_web_search" },
      { key = "A", icon = "", label = fim_label,            action = "toggle_fim" },
      { key = "M", icon = "", label = "Backend Monitor",    action = "monitor" },
    },
  }
  local sec_git = {
    title = "Git",
    items = {
      { key = "G", icon = "", label = "Neogit Status", action = "neogit" },
      { key = "D", icon = "", label = "Diff View",     action = "diffview" },
      { key = "F", icon = "", label = "Fugitive",      action = "fugitive" },
    },
  }
  local sec_diag = {
    title = "Diagnostics & LSP",
    items = {
      { key = "x", icon = "", label = "Workspace Diagnostics", action = "trouble_diag" },
      { key = "S", icon = "", label = "Symbols",                action = "trouble_sym" },
      { key = "R", icon = "", label = "LSP Defs / Refs",        action = "trouble_lsp" },
    },
  }
  local sec_config = {
    title = "Config",
    items = {
      { key = "h", icon = "", label = "Health Check", action = "checkhealth" },
      { key = "q", icon = "", label = "Quit",         action = "quit" },
      },
  }

  -- ##Subsection: Backend status rendered as its own pseudo-section so it can
  -- sit alongside the other blocks in the grid.
  local sec_backend = {
    title = "Backend Status",
    items = {
      { key = nil, icon = " ", label = string.format("Proxy  : %d", ep.proxy_port) },
      { key = nil, icon = " ", label = string.format("Llama  : %d", ep.llama_port) },
      { key = nil, icon = " ", label = string.format("Embed  : %d", ep.embed_port) },
      { key = nil, icon = " ", label = "Host   : " .. ep.host },
      { key = nil, icon = " ", label = "Profile: " .. (M._profile or "detecting...") },
    },
  }

  -- ##Subsection: Choose column count based on terminal width. Each column is
  -- COL_WIDTH wide and sections flow column-major into the chosen number of
  -- columns. This keeps the dashboard square — both axes used.
  local COL_WIDTH = 30
  local GAP = 4
  local function fits(n) return n * COL_WIDTH + (n - 1) * GAP + 4 <= width end
  local n_cols = fits(3) and 3 or (fits(2) and 2 or 1)

  local section_order
  if n_cols == 3 then
    section_order = {
      { sec_quick, sec_diag },
      { sec_ai,    sec_config },
      { sec_git,   sec_backend },
    }
  elseif n_cols == 2 then
    section_order = {
      { sec_quick, sec_git,    sec_config },
      { sec_ai,    sec_diag,   sec_backend },
    }
  else
    section_order = {
      { sec_quick, sec_ai, sec_git, sec_diag, sec_config, sec_backend },
    }
  end

  -- ##Step purpose: For each column, vertically stack its sections (with one
  -- blank line between sections) into a single block of lines. Collect the
  -- action key -> action-name map while we are already iterating the sections.
  local actions = {}
  local col_blocks = {}            -- list of {lines = {...}, kinds = {...}}

  for _, sections_in_col in ipairs(section_order) do
    local lines, kinds = {}, {}
    for s_idx, sec in ipairs(sections_in_col) do
      if s_idx > 1 then
        lines[#lines + 1] = pad_right("", COL_WIDTH)
        kinds[#kinds + 1] = "pad"
      end
      local sec_lines, sec_meta = render_section_block(sec, COL_WIDTH)
      for li, line in ipairs(sec_lines) do
        lines[#lines + 1] = line
        if li == 1 then
          kinds[#kinds + 1] = "section"
        elseif sec.title == "Backend Status" then
          kinds[#kinds + 1] = "status"
        else
          kinds[#kinds + 1] = "action"
        end
      end
      for _, m in ipairs(sec_meta) do
        if m.key then actions[m.key] = m.action end
      end
    end
    col_blocks[#col_blocks + 1] = { lines = lines, kinds = kinds }
  end

  -- ##Step purpose: Compose columns side-by-side, then center the whole grid
  -- inside the dashboard width. Rather than stamping a single highlight group
  -- on the whole merged row (which would let a section header in one column
  -- bleed onto an action label in another), we emit one extmark *per column*
  -- using byte offsets we compute as we build the line. This requires building
  -- the merged line ourselves so the offsets stay in sync.
  local block_width = #col_blocks * COL_WIDTH + (#col_blocks - 1) * GAP
  local margin = math.max(0, math.floor((width - block_width) / 2))
  local margin_str = string.rep(" ", margin)
  local margin_bytes = #margin_str
  local gap_str = string.rep(" ", GAP)

  local block_height = 0
  for _, cb in ipairs(col_blocks) do
    if #cb.lines > block_height then block_height = #cb.lines end
  end

  for i = 1, block_height do
    local parts, spans = {}, {}
    local offset = margin_bytes
    for c, cb in ipairs(col_blocks) do
      local raw = cb.lines[i] or ""
      local kind = cb.kinds[i] or "pad"
      local padded = pad_right(raw, COL_WIDTH)
      parts[c] = padded
      local span_bytes = #padded
      if kind ~= "pad" then
        spans[#spans + 1] = {
          kind = kind, start_col = offset, end_col = offset + span_bytes,
        }
      end
      offset = offset + span_bytes
      if c < #col_blocks then offset = offset + GAP end
    end
    push("pad", margin_str .. table.concat(parts, gap_str), { spans = spans })
  end

  push("pad", "")
  push("sep", center(sep, width))
  push("pad", "")

  -- ##Subsection: Controls cheat-sheet rendered as a horizontal grid so the
  -- whole dashboard fits on one screen on a normal-sized terminal.
  local controls_entries = {
    "SPC w   Save",         "SPC q   Quit",         "Ctrl-h/j/k/l Window Nav", "[d / ]d  Prev/Next Diag",
    "SPC e   File Tree",    "SPC f f Find File",    "SPC t t Toggle Term",     "[h / ]h  Prev/Next Hunk",
    "SPC f g Live Grep",    "SPC f b Buffers",      "SPC t n New Term",        "gd       Definition",
    "SPC t j Jenova Term",  "Esc Esc Leave Term",   "Shift-H/L Prev/Next Buf", "K        Hover Docs",
    "SPC c a Code Action",  "SPC r n Rename",       "SPC c d Diag Float",      "SPC c f  Format",
    "SPC a M Jenova Mon",   "SPC a h Health",       "SPC a l LAN Scan",        "SPC a f  FIM Toggle",
  }
  local CTL_COL_W = 26
  local CTL_GAP = 2
  local n_ctl_cols
  if 4 * CTL_COL_W + 3 * CTL_GAP + 4 <= width then
    n_ctl_cols = 4
  elseif 2 * CTL_COL_W + CTL_GAP + 4 <= width then
    n_ctl_cols = 2
  else
    n_ctl_cols = 1
  end
  push("section", center("── Navigation & Controls ──", width))
  push("pad", "")
  local ctl_block_w = n_ctl_cols * CTL_COL_W + (n_ctl_cols - 1) * CTL_GAP
  local ctl_margin = string.rep(" ", math.max(0, math.floor((width - ctl_block_w) / 2)))
  local ctl_gap_str = string.rep(" ", CTL_GAP)
  for i = 1, #controls_entries, n_ctl_cols do
    local parts = {}
    for c = 0, n_ctl_cols - 1 do
      parts[#parts + 1] = pad_right(controls_entries[i + c] or "", CTL_COL_W)
    end
    push("controls", ctl_margin .. table.concat(parts, ctl_gap_str))
  end

  push("pad", "")
  push("sep", center(sep, width))
  push("pad", "")

  -- ##Subsection: Footer — small nvi-style JVIM logo + legacy command hints.
  for _, l in ipairs(jvim_logo) do push("jvim_logo", center(l, width)) end
  push("pad", "")
  local hint_line = string.format(
    ":help jvim    :checkhealth    :q    :help news (v%d.%d)",
    v.major, v.minor)
  push("hint", center(hint_line, width))
  push("pad", "")
  push("footer", center(M._footer or "", width))

  return rows, actions
end

-- ##Function purpose: Map row.kind to a highlight group. Groups are linked at
-- buffer creation time so colour schemes can override them.
local KIND_HL = {
  logo = "JvimDashboardHeader",
  jvim_logo = "JvimDashboardJvim",
  title = "JvimDashboardTitle",
  subtitle = "JvimDashboardSubtitle",
  attr = "JvimDashboardAttr",
  sep = "JvimDashboardSep",
  section = "JvimDashboardSection",
  action = "JvimDashboardAction",
  hint = "JvimDashboardHint",
  status = "JvimDashboardStatus",
  controls = "JvimDashboardControls",
  footer = "JvimDashboardFooter",
}

local function ensure_highlights()
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link("JvimDashboardHeader",   "Special")
  link("JvimDashboardJvim",     "String")
  link("JvimDashboardTitle",    "String")
  link("JvimDashboardSubtitle", "Comment")
  link("JvimDashboardAttr",     "Comment")
  link("JvimDashboardSep",      "NonText")
  link("JvimDashboardSection",  "Title")
  link("JvimDashboardAction",   "Function")
  link("JvimDashboardHint",     "Comment")
  link("JvimDashboardStatus",   "Identifier")
  link("JvimDashboardControls", "NonText")
  link("JvimDashboardFooter",   "Comment")
end

-- ##Function purpose: Execute a named action. Optional plugins (telescope,
-- neogit, etc.) are required lazily so the dashboard works even when the
-- plugin is missing — in which case we surface a friendly notification.
local function notify_missing(what)
  vim.notify(what .. " is not available.", vim.log.levels.WARN, { title = "jvim" })
end

local function safe_cmd(cmd)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.WARN, { title = "jvim" })
  end
end

local function jvim_finder(method)
  local ok, finder = pcall(require, "jvim.finder")
  if not ok then return notify_missing("jvim.finder") end
  finder[method]()
end

local function jenova_chat(method)
  local ok, chat = pcall(require, "jenova.chat")
  if not ok then return notify_missing("jenova.chat") end
  pcall(chat.setup)
  chat[method]()
end

local function jvim_diag(scope)
  local ok, dl = pcall(require, "jvim.diagnostics_list")
  if not ok then return notify_missing("jvim.diagnostics_list") end
  dl.open({ scope = scope })
end

local ACTIONS = {
  new_file       = function() M.close(); vim.cmd("enew") end,
  find_files     = function() M.close(); jvim_finder("files") end,
  recent_files   = function() M.close(); jvim_finder("oldfiles") end,
  live_grep      = function() M.close(); jvim_finder("grep") end,
  buffers        = function() M.close(); jvim_finder("buffers") end,
  terminal       = function() M.close(); safe_cmd("JvimTerminal") end,
  ide            = function() M.close(); safe_cmd("IDE") end,
  ai_chat_context= function() M.close(); jenova_chat("chat_with_context") end,
  ai_toggle      = function() M.close(); jenova_chat("toggle_chat") end,
  ai_fresh_chat  = function() M.close(); jenova_chat("fresh_chat") end,
  ai_web_search  = function() M.close(); jenova_chat("web_search") end,
  jenova_term    = function() M.close()
    local ok, term = pcall(require, "jvim.terminal")
    if not ok then return notify_missing("jvim.terminal") end
    term.toggle_jenova()
  end,
  monitor        = function() M.close()
    local ok, mon = pcall(require, "jenova.monitor")
    if not ok then return notify_missing("jenova.monitor") end
    mon.open_monitor()
  end,
  neogit         = function() M.close(); safe_cmd("Neogit") end,
  diffview       = function() M.close(); safe_cmd("DiffviewOpen") end,
  fugitive       = function() M.close(); safe_cmd("Git") end,
  trouble_diag   = function() M.close(); jvim_diag("workspace") end,
  trouble_sym    = function() M.close(); pcall(vim.lsp.buf.document_symbol) end,
  trouble_lsp    = function() M.close(); pcall(vim.lsp.buf.references) end,
  checkhealth    = function() M.close(); safe_cmd("checkhealth") end,
  quit           = function() vim.cmd("confirm qa") end,
  toggle_fim     = function()
    local cfg = vim.g.llama_config
    if not cfg then
      vim.notify("FIM not configured (llama.vim not loaded)", vim.log.levels.WARN, { title = "jvim" })
      return
    end
    local new_state = not cfg.auto_fim
    cfg.auto_fim = new_state
    vim.g.llama_config = cfg
    vim.g.jenova_fim_enabled = new_state
    pcall(function() vim.fn["llama#setup_autocmds"]() end)
    local label = new_state and "ENABLED" or "DISABLED"
    vim.notify("FIM Autocomplete: " .. label, vim.log.levels.INFO, { title = "Jenova AI" })
    if M.is_open() then pcall(render) end
  end,
}

local function trigger(action_name)
  local fn = ACTIONS[action_name]
  if fn then return fn() end
  notify_missing("Action " .. tostring(action_name))
end

-- ##Function purpose: Render the layout into the dashboard buffer and apply
-- per-row highlights via extmarks. Buffer is left non-modifiable so the user
-- cannot accidentally edit it while still being able to invoke key actions.
local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  local win = state.win
  local width
  if win and vim.api.nvim_win_is_valid(win) then
    width = vim.api.nvim_win_get_width(win)
  else
    width = vim.o.columns
  end

  local rows, actions = build_layout(width)
  state.actions = actions
  local lines = {}
  for i, row in ipairs(rows) do lines[i] = row.text end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for i, row in ipairs(rows) do
    if row.spans and #row.spans > 0 then
      -- Per-column extmarks: one highlight per column span so an action label
      -- never inherits the section-header colour just because they share a
      -- merged row in the multi-column grid.
      for _, sp in ipairs(row.spans) do
        local sp_hl = KIND_HL[sp.kind]
        if sp_hl then
          vim.api.nvim_buf_set_extmark(state.buf, NS, i - 1, sp.start_col, {
            end_row = i - 1,
            end_col = sp.end_col,
            hl_group = sp_hl,
          })
        end
      end
    else
      local hl = KIND_HL[row.kind]
      if hl then
        vim.api.nvim_buf_set_extmark(state.buf, NS, i - 1, 0, {
          end_row = i - 1,
          end_col = #row.text,
          hl_group = hl,
        })
      end
    end
  end
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false
end

-- ##Function purpose: Bind action keymaps once for the dashboard buffer.
-- Action keys are static for the lifetime of the buffer (the same sections
-- appear in every column layout), so we avoid rebinding them on every
-- VimResized/WinResized render pass.
local function bind_action_keymaps(buf, actions)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  for key, action_name in pairs(actions or {}) do
    vim.keymap.set("n", key, function() trigger(action_name) end, {
      buffer = buf, nowait = true, silent = true,
      desc = "Dashboard: " .. action_name,
    })
  end
end

-- ##Function purpose: Configure the dashboard buffer's options & autocmds.
local function configure_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = FILETYPE
  vim.api.nvim_buf_set_name(buf, "[jvim]")
end

-- Window-local options the dashboard overrides. Saved on `M.open()` and
-- restored when the dashboard buffer leaves its window so that opening a
-- normal file in the same window (e.g. via "New File" / Telescope action)
-- does not leak dashboard-specific UI settings (no line numbers, signcolumn
-- off, empty statuscolumn, etc.).
local DASHBOARD_WO_KEYS = {
  "number", "relativenumber", "cursorline", "cursorcolumn",
  "signcolumn", "foldenable", "list", "wrap", "spell", "statuscolumn",
}

local function snapshot_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
  local snap = {}
  for _, key in ipairs(DASHBOARD_WO_KEYS) do
    snap[key] = vim.wo[win][key]
  end
  return snap
end

local function restore_window(win, snap)
  if not (snap and win and vim.api.nvim_win_is_valid(win)) then return end
  for key, value in pairs(snap) do
    -- Re-check validity before each set: a callback firing in an async / event
    -- context (BufWipeout, deferred callbacks) can race with the window being
    -- closed elsewhere, in which case `vim.wo[win][key] = ...` would error.
    pcall(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win][key] = value
      end
    end)
  end
end

-- ##Function purpose: Snapshot the window's options once (idempotent) and
-- apply the dashboard's window configuration. Tracking is per-window so that
-- multiple windows can display the dashboard buffer concurrently and each
-- gets its own original options restored on BufWinLeave / BufWipeout.
local function track_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if state.prev_wo[win] == nil then
    state.prev_wo[win] = snapshot_window(win) or {}
  end
end

-- ##Function purpose: Restore options for any tracked window that no longer
-- displays the dashboard buffer (or whose handle is no longer valid).
local function restore_stale_windows()
  for win, snap in pairs(state.prev_wo) do
    if not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_win_get_buf(win) ~= state.buf
    then
      restore_window(win, snap)
      state.prev_wo[win] = nil
    end
  end
end

-- ##Function purpose: Restore options for every tracked window and clear the
-- map. Used when the buffer itself is being wiped out.
local function restore_all_windows()
  for win, snap in pairs(state.prev_wo) do
    restore_window(win, snap)
  end
  state.prev_wo = {}
end

local function configure_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldenable = false
  vim.wo[win].list = false
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].statuscolumn = ""
end

-- ##Function purpose: Async hardware profile probe; updates footer when ready.
-- Hardware profile is static for a given machine, so cache the resolved value
-- and avoid re-spawning `detect-hardware.sh` every time the dashboard reopens.
local function probe_profile()
  if M._profile and M._profile ~= "unknown" and M._profile ~= "detecting..." then
    return
  end
  local jenova_root = vim.env.JENOVA_ROOT or ""
  if jenova_root == "" or jenova_root == "$JENOVA_ROOT" then
    M._profile = "(no JENOVA_ROOT)"
    return
  end
  local detect = jenova_root .. "/hardware-profiles/detect-hardware.sh"
  if vim.fn.executable(detect) ~= 1 or not vim.system then
    M._profile = "unknown"
    return
  end
  vim.system({ detect }, { text = true, timeout = 5000 }, function(obj)
    vim.schedule(function()
      local profile = "unknown"
      if obj and obj.code == 0 then
        local raw = obj.stdout or ""
        local trimmed = raw:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" then profile = trimmed end
      end
      M._profile = profile
      if M.is_open() then render() end
    end)
  end)
end

-- ##Function purpose: Open the dashboard in the current window. Reuses an
-- existing dashboard buffer if one is alive.
function M.open()
  ensure_highlights()

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    -- Only reuse the existing window if it actually still displays the
    -- dashboard buffer. The user may have switched buffers in that window
    -- (e.g. via :bnext / Telescope), in which case we should re-attach the
    -- dashboard buffer to the current window instead of stealing focus to a
    -- window that no longer shows it.
    if state.win
      and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf
    then
      vim.api.nvim_set_current_win(state.win)
      render()
      return
    end
    vim.api.nvim_set_current_buf(state.buf)
    state.win = vim.api.nvim_get_current_win()
    track_window(state.win)
    configure_window(state.win)
    render()
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  configure_buffer(buf)

  vim.api.nvim_set_current_buf(buf)
  state.win = vim.api.nvim_get_current_win()
  track_window(state.win)
  configure_window(state.win)

  render()
  bind_action_keymaps(buf, state.actions)
  probe_profile()

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    -- These events are window/UI-scoped, not buffer-scoped, so do NOT use a
    -- `buffer =` filter (it would prevent the callback from firing
    -- reliably). Guard inside the callback instead so we no-op once the
    -- dashboard buffer has been wiped.
    callback = function()
      if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
        return
      end
      -- New windows may have started displaying the dashboard buffer (e.g.
      -- :split inside the dashboard); track + configure each one before the
      -- redraw so per-window options stay consistent across splits.
      for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
        track_window(win)
        configure_window(win)
      end
      render()
    end,
  })
  -- Restore the host window's options when the dashboard buffer leaves the
  -- window (action replaces it with a real buffer, user navigates away, etc.).
  -- Walk every tracked window so each one is restored against its own
  -- pre-dashboard snapshot rather than relying on the most-recent state.win.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function() restore_stale_windows() end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      restore_all_windows()
      state.buf = nil
      state.win = nil
    end,
  })
end

function M.close()
  -- BufWipeout fires from nvim_buf_delete and restores window options for us.
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
  state.prev_wo = {}
end

function M.is_open()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

-- Re-render the dashboard if currently open. Used by async probes (macOS
-- product version, profile) to refresh the display once data
-- becomes available without blocking startup.
function M.redraw()
  if M.is_open() then pcall(render) end
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

-- ##Function purpose: Decide whether to auto-open at VimEnter. Returns true
-- only when jvim was launched with no file args, no stdin pipe, and a clean
-- single empty buffer — matching the historical conditions for showing the
-- nvi-style intro screen.
function M.should_autoshow()
  if vim.g.jvim_dashboard_disable then return false end
  if vim.fn.argc() ~= 0 then return false end
  -- Only autoshow when the startup buffer is a clean, unmodified, single empty
  -- line and is the only listed buffer Neovim has opened. `bufnr("$")` returns
  -- the highest buffer number ever assigned, which is unreliable when a plugin
  -- creates and wipes a temp buffer during startup. Counting listed buffers
  -- via getbufinfo() is robust against that.
  if #vim.fn.getbufinfo({ buflisted = 1 }) ~= 1 then return false end
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_line_count(bufnr) ~= 1 then return false end
  if vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "" then return false end
  if vim.bo[bufnr].modified then return false end
  -- stdin pipe sets stdin_isatty=0; if data was piped, abort.
  if vim.g.jvim_stdin_used then return false end
  -- Respect a user-configured 'shortmess'+="I" (intro suppressed by user).
  -- We distinguish from our own append in plugin/jvim_dashboard.lua via
  -- g:jvim_dashboard_user_shm_I.
  if vim.g.jvim_dashboard_user_shm_I and not vim.g.jvim_dashboard_force then
    return false
  end
  return true
end

return M
