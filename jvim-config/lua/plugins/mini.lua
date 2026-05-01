-- ##Script function and purpose: Configures mini.nvim utility modules that
-- remain useful as text-editing helpers — mini.ai (around/inside textobjects),
-- mini.surround (bracket operations), and mini.pairs (auto-pair brackets).
--
-- mini.icons and the nvim-web-devicons disable stub were removed in Wave 2 of
-- the native conversion: runtime/lua/jvim/icons.lua now owns icon lookup and
-- installs a `nvim-web-devicons` shim into package.loaded at startup (see
-- runtime/plugin/jvim_ui.lua). mini.comment was removed in Wave 1 (Neovim
-- 0.10+ ships built-in `gc`/`gcc`); mini.bufremove was replaced by an inline
-- helper in runtime/plugin/jvim_ui.lua.

return {
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
    end,
  },
}
