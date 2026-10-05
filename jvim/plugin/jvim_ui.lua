-- jvim_ui — autoload native UI modules at startup.
-- This file replaces all third-party UI plugins by wiring jvim's first-party
-- modules unconditionally (Wave 1 + Wave 2 of the native conversion).
--
-- Modules wired here (all under `runtime/lua/jvim/`):
--   icons             — file/filetype glyphs + nvim-web-devicons in-memory shim
--   ui                — vim.ui.input/select overrides (replaces dressing.nvim)
--   notify            — floating notification queue (replaces nvim-notify)
--   messages          — :messages mirror routed through jvim.notify
--   statusline        — global statusline (replaces lualine.nvim)
--   tabline           — buffer tabline (replaces bufferline-style plugins)
--   keyhelp           — leader-prefix popup (replaces which-key.nvim)
--   indent_guides     — extmark indent guides (replaces indent-blankline.nvim)
--   tree              — file explorer (replaces nvim-tree.lua)
--   finder            — fuzzy finder (replaces telescope.nvim + plenary + fzf-native)
--   diagnostics_list  — workspace diagnostics list (replaces trouble.nvim)
--   layout            — IDE panel layout (replaces edgy.nvim)
--   terminal          — bottom terminal (already first-party)
--   dashboard         — start screen (already first-party)
--
-- Removed third-party plugins:
--   kanagawa.nvim, lualine.nvim, which-key.nvim, indent-blankline.nvim,
--   mini.comment, mini.bufremove, mini.icons, nvim-web-devicons,
--   nvim-tree.lua, telescope.nvim (+plenary, +fzf-native), trouble.nvim,
--   edgy.nvim, noice.nvim, nvim-notify.

if vim.g.loaded_jvim_ui then return end
vim.g.loaded_jvim_ui = 1

-- ##Step: Install nvim-web-devicons compat shim FIRST so any plugin loaded
-- later by lazy.nvim that requires("nvim-web-devicons") gets jvim's icons.
pcall(function() require("jvim.icons").install_devicons_shim() end)

-- ##Step: vim.ui.input / vim.ui.select overrides — installed early so any
-- plugin that prompts during setup uses our floating UI.
pcall(function() require("jvim.ui").setup() end)

-- ##Step: Native notifier + messages mirror. Installed BEFORE colorscheme
-- so any colorscheme load errors are visible via jvim.notify.
pcall(function() require("jvim.notify").setup() end)
pcall(function() require("jvim.messages").setup() end)

-- ##Step: Apply native colorscheme. Wrapped in pcall so that running with
-- a stripped runtimepath (tests, headless) does not abort init.
pcall(vim.cmd, "colorscheme jvim")

-- ##Step: Native statusline + tabline.
pcall(function() require("jvim.statusline").setup() end)
pcall(function() require("jvim.tabline").setup() end)

-- ##Step: Native indent guides.
pcall(function() require("jvim.indent_guides").setup() end)

-- ##Step: Native key-help popup with the same group labels which-key used.
pcall(function()
  require("jvim.keyhelp").setup({
    groups = {
      { "<leader>a", group = "AI" },
      { "<leader>am", group = "AI Management" },
      { "<leader>at", group = "AI Tools" },
      { "<leader>b", group = "Buffer" },
      { "<leader>c", group = "Code" },
      { "<leader>f", group = "Find" },
      { "<leader>g", group = "Git" },
      { "<leader>r", group = "Rename" },
      { "<leader>t", group = "Terminal" },
      { "<leader>W", group = "Windows" },
      { "<leader>x", group = "Diagnostics" },
    },
  })
end)

-- ##Step: File explorer + fuzzy finder + diagnostics list + layout coordinator.
pcall(function() require("jvim.tree").setup() end)
pcall(function() require("jvim.finder").setup() end)
pcall(function() require("jvim.diagnostics_list").setup() end)
pcall(function() require("jvim.layout").setup() end)

-- ##Step: Native commenting. Neovim 0.10+ ships a built-in `gc`/`gcc`
-- toggle (see :h commenting) so mini.comment is no longer needed; we just
-- expose the convenience <leader>/ alias mini.comment users expect.
vim.keymap.set("n", "<leader>/", "gcc",
  { remap = true, silent = true, desc = "Toggle comment (line)" })
