-- ##Script function and purpose: Configures core editor plugins — NvimTree file
-- explorer, Telescope fuzzy finder, nvim-treesitter syntax, Trouble diagnostics,
-- indent-blankline guides, and conform.nvim code formatting.

return {

  -- ##Section purpose: nvim-tree — file explorer sidebar
  {
    "nvim-tree/nvim-tree.lua",
    cmd = { "NvimTreeToggle", "NvimTreeOpen", "NvimTreeFocus", "NvimTreeFindFileToggle" },
    keys = {
      { "<leader>e", "<cmd>NvimTreeToggle<CR>", desc = "Toggle File Explorer" },
    },
    config = function()
      require("nvim-tree").setup({
        -- ##Step purpose: Explorer opens on the left at 30 columns
        view = { side = "left", width = 30 },
        -- ##Step purpose: Disable window picker to prevent interference with panel layout
        actions = { open_file = { window_picker = { enable = false } } },
        renderer = {
          -- ##Step purpose: Highlight opened files in the tree for visual context
          highlight_opened_files = "all",
          icons = { show = { file = true, folder = true, folder_arrow = true, git = true } },
        },
        -- ##Step purpose: Show LSP diagnostics on directory nodes
        diagnostics = { enable = true, show_on_dirs = true },
      })
    end,
  },

  -- ##Section purpose: Telescope — fuzzy finder for files, buffers, grep
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      -- ##Step purpose: gmake is required on FreeBSD (GNU Make is not 'make')
      { "nvim-telescope/telescope-fzf-native.nvim", build = "gmake" },
    },
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Find Files" },
      { "<leader>fg", "<cmd>Telescope live_grep<CR>", desc = "Live Grep" },
      { "<leader>fb", "<cmd>Telescope buffers<CR>", desc = "Buffers" },
      { "<leader>fh", "<cmd>Telescope help_tags<CR>", desc = "Help Tags" },
      { "<leader>fo", "<cmd>Telescope oldfiles<CR>", desc = "Recent Files" },
      { "<leader>fd", "<cmd>Telescope diagnostics<CR>", desc = "Diagnostics" },
    },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          prompt_prefix = "   ",
          selection_caret = "  ",
        },
      })
      -- ##Action purpose: Load fzf sorter (pcall in case it failed to build)
      pcall(telescope.load_extension, "fzf")
    end,
  },

  -- ##Section purpose: nvim-treesitter — incremental syntax parsing and highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      -- ##Step purpose: Install parsers for all languages used in Jenova development
      ensure_installed = {
        "c", "cpp", "rust", "go", "python", "zig",
        "bash", "lua", "luadoc", "vim", "vimdoc",
        "json", "yaml", "toml",
        "markdown", "markdown_inline",
      },
      highlight = { enable = true },
      indent = { enable = true },
    },
    config = function(_, opts)
      -- ##Step purpose: Defensive pcall handles API name change between treesitter versions
      local ok, configs = pcall(require, "nvim-treesitter.configs")
      if not ok then configs = require("nvim-treesitter.config") end
      configs.setup(opts)
    end,
  },

  -- ##Section purpose: Trouble — pretty diagnostics, symbols, quickfix
  {
    "folke/trouble.nvim",
    cmd = { "Trouble" },
    opts = {
      -- ##Step purpose: Enable text wrapping so long diagnostic messages are not clipped
      win = { type = "split", wo = { wrap = true } },
      modes = {
        diagnostics = {
          auto_preview = true,
          -- ##Step purpose: Only show diagnostics for the currently open buffer
          filter = { buf = 0 },
          -- ##Step purpose: Flat list of errors, not grouped by file
          groups = {},
        },
      },
    },
    keys = {
      { "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", desc = "Workspace Diagnostics" },
      { "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", desc = "Buffer Diagnostics" },
      { "<leader>cs", "<cmd>Trouble symbols toggle focus=false<CR>", desc = "Symbols (Trouble)" },
      { "<leader>cl", "<cmd>Trouble lsp toggle focus=false win.position=right<CR>", desc = "LSP Definitions / References" },
      { "<leader>xq", "<cmd>Trouble qflist toggle<CR>", desc = "Quickfix List" },
      { "<leader>xl", "<cmd>Trouble loclist toggle<CR>", desc = "Location List" },
    },
  },

  -- ##Section purpose: indent-blankline — visual indent guide lines
  {
    "lukas-reineke/indent-blankline.nvim",
    event = { "BufReadPost", "BufNewFile" },
    main = "ibl",
    opts = {},
  },

  -- ##Section purpose: conform.nvim — format-on-save with FreeBSD-available formatters
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    keys = {
      {
        "<leader>cf",
        function() require("conform").format({ async = true, lsp_fallback = true }) end,
        desc = "Format Buffer",
      },
    },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
        python = { "isort", "black" },
        rust = { "rustfmt" },
        go = { "gofmt", "goimports" },
        c = { "clang-format" },
      },
      format_on_save = { timeout_ms = 500, lsp_fallback = true },
    },
  },

}
