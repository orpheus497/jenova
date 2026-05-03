-- ##Script function and purpose: Main Neovim entry point — bootstraps lazy.nvim, sets
-- global editor options, loads modular plugin configs, and wires master keybinds
-- for the Jenova FreeBSD IDE environment.

-- ========================================================================== --
--  Jenova IDE (Modular Edition)
-- ========================================================================== --

-- ##Section purpose: PATH RECTIFICATION — Prepend FreeBSD local site directory so
-- luarocks and site-local packages are found before anything else
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/site")

-- ##Section purpose: LIBDIR RESOLUTION — locate the install-tree `lib/jvim`
-- directory that holds bundled treesitter parsers (parser/<lang>.so). The
-- libdir is in &runtimepath by default (see runtime.c:get_lib_dir), but
-- lazy.nvim's `performance.rtp.reset = true` strips it during setup, which
-- breaks vim.treesitter.start() in every shipped ftplugin. Ask core for the
-- canonical libdir first (matches runtime.c:get_lib_dir cross-platform path
-- handling) and fall back to manual derivation only if it is unavailable, so
-- we can both early-prepend it and feed it to lazy via rtp.paths below.
local jvim_libdir
do
  local ok, libdir = pcall(function() return vim.api.nvim__get_lib_dir() end)
  if ok and libdir and libdir ~= "" and vim.fn.isdirectory(libdir) == 1 then
    jvim_libdir = vim.fs.normalize(libdir)
  end

  if not jvim_libdir then
    local exe = vim.v.progpath ~= "" and vim.v.progpath or vim.fn.exepath("jvim")
    if exe and exe ~= "" then
      -- Resolve to handle symlinks, then go ../lib/jvim relative to bin/jvim.
      local prefix = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.resolve(exe), ":h:h"))
      local cand = prefix .. "/lib/jvim"
      if vim.fn.isdirectory(cand) == 1 then
        jvim_libdir = cand
      end
    end
  end

  if not jvim_libdir and vim.fn.isdirectory("/usr/local/lib/jvim") == 1 then
    jvim_libdir = "/usr/local/lib/jvim"
  end

  if jvim_libdir then
    vim.opt.rtp:prepend(jvim_libdir)
  end
end

--------------------------------------------------------------------------------
-- [2] BOOTSTRAP LAZY.NVIM
--------------------------------------------------------------------------------
-- ##Section purpose: Auto-install lazy.nvim plugin manager on first launch if absent
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", lazypath })
end
vim.opt.rtp:prepend(lazypath)

--------------------------------------------------------------------------------
-- [3] MASTER EDITOR OPTIONS
--------------------------------------------------------------------------------
-- ##Section purpose: Global editor behaviour — these apply before any plugin loads
vim.g.mapleader = " "
vim.g.maplocalleader = " "

local opt = vim.opt
opt.number = true
opt.relativenumber = true
opt.undofile = true         -- Persistent ZFS-backed undo
opt.signcolumn = "yes"
opt.termguicolors = true    -- 24-bit RGB
opt.updatetime = 200
opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.softtabstop = 4
opt.cursorline = true
opt.ignorecase = true
opt.smartcase = true
opt.splitbelow = true
opt.splitright = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"
-- ##Step purpose: FreeBSD/ZFS optimizations — ZFS snapshots + persistent undo make
-- swapfiles redundant. maxmempattern raised for complex treesitter/LSP patterns.
opt.swapfile = false
opt.maxmempattern = 2000

--------------------------------------------------------------------------------
-- [4] PLUGIN ORCHESTRATION
--------------------------------------------------------------------------------
-- ##Section purpose: Load shipped plugin specs from `jvim_plugins/` (renamed
-- from `plugins/` to avoid colliding with user `~/.config/jvim/lua/plugins/`
-- — see PLUGINS.md). User plugin specs in `lua/plugins/*.lua` continue to be
-- loaded automatically as a second import root if present.
local lazy_imports = { { import = "jvim_plugins" } }
do
  local user_plugins = vim.fn.stdpath("config") .. "/lua/plugins"
  if vim.fn.isdirectory(user_plugins) == 1 then
    table.insert(lazy_imports, { import = "plugins" })
  end
end

