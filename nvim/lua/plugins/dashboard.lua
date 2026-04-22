-- ##Script function and purpose: alpha-nvim startup dashboard. Plugins are
-- vendored in jvim/runtime/pack/jenova/start/, so this module just configures
-- alpha imperatively (no lazy spec wrapper).

local alpha = require("alpha")
local dashboard = require("alpha.themes.dashboard")

local function detect_os()
  local sysname = vim.uv and vim.uv.os_uname().sysname
    or (vim.loop and vim.loop.os_uname().sysname) or "Unknown"
  local release = ""
  if sysname == "FreeBSD" then
    local r = vim.fn.system("uname -r")
    release = " " .. vim.fn.trim(r)
  elseif sysname == "Linux" then
    local ok, lines = pcall(vim.fn.readfile, "/etc/os-release")
    if ok then
      for _, line in ipairs(lines) do
        local name = line:match('^PRETTY_NAME="(.-)"')
        if name then release = " (" .. name .. ")"; break end
      end
    end
  elseif sysname == "Darwin" then
    local r = vim.fn.system("sw_vers -productVersion")
    release = " " .. vim.fn.trim(r)
  end
  return sysname .. release
end

local function btn(sc, txt, lua_func_str)
  return dashboard.button(sc, txt, "<cmd>lua " .. lua_func_str .. "<CR>")
end

local os_info = detect_os()
local v = vim.version()
local nvim_version = string.format("JVIM %d.%d.%d", v.major, v.minor, v.patch)

local header = {
  type = "text",
  val = {
    "",
    "",
    "",
    "       ██╗███████╗███╗   ██╗ ██████╗ ██╗   ██╗ █████╗        ",
    "       ██║██╔════╝████╗  ██║██╔═══██╗██║   ██║██╔══██╗       ",
    "       ██║█████╗  ██╔██╗ ██║██║   ██║██║   ██║███████║       ",
    "  ██   ██║██╔══╝  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║      ",
    "  ╚█████╔╝███████╗██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║      ",
    "   ╚════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝      ",
    "",
    "            Cognitive Architecture — IDE",
    "",
    "     " .. os_info .. "  │  " .. nvim_version,
    "",
  },
  opts = { position = "center", hl = "AlphaHeader" },
}

