-- ##Script function and purpose: Configures mini.nvim utility modules — mini.pairs
-- for auto-pairing brackets/quotes, mini.comment for toggling comments, mini.surround
-- for surround operations, and mini.statusline as a lightweight fallback statusline.

return {
  -- ##Section purpose: mini.nvim — collection of small independent Lua modules
  {
    "echasnovski/mini.nvim",
    version = false,
    config = function()
      -- ##Step purpose: mini.pairs — auto-close brackets, parens, quotes
      require("mini.pairs").setup()

      -- ##Step purpose: mini.comment — gc to toggle line/block comments
      require("mini.comment").setup()

      -- ##Step purpose: mini.surround — ys, ds, cs surround operations (vim-surround style)
      require("mini.surround").setup({
        mappings = {
          add            = "ys",
          delete         = "ds",
          find           = "fs",
          find_left      = "Fs",
          highlight      = "hs",
          replace        = "cs",
          update_n_lines = "ns",
        },
      })

      -- ##Step purpose: mini.bufremove — safe buffer deletion that keeps window layout
      require("mini.bufremove").setup()
      vim.keymap.set("n", "<leader>bd", function()
        require("mini.bufremove").delete(0, false)
      end, { desc = "Delete Buffer" })
      vim.keymap.set("n", "<leader>bD", function()
        require("mini.bufremove").delete(0, true)
      end, { desc = "Delete Buffer (Force)" })
    end,
  },
}
