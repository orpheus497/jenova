-- ##Script function and purpose: Configures all UI-layer plugins — Kanagawa colour
-- scheme (Dragon variant), lualine status bar, which-key keybind hints, noice.nvim
-- cmdline/message UI replacement, nvim-notify notification backend, and edgy.nvim
-- persistent panel layout (NvimTree + Trouble left, AI Chat right).
-- FIX B1: noice lsp.override key corrected to "vim.lsp.util.stylize_markdown".

return {

  -- ##Section purpose: kanagawa.nvim — colour scheme (Dragon variant: darkest)
  {
    "rebelot/kanagawa.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      require("kanagawa").setup({
        compile = false,
        undercurl = true,
        commentStyle = { italic = true },
        functionStyle = {},
        keywordStyle = { italic = true },
        statementStyle = { bold = true },
        typeStyle = {},
        transparent = false,
        dimInactive = false,
        terminalColors = true,
        colors = {
          palette = {},
          theme = { wave = {}, lotus = {}, dragon = {}, all = {} },
        },
        overrides = function(colors) return {} end,
        -- ##Step purpose: Dragon is the darkest variant — ideal for terminal sessions
        theme = "dragon",
      })
      vim.cmd("colorscheme kanagawa")
    end,
  },

  -- ##Section purpose: lualine.nvim — statusline with mode, branch, diagnostics
  {
    "nvim-lualine/lualine.nvim",
    opts = {
      options = {
        theme = "kanagawa",
        component_separators = "|",
        section_separators = { left = "", right = "" },
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
      vim.o.timeout = true
      vim.o.timeoutlen = 300
    end,
    opts = {
      -- ##Step purpose: Group labels for the major leader namespaces
      spec = {
        { "<leader>a", group = "AI" },
        { "<leader>b", group = "Buffer" },
        { "<leader>c", group = "Code" },
        { "<leader>f", group = "Find" },
        { "<leader>g", group = "Git" },
        { "<leader>r", group = "Rename" },
        { "<leader>w", group = "Windows" },
        { "<leader>x", group = "Diagnostics" },
      },
    },
  },

  -- ##Section purpose: nvim-notify — styled notification popups used by noice
  {
    "rcarriga/nvim-notify",
    opts = {
      timeout = 3000,
      render = "compact",
      stages = "fade",
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
          -- ##Step purpose: FIX B1 — correct function name for markdown rendering
          ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
          ["vim.lsp.util.stylize_markdown"] = true,
          ["cmp.entry.get_documentation"] = true,
        },
      },
      presets = {
        bottom_search = true,
        command_palette = true,
        long_message_to_split = true,
        inc_rename = false,
        lsp_doc_border = true,
      },
    },
  },

  -- ##Section purpose: edgy.nvim — persistent panel layout management
  -- Edgy owns the three-panel layout: NvimTree + Trouble left, AI Chat right
  {
    "folke/edgy.nvim",
    event = "VeryLazy",
    opts = {
      left = {
        {
          title = "Explorer",
          ft = "NvimTree",
          pinned = true,
          open = "NvimTreeOpen",
          size = { height = 0.5 },
        },
        {
          title = "Diagnostics",
          ft = "trouble",
          pinned = true,
          open = "Trouble diagnostics toggle filter.buf=0",
          size = { height = 0.5 },
        },
      },
      -- ##Step purpose: Right panel for AI Chat — gp.nvim chat buffers
      right = {
        {
          title = "AI Chat",
          ft = "markdown",
          -- ##Condition purpose: Only capture markdown buffers that are gp.nvim chats
          filter = function(buf)
            local name = vim.api.nvim_buf_get_name(buf)
            return name:match("/gp/") ~= nil
          end,
          pinned = true,
          size = { width = 0.3 },
        },
      },
    },
  },

}
