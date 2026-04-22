-- File tree, finder, diagnostics list, indent guides, and layout are handled
-- by jvim's native runtime/plugin/jvim_ui.lua (jvim.tree, jvim.finder,
-- jvim.diagnostics_list, jvim.indent_guides, jvim.layout).

-- nvim-treesitter — incremental syntax parsing (still vendored)
do
  local ok, configs = pcall(require, "nvim-treesitter.configs")
  if not ok then configs = require("nvim-treesitter.config") end
  configs.setup({
    ensure_installed = {
      "c", "cpp", "rust", "go", "python", "zig",
      "bash", "lua", "luadoc", "vim", "vimdoc",
      "json", "yaml", "toml",
      "markdown", "markdown_inline",
    },
    highlight = { enable = true },
    indent    = { enable = true },
  })
end