require("lazy").setup(lazy_imports, {
  defaults = { lazy = false },
  install = { colorscheme = { "jvim" } },
  rocks = { enabled = false }, -- Fix for FreeBSD libc/rocks conflict
  ui = { border = "rounded" },
  performance = {
    rtp = {
      reset = true,
      -- ##Step purpose: Keep the install-tree libdir on &runtimepath after
      -- lazy's rtp reset so bundled treesitter parsers (parser/<lang>.so) and
      -- any other lib-resident assets remain discoverable via
      -- nvim_get_runtime_file().
      paths = jvim_libdir and { jvim_libdir } or {},
      disabled_plugins = {
        "gzip",
        "matchit",
        "matchparen",
        "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})

--------------------------------------------------------------------------------
-- [5] MASTER KEYBOARD ORCHESTRATION (General)
--------------------------------------------------------------------------------
-- ##Section purpose: Top-level keybinds not owned by any individual plugin module
local map = vim.keymap.set

-- General
map("n", "<leader>w", "<cmd>w<CR>", { desc = "Save" })
map("n", "<leader>q", "<cmd>q<CR>", { desc = "Quit" })
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "No Highlight" })

-- Window Navigation
map("n", "<C-h>", "<C-w>h", { desc = "Go to Left Window" })
map("n", "<C-j>", "<C-w>j", { desc = "Go to Lower Window" })
map("n", "<C-k>", "<C-w>k", { desc = "Go to Upper Window" })
map("n", "<C-l>", "<C-w>l", { desc = "Go to Right Window" })

-- Buffer Navigation
map("n", "<S-h>", "<cmd>bprevious<CR>", { desc = "Prev Buffer" })
map("n", "<S-l>", "<cmd>bnext<CR>", { desc = "Next Buffer" })

-- Diagnostics
map("n", "[d", vim.diagnostic.goto_prev, { desc = "Prev Diagnostic" })
map("n", "]d", vim.diagnostic.goto_next, { desc = "Next Diagnostic" })

-- ##Section purpose: Bottom terminal workflow — toggle/new shell + Jenova agent
-- terminal. Implementation lives in `jvim.terminal` so it can be reused from
-- the dashboard and user commands without duplicating split logic.
map("n", "<leader>tt", function()
  require("jvim.terminal").toggle_shell()
end, { desc = "Toggle Terminal" })
map("n", "<leader>tn", function()
  require("jvim.terminal").new_shell()
end, { desc = "New Terminal" })
map("n", "<leader>ta", function()
  require("jvim.terminal").toggle_jenova()
end, { desc = "Jenova Agent Terminal" })
-- Keep the historical <leader>aj binding pointing at the Jenova terminal.
map("n", "<leader>aj", function()
  require("jvim.terminal").toggle_jenova()
end, { desc = "Jenova Agent Terminal" })

vim.api.nvim_create_user_command("JvimTerminal", function()
  require("jvim.terminal").toggle_shell()
end, { desc = "Toggle bottom terminal" })
vim.api.nvim_create_user_command("JvimTerminalNew", function()
  require("jvim.terminal").new_shell()
end, { desc = "Open new bottom terminal" })
vim.api.nvim_create_user_command("JenovaTerminal", function()
  require("jvim.terminal").toggle_jenova()
end, { desc = "Toggle Jenova agent terminal" })

--------------------------------------------------------------------------------
-- [6] JENOVA BACKEND HEALTH CHECK
--------------------------------------------------------------------------------
-- ##Section purpose: Shared non-blocking TCP probe used by startup and periodic checks.
-- callback(connected: boolean) is called on the main loop via vim.schedule.
local function _jenova_tcp_probe(callback)
  local uv = vim.uv or vim.loop
  if not uv then
    vim.schedule(function() callback(false) end)
    return
  end
  local ep_ok, ep = pcall(require, "jenova.endpoints")
  local host, port
  if ep_ok then
    host = ep.host()
    port = ep.proxy_port()
  else
    host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
    if host == "0.0.0.0" or host == "::" or host == "*" then host = "127.0.0.1" end
    port = tonumber(vim.env.JENOVA_PORT or "8080")
  end
  local tcp = uv.new_tcp()
  if not tcp then
    vim.schedule(function() callback(false) end)
    return
  end
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
      if not closed then
        close_handles()
        vim.schedule(function() callback(false) end)
      end
    end)
  end
  tcp:connect(host, port, function(err)
    if closed then return end
    close_handles()
    vim.schedule(function() callback(not err) end)
  end)
end

-- ##Section purpose: Notify user if Jenova CA backend is unreachable at startup.
-- Deferred 1.5s so the notification fires after jvim.notify is fully initialised.
-- Backend status is cached in vim.g.jenova_connected for the statusline component.
-- When launched without jvim (no JENOVA_ROOT set), falls back to LAN discovery
-- to find a remote Jenova CA instance on the local network.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.defer_fn(function()
      _jenova_tcp_probe(function(connected)
        vim.g.jenova_connected = connected
        if connected then
          -- Backend reachable — start monitor polling
          local ok, monitor = pcall(require, "jenova.monitor")
          if ok then
            monitor.start_polling()
          end
        else
          local ep_ok, ep = pcall(require, "jenova.endpoints")
          local is_lan_mode = vim.env.JENOVA_LAN_MODE == "1"
          local has_connect_host = vim.env.JENOVA_CONNECT_HOST
            and vim.env.JENOVA_CONNECT_HOST ~= ""
          local has_jvim_env = ep_ok and ep.has_jvim_env() or (
            vim.env.JENOVA_ROOT and vim.env.JENOVA_ROOT ~= ""
            and vim.env.JENOVA_ROOT ~= "$JENOVA_ROOT"
          )

          if is_lan_mode and has_connect_host then
            -- Explicit remote host: jvim --remote <host>
            local remote = vim.env.JENOVA_CONNECT_HOST
            local port = vim.env.JENOVA_PORT or "8080"
            vim.notify(
              string.format(
                "LAN remote %s:%s not responding.\n" ..
                "Verify server has JENOVA_HOST=0.0.0.0 and jenova-ca is running.\n" ..
                "Monitor will keep retrying.",
                remote, port
              ),
              vim.log.levels.WARN,
              { title = "Jenova LAN" }
            )
            local ok, monitor = pcall(require, "jenova.monitor")
            if ok then
              monitor.start_polling()
            end
          elseif is_lan_mode and not has_connect_host then
            -- Auto-discover mode: jvim --remote (no host given)
            local lan_ok, lan = pcall(require, "jenova.lan")
            if lan_ok then
              lan.auto_discover()
            else
              vim.notify(
                "LAN auto-discover: jenova.lan module unavailable.",
                vim.log.levels.WARN,
                { title = "Jenova LAN" }
              )
            end
          elseif has_jvim_env then
            vim.notify(
              "Jenova CA backend not running. AI features unavailable.\n" ..
              "Run:  jvim somefile.lua   OR   bin/jenova-ca --daemon",
              vim.log.levels.WARN,
              { title = "Jenova" }
            )
            local ok, monitor = pcall(require, "jenova.monitor")
            if ok then
              monitor.start_polling()
            end
          else
            local lan_ok, lan = pcall(require, "jenova.lan")
            if lan_ok then
              lan.auto_discover()
            else
              vim.notify(
                "Jenova CA not configured. Use jvim or set JENOVA_CONNECT_HOST.",
                vim.log.levels.INFO,
                { title = "Jenova" }
              )
            end
          end
        end
      end)
    end, 1500)
  end,
  once = true,
})

