-- ##Script function and purpose: Editor-layer setup — file tree, fuzzy finder,
-- treesitter, diagnostics, indent guides, and format-on-save. Plugins are
-- vendored under jvim/runtime/pack/jenova/start/ and auto-loaded.

-- nvim-tree — file explorer sidebar
require("nvim-tree").setup({
  view = { side = "left", width = 30 },
  actions = { open_file = { window_picker = { enable = false } } },
  renderer = {
    highlight_opened_files = "all",
    icons = { show = { file = true, folder = true, folder_arrow = true, git = true } },
  },
  diagnostics = { enable = true, show_on_dirs = true },
})
vim.keymap.set("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle File Explorer" })

-- Telescope — fuzzy finder for files, buffers, grep
local telescope = require("telescope")
telescope.setup({
  defaults = {
    prompt_prefix = "   ",
    selection_caret = "  ",
  },
})
pcall(telescope.load_extension, "fzf")

vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files<CR>", { desc = "Find Files" })
vim.keymap.set("n", "<leader>fg", "<cmd>Telescope live_grep<CR>",  { desc = "Live Grep" })
vim.keymap.set("n", "<leader>fb", "<cmd>Telescope buffers<CR>",    { desc = "Buffers" })
vim.keymap.set("n", "<leader>fh", "<cmd>Telescope help_tags<CR>",  { desc = "Help Tags" })
vim.keymap.set("n", "<leader>fo", "<cmd>Telescope oldfiles<CR>",   { desc = "Recent Files" })
vim.keymap.set("n", "<leader>fd", "<cmd>Telescope diagnostics<CR>", { desc = "Diagnostics" })

-- nvim-treesitter — incremental syntax parsing and highlighting
do
  local ok, configs = pcall(require, "nvim-treesitter.configs")
  if not ok then configs = require("nvim-treesitter.config") end
  configs.setup({
    ensure_installed = {
      "c", "cpp", "rust", "go", "python", "zig",
      "bash", "lua", "luadoc", "vim", "vimdoc",
      "json", "yaml", "toml",
      "markdown", "markdown_inline",
    },
    highlight = { enable = true },
    indent = { enable = true },
  })
end

-- Trouble — pretty diagnostics, symbols, quickfix
require("trouble").setup({
  win = { type = "split", wo = { wrap = true } },
  modes = {
    diagnostics = {
      auto_preview = true,
      filter = { buf = 0 },
      groups = {},
    },
  },
})
vim.keymap.set("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>",                           { desc = "Workspace Diagnostics" })
vim.keymap.set("n", "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>",              { desc = "Buffer Diagnostics" })
vim.keymap.set("n", "<leader>cs", "<cmd>Trouble symbols toggle focus=false<CR>",                   { desc = "Symbols (Trouble)" })
vim.keymap.set("n", "<leader>cl", "<cmd>Trouble lsp toggle focus=false win.position=right<CR>",    { desc = "LSP Definitions / References" })
vim.keymap.set("n", "<leader>xq", "<cmd>Trouble qflist toggle<CR>",                                { desc = "Quickfix List" })
vim.keymap.set("n", "<leader>xl", "<cmd>Trouble loclist toggle<CR>",                               { desc = "Location List" })

-- indent-blankline — visual indent guide lines
require("ibl").setup()

-- conform.nvim — format-on-save with per-formatter existence checks
require("conform").setup({
  formatters_by_ft = {
    lua    = { "stylua" },
    python = { "isort", "black" },
    rust   = { "rustfmt" },
    go     = { "gofmt", "goimports" },
    c      = { "clang-format" },
    cpp    = { "clang-format" },
    sh     = { "shfmt" },
    bash   = { "shfmt" },
  },
  format_on_save = function(bufnr)
    if vim.api.nvim_buf_line_count(bufnr) > 5000 then return nil end
    local ok, conform = pcall(require, "conform")
    if not ok then return nil end
    local formatters = conform.list_formatters(bufnr)
    for _, f in ipairs(formatters) do
      if f.available then
        return { timeout_ms = 500, lsp_fallback = true }
      end
    end
    return nil
  end,
})
vim.keymap.set("n", "<leader>cf", function()
  require("conform").format({ async = true, lsp_fallback = true })
end, { desc = "Format Buffer" })
