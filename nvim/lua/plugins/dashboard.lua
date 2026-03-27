-- ##Script function and purpose: Configures alpha-nvim dashboard — displayed on
-- Neovim startup with a custom header, quick-access buttons, and session stats.

return {
  -- ##Section purpose: alpha-nvim — greeter / startup dashboard
  {
    "goolord/alpha-nvim",
    dependencies = { "nvim-web-devicons" },
    config = function()
      local alpha = require("alpha")
      local dashboard = require("alpha.themes.dashboard")

      -- ##Step purpose: ASCII art header for the Jenova IDE dashboard
      dashboard.section.header.val = {
        "                                                     ",
        "  ██╗███████╗███╗   ██╗ ██████╗ ██╗   ██╗ █████╗   ",
        "  ██║██╔════╝████╗  ██║██╔═══██╗██║   ██║██╔══██╗  ",
        "  ██║█████╗  ██╔██╗ ██║██║   ██║██║   ██║███████║  ",
        "  ██║██╔══╝  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║  ",
        "  ██║███████╗██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║  ",
        "  ╚═╝╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝  ",
        "                                                     ",
        "         Jenova Cognitive Architecture — IDE         ",
        "                                                     ",
      }

      -- ##Step purpose: Quick-action buttons shown below the header
      dashboard.section.buttons.val = {
        dashboard.button("e", "  New File",        "<cmd>ene<CR>"),
        dashboard.button("f", "  Find File",       "<cmd>Telescope find_files<CR>"),
        dashboard.button("r", "  Recent Files",    "<cmd>Telescope oldfiles<CR>"),
        dashboard.button("g", "  Live Grep",       "<cmd>Telescope live_grep<CR>"),
        dashboard.button("s", "  Restore Session", "<cmd>SessionRestore<CR>"),
        dashboard.button("l", "  Lazy",            "<cmd>Lazy<CR>"),
        dashboard.button("q", "  Quit",            "<cmd>qa<CR>"),
      }

      -- ##Step purpose: Footer line showing plugin count after lazy finishes loading
      local function footer()
        local stats = require("lazy").stats()
        return string.format(
          "  %d plugins loaded in %.2f ms",
          stats.count,
          (stats.startuptime or 0)
        )
      end

      dashboard.section.footer.val = footer()

      -- ##Step purpose: Apply layout and register with alpha
      dashboard.opts.layout = {
        { type = "padding", val = 2 },
        dashboard.section.header,
        { type = "padding", val = 2 },
        dashboard.section.buttons,
        { type = "padding", val = 1 },
        dashboard.section.footer,
      }

      alpha.setup(dashboard.opts)
    end,
  },
}
