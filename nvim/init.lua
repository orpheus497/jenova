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
-- ##Section purpose: Load all plugin specs from nvim/lua/plugins/ via lazy.nvim
require("lazy").setup("plugins", {
  defaults = { lazy = false },
  install = { colorscheme = { "kanagawa" } },
  rocks = { enabled = false }, -- Fix for FreeBSD libc/rocks conflict
  ui = { border = "rounded" },
  performance = {
    rtp = {
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
    callback(false)
    return
  end
  local host = vim.env.JENOVA_CONNECT_HOST or "127.0.0.1"
  local port = tonumber(vim.env.JENOVA_PORT or "8080")
  local tcp = uv.new_tcp()
  if not tcp then
    callback(false)
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
    timeout:start(2000, 0, function()
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
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.defer_fn(function()
      _jenova_tcp_probe(function(connected)
        vim.g.jenova_connected = connected
        if not connected then
          vim.notify(
            "Jenova CA backend not running. AI features unavailable.\n" ..
            "Run:  jvim somefile.lua   OR   bin/llama-server-nvim",
            vim.log.levels.WARN,
            { title = "Jenova" }
          )
        end
      end)
    end, 1500)
  end,
  once = true,
})

-- ##Section purpose: Periodic backend health refresh every 30s
-- Updates vim.g.jenova_connected so the lualine status component stays current.
vim.g.jenova_connected = false  -- initialise pessimistically
local _init_uv = vim.uv or vim.loop
local _jenova_timer = _init_uv and _init_uv.new_timer()
if _jenova_timer then
  _jenova_timer:start(5000, 30000, vim.schedule_wrap(function()
    _jenova_tcp_probe(function(connected)
      vim.g.jenova_connected = connected
    end)
  end))
end

--------------------------------------------------------------------------------
-- [7] IDE PANEL OPENER
--------------------------------------------------------------------------------
-- ##Section purpose: :IDE user command — opens NvimTree, Edgy auto-manages layout
-- FIX F1: Removed manual panel management that raced with Edgy. Edgy now owns
-- the three-panel layout (NvimTree + Trouble left, AI Chat right).
vim.api.nvim_create_user_command("IDE", function()
  -- ##Condition purpose: If on dashboard, close it first
  if vim.bo.filetype == "alpha" then
    vim.cmd("bd")
  end
  -- ##Step purpose: Open NvimTree — Edgy intercepts and docks it left
  vim.cmd("NvimTreeOpen")
end, { desc = "Open IDE panels (Edgy auto-manages layout)" })
