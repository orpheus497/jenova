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

-- ##Action purpose: Launch Jenova CLI agent in a terminal split
-- FIX B2: Changed from <leader>ca to <leader>aj to avoid collision with LSP code action
vim.keymap.set('n', '<leader>aj', '<cmd>term cd ~/Projects/jenova && bin/jenova<CR>', { desc = "Jenova Agent Terminal" })

--------------------------------------------------------------------------------
-- [6] IDE THREE-PANEL LAYOUT COMMAND
--------------------------------------------------------------------------------
-- ##Section purpose: :IDE user command — opens NvimTree + Trouble + GpChat vsplit
vim.api.nvim_create_user_command("IDE", function()
  -- ##Condition purpose: If we are on the dashboard, close it first so it doesn't
  -- occupy the main window when the three-panel layout is built
  if vim.bo.filetype == "alpha" then
    vim.cmd("bd")
  end

  -- ##Step purpose: Save reference to the main window before panels open
  local main_win = vim.api.nvim_get_current_win()

  -- ##Step purpose: Open left-side panels (NvimTree file explorer + Trouble diagnostics)
  vim.cmd("NvimTreeOpen")
  -- Open Trouble locked to the current buffer only (not workspace)
  vim.cmd("Trouble diagnostics toggle filter.buf=0")

  -- ##Step purpose: Return focus to the main editor centre pane
  vim.api.nvim_set_current_win(main_win)

  -- ##Step purpose: Open GpChat vsplit for the full file as AI context
  vim.cmd("1,$GpChatNew vsplit")

  -- ##Step purpose: Force focus back to main window one last time
  vim.api.nvim_set_current_win(main_win)
end, { desc = "Start Three-Panel IDE Layout" })