-- ##Section purpose: Fallback backend health refresh every 30s (only if monitor module
-- fails to load). Cleaned up on VimLeavePre to prevent late callbacks.
vim.g.jenova_connected = false  -- initialise pessimistically
local _init_uv = vim.uv or vim.loop
local _jenova_timer = _init_uv and _init_uv.new_timer()
-- Cache monitor module reference once (avoids pcall+require on every 30s tick)
local _cached_monitor = nil
local _monitor_checked = false
if _jenova_timer then
  _jenova_timer:start(5000, 30000, vim.schedule_wrap(function()
    -- Cache the monitor module lookup (only try once)
    if not _monitor_checked then
      _monitor_checked = true
      local ok, mod = pcall(require, "jenova.monitor")
      if ok then _cached_monitor = mod end
    end
    -- Skip if monitor module is handling polling (avoid duplicate probes)
    if _cached_monitor and _cached_monitor._timer then return end
    _jenova_tcp_probe(function(connected)
      vim.g.jenova_connected = connected
    end)
  end))
  -- Clean up fallback timer on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if _jenova_timer then
        pcall(function() _jenova_timer:close() end)
      end
    end,
    once = true,
  })
end

--------------------------------------------------------------------------------
-- [7] IDE PANEL OPENER
--------------------------------------------------------------------------------
-- ##Section purpose: :IDE user command — opens NvimTree, Edgy auto-manages layout
-- FIX F1: Removed manual panel management that raced with Edgy. Edgy now owns
-- the three-panel layout (NvimTree + Trouble left, AI Chat right).
-- ##Section purpose: :JenovaMonitor — opens floating window with real-time backend stats
vim.api.nvim_create_user_command("JenovaMonitor", function()
  local ok, monitor = pcall(require, "jenova.monitor")
  if ok then
    monitor.open_monitor()
  else
    vim.notify("Failed to load jenova.monitor module", vim.log.levels.ERROR)
  end
end, { desc = "Open Jenova backend monitor" })

-- ##Section purpose: :JenovaLanScan — manual LAN discovery for remote Jenova CA
vim.api.nvim_create_user_command("JenovaLanScan", function()
  local ok, lan = pcall(require, "jenova.lan")
  if ok then
    vim.notify("Scanning LAN for Jenova CA instances...", vim.log.levels.INFO, { title = "Jenova LAN" })
    lan.discover({
      on_found = function(host, port)
        lan.configure_remote(host, port)
        -- Restart monitor polling with new endpoint
        local mon_ok, monitor = pcall(require, "jenova.monitor")
        if mon_ok then
          monitor.start_polling()
        end
      end,
      on_complete = function()
        vim.notify("No Jenova CA found on LAN.", vim.log.levels.WARN, { title = "Jenova LAN" })
      end,
    })
  else
    vim.notify("Failed to load jenova.lan module", vim.log.levels.ERROR)
  end
end, { desc = "Scan LAN for remote Jenova CA instances" })

-- ##Step purpose: <leader>am — open backend monitor, <leader>ah — run checkhealth, <leader>al — LAN scan
map("n", "<leader>am", "<cmd>JenovaMonitor<CR>", { desc = "Jenova Monitor" })
map("n", "<leader>ah", "<cmd>checkhealth jenova<CR>", { desc = "Jenova Health" })
map("n", "<leader>al", "<cmd>JenovaLanScan<CR>", { desc = "Jenova LAN Scan" })

vim.api.nvim_create_user_command("IDE", function()
  require("jvim.layout").open_ide()
end, { desc = "Open IDE panels (jvim.layout coordinates tree + terminal + editor)" })
