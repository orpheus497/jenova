-- ##Script function and purpose: Configures core editor plugins — NvimTree file
-- explorer, Telescope fuzzy finder, nvim-treesitter syntax, Trouble diagnostics,
-- indent-blankline guides, and conform.nvim code formatting.

return {

  -- ##Section purpose: nvim-tree — file explorer sidebar
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      { "<leader>e", "<cmd>NvimTreeToggle<CR>",  desc = "Toggle File Explorer" },
      { "<leader>E", "<cmd>NvimTreeFocus<CR>",   desc = "Focus File Explorer" },
    },
    opts = {
      view = { width = 32 },
      renderer = {
        group_empty = true,
        icons = { show = { git = true, folder = true, file = true } },
      },
      filters = { dotfiles = false },
      git = { enable = true, ignore = false },
    },
  },

  -- ##Section purpose: Telescope — fuzzy finder for files, buffers, grep
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<CR>",  desc = "Find Files" },
      { "<leader>fg", "<cmd>Telescope live_grep<CR>",   desc = "Live Grep" },
      { "<leader>fb", "<cmd>Telescope buffers<CR>",     desc = "Buffers" },
      { "<leader>fh", "<cmd>Telescope help_tags<CR>",   desc = "Help Tags" },
      { "<leader>fo", "<cmd>Telescope oldfiles<CR>",    desc = "Recent Files" },
      { "<leader>fd", "<cmd>Telescope diagnostics<CR>", desc = "Diagnostics" },
    },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          prompt_prefix = "   ",
          selection_caret = "  ",
          layout_config = { horizontal = { preview_width = 0.55 } },
        },
      })
      -- ##Action purpose: Load fzf sorter for faster fuzzy matching (pcall so Telescope
      -- still works if telescope-fzf-native fails to build or isn't installed)
      pcall(telescope.load_extension, "fzf")
    end,
  },

  -- ##Section purpose: nvim-treesitter — incremental syntax parsing and highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      ensure_installed = {
        "lua", "luadoc", "vim", "vimdoc",
        "bash", "c", "cpp", "python",
        "json", "yaml", "toml", "markdown",
      },
      highlight = { enable = true },
      indent = { enable = true },
    },
    config = function(_, opts)
      require("nvim-treesitter.configs").setup(opts)
    end,
  },

  -- ##Section purpose: Trouble — pretty diagnostics and quickfix list
  {
    "folke/trouble.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      { "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>",              desc = "Workspace Diagnostics" },
      { "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", desc = "Buffer Diagnostics" },
      { "<leader>xq", "<cmd>Trouble qflist toggle<CR>",                   desc = "Quickfix List" },
      { "<leader>xl", "<cmd>Trouble loclist toggle<CR>",                  desc = "Location List" },
    },
    opts = { use_diagnostic_signs = true },
  },

  -- ##Section purpose: indent-blankline — visual indent guide lines
  {
    "lukas-reineke/indent-blankline.nvim",
    event = { "BufReadPost", "BufNewFile" },
    main = "ibl",
    opts = {
      indent = { char = "│" },
      scope = { enabled = true },
    },
  },

  -- ##Section purpose: conform.nvim — lightweight, async code formatter
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
        lua    = { "stylua" },
        python = { "black" },
        sh     = { "shfmt" },
      },
      format_on_save = { timeout_ms = 500, lsp_fallback = true },
    },
  },

}
