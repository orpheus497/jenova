-- ##Script function and purpose: UI plugin setup. Plugins themselves ship inside
-- jvim/runtime/pack/jenova/start/ and are auto-loaded by packpath; this module
-- only carries the configuration calls that used to live inside lazy specs.

-- Kanagawa colour scheme (Dragon variant: darkest)
require("kanagawa").setup({
  compile = false,
  undercurl = true,
  commentStyle = { italic = true },
  keywordStyle = { italic = true },
  statementStyle = { bold = true },
  transparent = false,
  dimInactive = false,
  terminalColors = true,
  theme = "dragon",
})
vim.cmd("colorscheme kanagawa-dragon")

-- lualine.nvim — statusline with mode, branch, diagnostics, AI status
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
      {
        function()
          if monitor then return monitor.lualine_status() end
          if vim.g.jenova_connected then return "AI: on" end
          return "AI: off"
        end,
        color = function()
          return { fg = vim.g.jenova_connected and "#98BB6C" or "#FF5D62" }
        end,
      },
      "encoding", "filetype",
    },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
})

-- which-key.nvim — popup keybind hint overlay
vim.o.timeout = true
vim.o.timeoutlen = 300
require("which-key").setup({
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
})

-- nvim-notify — styled notification popups (consumed by noice)
local notify = require("notify")
notify.setup({
  timeout = 3000,
  render = "compact",
  stages = "fade",
})
vim.notify = notify

-- noice.nvim — replaces cmdline, messages, and popupmenu UI
require("noice").setup({
  lsp = {
    override = {
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
})
-- Telescope notify extension — load once telescope is available
pcall(function() require("telescope").load_extension("notify") end)

-- edgy.nvim — persistent panel layout (NvimTree + Trouble left, AI Chat right)
require("edgy").setup({
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
  right = {
    {
      title = "AI Chat",
      ft = "markdown",
      filter = function(buf)
        local name = vim.api.nvim_buf_get_name(buf)
        return name:match("/jenova/chats/") ~= nil
      end,
      pinned = true,
      size = { width = 0.3 },
    },
  },
})
