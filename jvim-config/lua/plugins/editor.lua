-- ##Script function and purpose: Configures editor plugins still backed by
-- third-party packages — nvim-treesitter (incremental syntax) and conform.nvim
-- (format-on-save). The previous nvim-tree, telescope, trouble, and
-- indent-blankline entries have been removed; their replacements live in
-- runtime/lua/jvim/{tree,finder,diagnostics_list,indent_guides}.lua and are
-- wired by runtime/plugin/jvim_ui.lua.

return {

  -- ##Section purpose: nvim-treesitter — incremental syntax parsing and highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      -- ##Step purpose: Install parsers for all languages used in Jenova development
      ensure_installed = {
        "c", "cpp", "rust", "go", "python", "zig",
        "bash", "lua", "luadoc", "vim", "vimdoc",
        "json", "yaml", "toml",
        "markdown", "markdown_inline",
      },
      highlight = { enable = true },
      indent = { enable = true },
    },
    config = function(_, opts)
      -- ##Step purpose: Defensive pcall handles API name change between treesitter versions
      local ok, configs = pcall(require, "nvim-treesitter.configs")
      if not ok then configs = require("nvim-treesitter.config") end
      configs.setup(opts)
    end,
  },

  -- ##Section purpose: conform.nvim — format-on-save with per-formatter existence checks
  -- Only format if at least one formatter is installed; silently skips missing tools.
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd   = { "ConformInfo" },
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
        python = { "isort", "black" },
        rust   = { "rustfmt" },
        go     = { "gofmt", "goimports" },
        c      = { "clang-format" },
        cpp    = { "clang-format" },
        sh     = { "shfmt" },
        bash   = { "shfmt" },
      },
      -- ##Step purpose: Only format if at least one formatter is installed and available.
      -- lsp_fallback=true means LSP formatting fires when no conform formatter matches.
      format_on_save = function(bufnr)
        if vim.api.nvim_buf_line_count(bufnr) > 5000 then
          return nil
        end
        local ok, conform = pcall(require, "conform")
        if not ok then return nil end
        local formatters = conform.list_formatters(bufnr)
        local any_available = false
        for _, f in ipairs(formatters) do
          if f.available then
            any_available = true
            break
          end
        end
        if not any_available then
          return nil
        end
        return { timeout_ms = 500, lsp_fallback = true }
      end,
    },
  },

}
