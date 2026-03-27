-- ##Script function and purpose: Configures mini.nvim utility modules — mini.ai for
-- better around/inside textobjects, mini.surround for bracket operations, mini.pairs
-- for auto-pairing, mini.comment for toggling comments, mini.bufremove for safe buffer
-- deletion, and mini.icons which replaces nvim-web-devicons.

return {
  -- ##Section purpose: Disable nvim-web-devicons — mini.icons mocks it in memory
  { "nvim-tree/nvim-web-devicons", enabled = false },

  -- ##Section purpose: mini.nvim — collection of small independent Lua modules
  {
    "echasnovski/mini.nvim",
    version = false,
    config = function()
      -- ##Step purpose: mini.ai — enhanced around/inside textobjects
      require("mini.ai").setup({ n_lines = 500 })

      -- ##Step purpose: mini.surround — add/delete/replace surroundings
      require("mini.surround").setup()

      -- ##Step purpose: mini.pairs — auto-close brackets and quotes
      require("mini.pairs").setup()

      -- ##Step purpose: mini.comment — gc to toggle line/block comments
      require("mini.comment").setup()

      -- ##Step purpose: mini.bufremove — safe buffer deletion preserving window layout
      require("mini.bufremove").setup()
      vim.keymap.set("n", "<leader>bd", function()
        require("mini.bufremove").delete(0, false)
      end, { desc = "Delete Buffer" })
      vim.keymap.set("n", "<leader>bD", function()
        require("mini.bufremove").delete(0, true)
      end, { desc = "Delete Buffer (Force)" })

      -- ##Step purpose: mini.icons — lightweight icon provider that replaces
      -- nvim-web-devicons (satisfies all require("nvim-web-devicons") calls)
      require("mini.icons").setup()
      require("mini.icons").mock_nvim_web_devicons()
    end,
  },
}
