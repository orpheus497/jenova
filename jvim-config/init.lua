-- Jenova FreeBSD IDE — jvim native configuration

--------------------------------------------------------------------------------
-- [1] BUILTIN DISABLE
-- Let jvim_ui and jvim_dashboard load (they are now our UI layer).
-- Only disable slow/unused builtins.
--------------------------------------------------------------------------------
for _, name in ipairs({
  "gzip", "matchit", "matchparen", "netrwPlugin",
  "tarPlugin", "tohtml", "tutor", "zipPlugin",
}) do
  vim.g["loaded_" .. name] = 1
end

--------------------------------------------------------------------------------
-- [2] EDITOR OPTIONS
--------------------------------------------------------------------------------
vim.g.mapleader = " "
vim.g.maplocalleader = " "

local opt = vim.opt
opt.number         = true
opt.relativenumber = true
opt.undofile       = true
opt.signcolumn     = "yes"
opt.termguicolors  = true
opt.updatetime     = 200
opt.expandtab      = true
opt.shiftwidth     = 4
opt.tabstop        = 4
opt.softtabstop    = 4
opt.cursorline     = true
opt.ignorecase     = true
opt.smartcase      = true
opt.splitbelow     = true
opt.splitright     = true
opt.mouse          = "a"
opt.clipboard      = "unnamedplus"
opt.swapfile       = false
opt.maxmempattern  = 2000

-- Use mcsh (the bundled tcsh-derived shell) for :terminal, :! and the docked
-- jvim terminal toggle. Falls back to the system shell only if mcsh is not on
-- $PATH so headless/dev environments without a built mcsh still work.
do
  local mcsh = vim.fn.exepath("mcsh")
  if mcsh ~= "" then
    opt.shell = mcsh
    opt.shellcmdflag = "-c"
    opt.shellquote = ""
    opt.shellxquote = ""
  end
end

--------------------------------------------------------------------------------
-- [3] PLUGIN CONFIGURATION
-- Vendored plugins live under jvim/runtime/pack/jenova/start/ and are
-- auto-loaded by Neovim's native package system. The plugin spec files in
-- lua/plugins/ still use lazy.nvim-style table syntax for clarity, so we
-- run them through a tiny native spec_runner that honours init/config/opts/
-- keys/cmd/event/ft. No third-party plugin manager is loaded.
--------------------------------------------------------------------------------
local spec_runner = require("jenova.spec_runner")
for _, mod in ipairs({
  "plugins.editor",
  "plugins.git",
  "plugins.lsp",
  "plugins.mini",
  "plugins.llama",
  "plugins.chat",
  "plugins.health",
  "plugins.ui",
  "plugins.dashboard",
}) do
  spec_runner.run(mod)
end

--------------------------------------------------------------------------------
-- [4] MASTER KEYBINDS
--------------------------------------------------------------------------------
local map = vim.keymap.set

map("n", "<leader>w", "<cmd>w<CR>",         { desc = "Save" })
map("n", "<leader>q", "<cmd>q<CR>",         { desc = "Quit" })
map("n", "<Esc>",     "<cmd>nohlsearch<CR>", { desc = "No Highlight" })

map("n", "<C-h>", "<C-w>h", { desc = "Go to Left Window" })
map("n", "<C-j>", "<C-w>j", { desc = "Go to Lower Window" })
map("n", "<C-k>", "<C-w>k", { desc = "Go to Upper Window" })
map("n", "<C-l>", "<C-w>l", { desc = "Go to Right Window" })

map("n", "<S-h>", "<cmd>bprevious<CR>", { desc = "Prev Buffer" })
map("n", "<S-l>", "<cmd>bnext<CR>",     { desc = "Next Buffer" })

map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, { desc = "Prev Diagnostic" })
map("n", "]d", function() vim.diagnostic.jump({ count =  1 }) end, { desc = "Next Diagnostic" })

map("n", "<leader>aj", function()
  require("jvim.terminal").toggle_shell()
end, { desc = "Toggle Terminal Shell" })

--------------------------------------------------------------------------------
-- [5] IDE COMMAND
--------------------------------------------------------------------------------
vim.api.nvim_create_user_command("IDE", function()
  require("jvim.layout").open_ide()
end, { desc = "Open IDE panels" })

vim.api.nvim_create_user_command("JenovaMonitor", function()
  local ok, monitor = pcall(require, "jenova.monitor")
  if ok then monitor.open_monitor()
  else vim.notify("Failed to load jenova.monitor", vim.log.levels.ERROR) end
end, { desc = "Open Jenova backend monitor" })

vim.api.nvim_create_user_command("JenovaLanScan", function()
  local ok, lan = pcall(require, "jenova.lan")
  if ok then
    vim.notify("Scanning LAN for Jenova CA...", vim.log.levels.INFO, { title = "Jenova LAN" })
    lan.discover({
      on_found = function(host, port)
        lan.configure_remote(host, port)
        local mon_ok, monitor = pcall(require, "jenova.monitor")
        if mon_ok then monitor.start_polling() end
      end,
      on_complete = function()
        vim.notify("No Jenova CA found on LAN.", vim.log.levels.WARN, { title = "Jenova LAN" })
      end,
    })
  else
    vim.notify("Failed to load jenova.lan", vim.log.levels.ERROR)
  end
end, { desc = "Scan LAN for remote Jenova CA" })

