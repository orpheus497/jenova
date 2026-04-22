-- ##Script function and purpose: Main Neovim entry point — bootstraps lazy.nvim, sets
-- global editor options, loads modular plugin configs, and wires master keybinds
-- for the Jenova FreeBSD IDE environment.

-- ========================================================================== --
--  ULTIMATE MASTERCRAFTER FREEBSD 15.0 NEOVIM IDE (MODULAR EDITION)
-- ========================================================================== --

-- ##Section purpose: PATH RECTIFICATION — Prepend FreeBSD local site directory so
-- luarocks and site-local packages are found before anything else
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/site")

--------------------------------------------------------------------------------
-- [2] NATIVE PACKAGE LOADING
--------------------------------------------------------------------------------
-- ##Section purpose: All plugins are vendored under jvim/runtime/pack/jenova/start/
-- and loaded by Neovim's native packpath at startup. No external plugin manager
-- (no lazy.nvim, no packer) — everything ships with jvim.
--
-- Disable a few rarely-used built-ins for faster startup, matching the prior
-- lazy.nvim performance.rtp.disabled_plugins set.
-- Also disable jvim's bundled first-party UI plugins (jvim_ui, jvim_dashboard) —
-- they conflict with the vendored nvim-tree/telescope/lualine/etc. stack and
-- contain the E5108 'Invalid col: out of range' bug in jvim/tree.lua:140.
for _, name in ipairs({
  "gzip", "matchit", "matchparen", "netrwPlugin",
  "tarPlugin", "tohtml", "tutor", "zipPlugin",
  "jvim_ui", "jvim_dashboard",
}) do
  vim.g["loaded_" .. name] = 1
end

-- nvim-tree clears netrw's FileExplorer autocmd group to take over file:// URIs.
-- We disabled netrw above, so the group never gets created and `autocmd! FileExplorer *`
-- raises E216. Pre-create an empty group so the clear is a no-op.
vim.api.nvim_create_augroup("FileExplorer", { clear = true })

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
-- [4] PLUGIN CONFIGURATION
--------------------------------------------------------------------------------
-- ##Section purpose: Plugins themselves are auto-discovered by packpath; these
-- modules carry only the .setup() calls and Jenova-specific keymaps.
for _, mod in ipairs({
  "plugins.ui",
  "plugins.editor",
  "plugins.lsp",
  "plugins.git",
  "plugins.mini",
  "plugins.dashboard",
  "plugins.llama",
  "plugins.chat",
  "plugins.health",
}) do
  local ok, err = pcall(require, mod)
  if not ok then
    vim.notify(("Failed to load %s: %s"):format(mod, err), vim.log.levels.WARN)
  end
end

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

-- ##Action purpose: Launch Jenova CLI agent in a terminal split.
-- Uses $JENOVA_ROOT env var (set by jenova.conf / jvim); falls back to ~/Projects/jenova
-- so the binding works on a fresh clone where the variable may not yet be exported.
vim.keymap.set('n', '<leader>aj', function()
  local root = vim.fn.expand("$JENOVA_ROOT")
  if root == "" or root == "$JENOVA_ROOT" then
    root = vim.fn.expand("~/Projects/jenova")
  end
  vim.cmd("term cd " .. vim.fn.shellescape(root) .. " && bin/jenova")
end, { desc = "Jenova Agent Terminal" })

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
-- Deferred 1.5s so the notification fires after noice.nvim is fully initialised.
-- Backend status is cached in vim.g.jenova_connected for lualine status component.
-- The jenova.monitor module handles periodic polling and provides data to lualine.
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
  -- ##Condition purpose: If on dashboard, close it first
  if vim.bo.filetype == "alpha" then
    vim.cmd("bd")
  end
  -- ##Step purpose: Open NvimTree — Edgy intercepts and docks it left
  vim.cmd("NvimTreeOpen")
end, { desc = "Open IDE panels (Edgy auto-manages layout)" })
