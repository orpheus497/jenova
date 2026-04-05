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
        -- Dragon provides dark background with red/black/grey color palette
        theme = "dragon",
      })
      -- ##Step purpose: Explicitly load kanagawa-dragon variant
      vim.cmd("colorscheme kanagawa-dragon")
    end,
  },

  -- ##Section purpose: lualine.nvim — statusline with mode, branch, diagnostics, AI status
  -- Enhanced: Shows model name, slot usage, service health icons, and connection state.
  -- Uses jenova.monitor module for real-time backend data.
  {
    "nvim-lualine/lualine.nvim",
    config = function()
      -- Cache monitor module reference once (avoids repeated pcall on every render)
      local mon_ok, monitor = pcall(require, "jenova.monitor")
      if not mon_ok then monitor = nil end

      require("lualine").setup({
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
          lualine_x = {
            -- ##Step purpose: Service health icons — [PLE] = Proxy/Llama/Embed
            -- Uppercase = online, lowercase = offline
            {
              function()
                if monitor then return monitor.service_icons() end
                return ""
              end,
              color = function()
                if monitor and monitor.state.proxy_ok and monitor.state.llama_ok then
                  return { fg = "#98BB6C" }
                elseif monitor and (monitor.state.proxy_ok or monitor.state.llama_ok) then
                  return { fg = "#DCA561" }
                end
                return { fg = "#FF5D62" }
              end,
            },
            -- ##Step purpose: Model name and slot status from live backend data
            {
              function()
                if monitor then return monitor.lualine_status() end
                if vim.g.jenova_connected then return "AI: on" end
                return "AI: off"
              end,
              color = function()
                return {
                  fg = vim.g.jenova_connected and "#98BB6C" or "#FF5D62",
                }
              end,
            },
            "encoding", "filetype",
          },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
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
  -- PR #23: Telescope notify extension loading deferred until Telescope is ready.
  -- Previously pcall(require("telescope").load_extension, "notify") ran at notify
  -- config time but Telescope is lazy-loaded later, so the extension silently failed.
  {
    "rcarriga/nvim-notify",
    opts = {
      timeout = 3000,
      render = "compact",
      stages = "fade",
    },
    config = function(_, opts)
      local notify = require("notify")
      notify.setup(opts)
      vim.notify = notify

      -- ##Step purpose: Defer Telescope notify extension registration until Telescope
      -- is actually loaded. The autocmd group is deleted once telescope fires so it
      -- does not run on every subsequent LazyLoad event.
      -- Augroup with clear=true prevents duplicate autocmds if this file is re-sourced.
      local group = vim.api.nvim_create_augroup("NotifyTelescopeLoad", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LazyLoad",
        callback = function(ev)
          if ev.data == "telescope.nvim" then
            pcall(require("telescope").load_extension, "notify")
            vim.api.nvim_del_augroup_by_name("NotifyTelescopeLoad")
          end
        end,
      })
    end,
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
