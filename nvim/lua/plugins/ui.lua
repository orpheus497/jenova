-- ##Script function and purpose: Configures all UI-layer plugins — Kanagawa colour
-- scheme, lualine status bar, which-key keybind hints, noice.nvim cmdline/message
-- UI replacement, nvim-notify notification backend, and edgy.nvim panel layout.
-- FIX B1: noice lsp.override key corrected from "vim.lsp.util.styled_pa_lines"
--         to "vim.lsp.util.stylize_markdown" so hover windows render markdown.

return {

  -- ##Section purpose: kanagawa.nvim — colour scheme (Wave variant)
  {
    "rebelot/kanagawa.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      require("kanagawa").setup({
        transparent = false,
        theme = "wave",
        colors = { theme = { all = { ui = { bg_gutter = "none" } } } },
      })
      vim.cmd("colorscheme kanagawa")
    end,
  },

  -- ##Section purpose: lualine.nvim — statusline with mode, branch, diagnostics
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        theme = "kanagawa",
        component_separators = "|",
        section_separators   = { left = "", right = "" },
        globalstatus = true,
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "encoding", "fileformat", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },

  -- ##Section purpose: which-key.nvim — popup keybind hint overlay
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    init = function()
      vim.o.timeout    = true
      vim.o.timeoutlen = 300
    end,
    opts = {
      -- ##Step purpose: Group labels for the major leader namespaces
      spec = {
        { "<leader>a", group = "AI" },
        { "<leader>c", group = "Code" },
        { "<leader>f", group = "Find" },
        { "<leader>g", group = "Git" },
        { "<leader>b", group = "Buffer" },
        { "<leader>x", group = "Diagnostics" },
        { "<leader>w", group = "Windows" },
      },
    },
  },

  -- ##Section purpose: nvim-notify — styled notification popups used by noice
  {
    "rcarriga/nvim-notify",
    opts = {
      timeout = 3000,
      render  = "compact",
      stages  = "fade",
    },
  },

  -- ##Section purpose: noice.nvim — replaces cmdline, messages, and popupmenu UI
  {
    "folke/noice.nvim",
    event = "VeryLazy",
    dependencies = { "MunifTanjim/nui.nvim", "rcarriga/nvim-notify" },
    opts = {
      lsp = {
        override = {
          -- FIX B1: Was "vim.lsp.util.styled_pa_lines" (typo) — now correctly set
          -- so hover windows render markdown syntax highlighting
          ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
          ["vim.lsp.util.stylize_markdown"]                = true,
          ["cmp.entry.get_documentation"]                  = true,
        },
      },
      presets = {
        bottom_search         = true,
        command_palette       = true,
        long_message_to_split = true,
        inc_rename            = false,
        lsp_doc_border        = true,
      },
    },
  },

  -- ##Section purpose: edgy.nvim — persistent panel layout (NvimTree, Trouble)
  {
    "folke/edgy.nvim",
    event = "VeryLazy",
    opts = {
      left = {
        {
          title = "Explorer",
          ft    = "NvimTree",
          size  = { width = 32 },
        },
        {
          title = "Diagnostics",
          ft    = "trouble",
          size  = { height = 0.3 },
        },
      },
    },
  },

}