vim.keymap.set("x", "<leader>/", "gc",
  { remap = true, silent = true, desc = "Toggle comment (selection)" })

-- ##Step: File-tree toggle (replaces NvimTreeToggle).
vim.keymap.set("n", "<leader>e", function() require("jvim.tree").toggle() end,
  { silent = true, desc = "Toggle file explorer" })

-- ##Step: Finder mappings (replace Telescope keymaps).
vim.keymap.set("n", "<leader>ff", function() require("jvim.finder").files() end,
  { silent = true, desc = "Find files" })
vim.keymap.set("n", "<leader>fg", function() require("jvim.finder").grep() end,
  { silent = true, desc = "Live grep" })
vim.keymap.set("n", "<leader>fb", function() require("jvim.finder").buffers() end,
  { silent = true, desc = "Find buffers" })
vim.keymap.set("n", "<leader>fh", function() require("jvim.finder").help_tags() end,
  { silent = true, desc = "Find help" })
vim.keymap.set("n", "<leader>fo", function() require("jvim.finder").oldfiles() end,
  { silent = true, desc = "Recent files" })
vim.keymap.set("n", "<leader>fd", function() require("jvim.finder").diagnostics() end,
  { silent = true, desc = "Find diagnostics" })

-- ##Step: Diagnostics list (replace Trouble keymaps).
vim.keymap.set("n", "<leader>xx", function()
  require("jvim.diagnostics_list").toggle({ scope = "workspace" })
end, { silent = true, desc = "Workspace diagnostics" })
vim.keymap.set("n", "<leader>xb", function()
  require("jvim.diagnostics_list").toggle({ scope = "buffer" })
end, { silent = true, desc = "Buffer diagnostics" })
vim.keymap.set("n", "<leader>xq", "<cmd>copen<CR>",
  { silent = true, desc = "Quickfix list" })
vim.keymap.set("n", "<leader>xl", "<cmd>lopen<CR>",
  { silent = true, desc = "Location list" })

-- ##Step: Buffer deletion that preserves the window layout — direct
-- replacement for mini.bufremove. Implemented inline because it is a
-- ~25-line algorithm.
local function buf_remove(force)
  local target = vim.api.nvim_get_current_buf()
  if vim.bo[target].modified and not force then
    vim.notify("Buffer modified — use <leader>bD to force", vim.log.levels.WARN)
    return
  end
  -- Find an alternate buffer to swap into every window currently showing
  -- `target` so that closing the buffer never closes the window itself.
  local function alt_for(win)
    local cur = vim.api.nvim_win_get_buf(win)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= cur and b ~= target and vim.api.nvim_buf_is_loaded(b)
          and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
        return b
      end
    end
    -- Fallback: a fresh empty buffer.
    return vim.api.nvim_create_buf(true, false)
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == target then
      pcall(vim.api.nvim_win_set_buf, win, alt_for(win))
    end
  end
  if vim.api.nvim_buf_is_valid(target) then
    pcall(vim.api.nvim_buf_delete, target, { force = force })
  end
end
vim.keymap.set("n", "<leader>bd", function() buf_remove(false) end,
  { silent = true, desc = "Delete Buffer" })
vim.keymap.set("n", "<leader>bD", function() buf_remove(true) end,
  { silent = true, desc = "Delete Buffer (Force)" })

-- ##Step: Dashboard keymaps
vim.keymap.set("n", "<leader>h", "<cmd>JvimDashboard<CR>",
  { silent = true, desc = "Dashboard / Home" })

-- ##Step: Terminal keymaps (jvim.terminal).
vim.keymap.set("n", "<leader>tt", function() require("jvim.terminal").toggle_shell() end,
  { silent = true, desc = "Toggle Shell Terminal" })
vim.keymap.set("n", "<leader>tn", function() require("jvim.terminal").new_shell() end,
  { silent = true, desc = "New Shell Terminal" })
vim.keymap.set("n", "<leader>atj", function() require("jvim.terminal").toggle_jenova() end,
  { silent = true, desc = "Toggle Jenova Terminal" })
vim.keymap.set("n", "<leader>ti", function() require("jvim.layout").open_ide() end,
  { silent = true, desc = "Open IDE layout" })