map("n", "<leader>aM", "<cmd>JenovaMonitor<CR>",    { desc = "Jenova Monitor" })
map("n", "<leader>ah", "<cmd>checkhealth jenova<CR>", { desc = "Jenova Health" })
map("n", "<leader>al", "<cmd>JenovaLanScan<CR>",    { desc = "Jenova LAN Scan" })
map("n", "<leader>af", function()
  local cfg = vim.g.llama_config
  if not cfg then
    vim.notify("FIM not configured (llama.vim not loaded)", vim.log.levels.WARN, { title = "jvim" })
    return
  end
  local new_state = not cfg.auto_fim
  cfg.auto_fim = new_state
  vim.g.llama_config = cfg
  vim.g.jenova_fim_enabled = new_state
  local label = new_state and "ENABLED" or "DISABLED"
  vim.notify("FIM Autocomplete: " .. label, vim.log.levels.INFO, { title = "Jenova AI" })
end, { desc = "Toggle FIM Autocomplete" })

--------------------------------------------------------------------------------
-- [6] JENOVA BACKEND HEALTH CHECK
--------------------------------------------------------------------------------
local function _jenova_tcp_probe(callback)
  local uv = vim.uv or vim.loop
  if not uv then vim.schedule(function() callback(false) end); return end
  local ep_ok, ep = pcall(require, "jenova.endpoints")
  local host, port
  if ep_ok then
    host = ep.host(); port = ep.proxy_port()
  else
    host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
    if host == "0.0.0.0" or host == "::" or host == "*" then host = "127.0.0.1" end
    port = tonumber(vim.env.JENOVA_PORT or "8080")
  end
  local tcp = uv.new_tcp()
  if not tcp then vim.schedule(function() callback(false) end); return end
  local timeout = uv.new_timer()
  local closed = false
  local function close_handles()
    if not closed then
      closed = true
      pcall(function() tcp:close() end)
      if timeout then pcall(function() timeout:close() end) end
    end
  end
  if timeout then
    timeout:start(3000, 0, function()
      if not closed then close_handles(); vim.schedule(function() callback(false) end) end
    end)
  end
  tcp:connect(host, math.floor(port or 8080), function(err)
    if closed then return end
    close_handles()
    vim.schedule(function() callback(not err) end)
  end)
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.defer_fn(function()
      _jenova_tcp_probe(function(connected)
        vim.g.jenova_connected = connected
        if connected then
          local ok, monitor = pcall(require, "jenova.monitor")
          if ok then monitor.start_polling() end
        else
          local is_lan_mode     = vim.env.JENOVA_LAN_MODE == "1"
          local has_connect_host = vim.env.JENOVA_CONNECT_HOST and vim.env.JENOVA_CONNECT_HOST ~= ""
          local has_jvim_env    = (vim.env.JENOVA_ROOT and vim.env.JENOVA_ROOT ~= "" and vim.env.JENOVA_ROOT ~= "$JENOVA_ROOT")
          if is_lan_mode and has_connect_host then
            vim.notify(("LAN remote %s:%s not responding."):format(
              vim.env.JENOVA_CONNECT_HOST, vim.env.JENOVA_PORT or "8080"),
              vim.log.levels.WARN, { title = "Jenova LAN" })
            local ok, monitor = pcall(require, "jenova.monitor")
            if ok then monitor.start_polling() end
          elseif is_lan_mode then
            local lan_ok, lan = pcall(require, "jenova.lan")
            if lan_ok then lan.auto_discover() end
          elseif has_jvim_env then
            vim.notify("Jenova CA not running. AI features unavailable.",
              vim.log.levels.WARN, { title = "Jenova" })
            local ok, monitor = pcall(require, "jenova.monitor")
            if ok then monitor.start_polling() end
          else
            local lan_ok, lan = pcall(require, "jenova.lan")
            if lan_ok then lan.auto_discover() end
          end
        end
      end)
    end, 1500)
  end,
})

vim.g.jenova_connected = false
local _init_uv = vim.uv or vim.loop
local _jenova_timer = _init_uv and _init_uv.new_timer()
local _cached_monitor, _monitor_checked = nil, false
if _jenova_timer then
  _jenova_timer:start(5000, 30000, vim.schedule_wrap(function()
    if not _monitor_checked then
      _monitor_checked = true
      local ok, mod = pcall(require, "jenova.monitor")
      if ok then _cached_monitor = mod end
    end
    if _cached_monitor and _cached_monitor._timer then return end
    _jenova_tcp_probe(function(connected) vim.g.jenova_connected = connected end)
  end))
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      if _jenova_timer then pcall(function() _jenova_timer:close() end) end
    end,
  })
end