local quick_actions = {
  type = "group",
  val = {
    { type = "text", val = "── Quick Actions ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
    { type = "padding", val = 1 },
    dashboard.button("e", "  New File",     "<cmd>ene<CR>"),
    btn("f",              "  Find File",    "require('telescope.builtin').find_files()"),
    btn("r",              "  Recent Files", "require('telescope.builtin').oldfiles()"),
    btn("g",              "  Live Grep",    "require('telescope.builtin').live_grep()"),
    btn("b",              "  Buffers",      "require('telescope.builtin').buffers()"),
    dashboard.button("i", "  Open IDE Panels", "<cmd>IDE<CR>"),
  },
  opts = { spacing = 0 },
}

local ai_section = {
  type = "group",
  val = {
    { type = "text", val = "── AI / Jenova ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
    { type = "padding", val = 1 },
    btn("c", "  Chat with File Context",  "require('jenova.chat').setup(); require('jenova.chat').chat_with_context()"),
    btn("n", "  New Chat",                "require('jenova.chat').setup(); require('jenova.chat').open_chat()"),
    btn("t", "  Toggle AI Chat",          "require('jenova.chat').setup(); require('jenova.chat').toggle_chat()"),
    btn("s", "  Web Search",              "require('jenova.chat').setup(); require('jenova.chat').web_search()"),
    btn("j", "  Jenova Agent Terminal",   "local r=vim.fn.expand('$JENOVA_ROOT'); if r=='' or r=='$JENOVA_ROOT' then r=vim.fn.expand('~/Projects/jenova') end; vim.cmd('term cd '..vim.fn.shellescape(r)..' && bin/jenova')"),
    btn("M", "  Backend Monitor",         "require('jenova.monitor').open_monitor()"),
  },
  opts = { spacing = 0 },
}

local git_section = {
  type = "group",
  val = {
    { type = "text", val = "── Git ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
    { type = "padding", val = 1 },
    dashboard.button("G", "  Neogit Status", "<cmd>Neogit<CR>"),
    dashboard.button("D", "  Diff View",     "<cmd>DiffviewOpen<CR>"),
    dashboard.button("F", "  Fugitive",      "<cmd>Git<CR>"),
  },
  opts = { spacing = 0 },
}

local diagnostics_section = {
  type = "group",
  val = {
    { type = "text", val = "── Diagnostics & LSP ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
    { type = "padding", val = 1 },
    dashboard.button("x", "  Workspace Diagnostics", "<cmd>Trouble diagnostics toggle<CR>"),
    dashboard.button("S", "  Symbols",                "<cmd>Trouble symbols toggle focus=false<CR>"),
    dashboard.button("R", "  LSP Defs / References",  "<cmd>Trouble lsp toggle focus=false win.position=right<CR>"),
  },
  opts = { spacing = 0 },
}

local config_section = {
  type = "group",
  val = {
    { type = "text", val = "── Config ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
    { type = "padding", val = 1 },
    dashboard.button("m", "  Mason (LSP Installer)", "<cmd>Mason<CR>"),
    dashboard.button("h", "  Checkhealth",           "<cmd>checkhealth<CR>"),
    dashboard.button("q", "  Quit",                   "<cmd>qa<CR>"),
  },
  opts = { spacing = 0 },
}

-- Async hardware profile detection for the backend status panel.
local _mon_ok, _monitor = pcall(require, "jenova.monitor")
local _ep
if _mon_ok and _monitor.get_endpoints then
  _ep = _monitor.get_endpoints()
else
  local _h = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
  if _h == "0.0.0.0" or _h == "::" or _h == "*" then _h = "127.0.0.1" end
  _ep = { host = _h, proxy_port = 8080, llama_port = 8081, embed_port = 8082 }
end
local host = _ep.host
local proxy_port = tostring(_ep.proxy_port)
local llama_port = tostring(_ep.llama_port)
local embed_port = tostring(_ep.embed_port)

local function make_backend_status(profile_name)
  return {
    "",
    "── Backend Status ──",
    "",
    string.format("     Proxy:    :%s     Llama:  :%s     Embed:  :%s",
      proxy_port, llama_port, embed_port),
    string.format("     Host:     %s      Profile: %s", host, profile_name),
    "",
  }
end

local backend_status = {
  type = "text",
  val = make_backend_status("detecting..."),
  opts = { position = "center", hl = "AlphaHeaderLabel" },
}

local jenova_root = vim.env.JENOVA_ROOT or ""
if jenova_root ~= "" and jenova_root ~= "$JENOVA_ROOT" then
  local detect = jenova_root .. "/hardware-profiles/detect-hardware.sh"
  if vim.fn.executable(detect) == 1 and vim.system then
    vim.system({ detect }, { text = true, timeout = 5000 }, function(obj)
      vim.schedule(function()
        local profile_name = "unknown"
        if obj and obj.code == 0 then
          local raw = obj.stdout or ""
          local result = raw:match("^%s*(.-)%s*$") or ""
          if result ~= "" then profile_name = result end
        end
        backend_status.val = make_backend_status(profile_name)
        pcall(vim.cmd, "AlphaRedraw")
      end)
    end)
  else
    backend_status.val = make_backend_status("unknown")
  end
else
  backend_status.val = make_backend_status("(no JENOVA_ROOT)")
end

local controls = {
  type = "text",
  val = {
    "",
    "┌─────────────── Navigation & Controls ───────────────┐",
    "│                                                      │",
    "│  SPC w       Save          SPC q       Quit          │",
    "│  SPC e       File Tree     SPC f f     Find File     │",
    "│  SPC f g     Live Grep     SPC f b     Buffers       │",
    "│  Shift-H/L   Prev/Next Buffer                        │",
    "│                                                      │",
    "│  Ctrl-h/j/k/l   Window Navigation                    │",
    "│  [ d  /  ] d    Prev / Next Diagnostic               │",
    "│  [ h  /  ] h    Prev / Next Git Hunk                 │",
    "│  g d            Go to Definition                      │",
    "│  K              Hover Documentation                   │",
    "│  SPC c a        Code Action     SPC r n   Rename      │",
    "│  SPC c d        Diagnostic Float                      │",
    "│                                                      │",
    "│  SPC a c   File Context Chat   SPC a t   Toggle Chat  │",
    "│  SPC a r   Respond (send)      SPC a n   New Chat     │",
    "│  SPC a e   Visual Chat (v)     SPC a w   Rewrite (v)  │",
    "│  SPC a s   Web Search          SPC a i   Inline Rewrite│",
    "│  SPC a x   Stop Generation     SPC a m   Monitor      │",
    "│                                                      │",
    "│  g c       Toggle Comment   s a / s d / s r  Surround │",
    "│  SPC b d   Delete Buffer    SPC c f   Format Buffer   │",
    "│                                                      │",
    "└──────────────────────────────────────────────────────┘",
  },
  opts = { position = "center", hl = "AlphaFooter" },
}

local footer_val = {
  type = "text",
  val = "",
  opts = { position = "center", hl = "AlphaFooter" },
}

alpha.setup({
  layout = {
    { type = "padding", val = 1 },
    header,
    { type = "padding", val = 1 },
    quick_actions,
    { type = "padding", val = 1 },
    ai_section,
    { type = "padding", val = 1 },
    git_section,
    { type = "padding", val = 1 },
    diagnostics_section,
    { type = "padding", val = 1 },
    config_section,
    { type = "padding", val = 1 },
    backend_status,
    { type = "padding", val = 1 },
    controls,
    { type = "padding", val = 1 },
    footer_val,
  },
  opts = { margin = 5 },
})

-- Footer: count vendored packages once jvim has finished startup.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local count = 0
    local pack_dir = vim.fn.fnamemodify(
      vim.api.nvim_get_runtime_file("pack/jenova/start", false)[1] or "", ":p")
    if pack_dir ~= "" then
      for _ in vim.fs.dir(pack_dir) do count = count + 1 end
    end
    footer_val.val = string.format("  %d vendored plugins loaded", count)
    pcall(vim.cmd, "AlphaRedraw")
  end,
})
