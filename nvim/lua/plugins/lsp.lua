-- ##Script function and purpose: Configures the full LSP stack — Mason package
-- manager, mason-lspconfig bridge, nvim-lspconfig server setup with FreeBSD binary
-- detection, nvim-cmp completion engine with LSP/buffer/path/snippet sources,
-- and lazydev for Neovim Lua API completion.

return {

  -- ##Section purpose: lazydev — Lua LSP type annotations for the Neovim API
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {
      library = {
        { path = "luvit-meta/library", words = { "vim%.uv" } },
      },
    },
  },
  { "Bilal2453/luvit-meta", lazy = true },

  -- ##Section purpose: nvim-lspconfig + Mason — LSP server setup with FreeBSD support
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      -- ##Step purpose: Mason UI setup
      require("mason").setup({
        ui = {
          border = "rounded",
          icons = {
            package_installed = "✓",
            package_pending = "➜",
            package_uninstalled = "✗",
          },
        },
      })

      -- ##Step purpose: mason-lspconfig bridge — only gopls auto-installed (Go binaries
      -- are portable). All other servers must be installed via FreeBSD pkg or ports.
      require("mason-lspconfig").setup({
        ensure_installed = { "gopls" },
        -- ##Step purpose: Disable automatic installation — Mason prebuilt binaries
        -- are Linux-only and fail on FreeBSD
        automatic_installation = false,
      })

      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      -- ##Function purpose: FreeBSD binary detection — tries versioned names for
      -- system-installed LSP servers (FreeBSD LLVM is versioned: clangd19, etc.)
      local function get_cmd(server)
        if server == "clangd" then
          -- ##Loop purpose: Try versioned clangd names from newest to oldest
          for _, v in ipairs({ "19", "18", "17", "15", "" }) do
            local name = "clangd" .. v
            if vim.fn.executable(name) == 1 then return { name } end
          end
        elseif server == "rust_analyzer" then
          if vim.fn.executable("rust-analyzer") == 1 then return { "rust-analyzer" } end
        elseif server == "lua_ls" then
          if vim.fn.executable("lua-language-server") == 1 then return { "lua-language-server" } end
        elseif server == "pyright" then
          -- ##Step purpose: FreeBSD uses py311-pyright from pkg
          if vim.fn.executable("pyright") == 1 then return { "pyright" } end
        elseif server == "zls" then
          if vim.fn.executable("zls") == 1 then return { "zls" } end
        elseif server == "bashls" then
          -- ##Step purpose: bashls is an npm package (bash-language-server)
          if vim.fn.executable("bash-language-server") == 1 then return { "bash-language-server", "start" } end
        end
        return nil
      end

      -- ##Step purpose: Full server list — all languages used in Jenova development
      local servers = { "clangd", "rust_analyzer", "gopls", "pyright", "zls", "bashls", "lua_ls" }

      -- ##Loop purpose: Configure each server with FreeBSD binary detection
      for _, server in ipairs(servers) do
        local config = { capabilities = capabilities }

        -- ##Step purpose: Use FreeBSD-detected binary path if found
        local custom_cmd = get_cmd(server)
        if custom_cmd then
          config.cmd = custom_cmd
        end

        -- ##Condition purpose: Extra lua_ls settings — lazydev handles globals
        if server == "lua_ls" then
          config.settings = { Lua = { telemetry = { enable = false } } }
        end

        -- ##Condition purpose: Use Neovim 0.11+ native LSP config API if available
        if vim.lsp.config then
          vim.lsp.config(server, config)
          vim.lsp.enable(server)
        else
          require("lspconfig")[server].setup(config)
        end
      end

      -- ##Function purpose: Attach buffer-local LSP keybinds when a server connects
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("jenova_lsp_attach", { clear = true }),
        callback = function(ev)
          local o = { buffer = ev.buf }
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, o)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, o)
          -- ##Step purpose: <leader>ca is exclusively LSP code action
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, o)
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, o)
          vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, o)
        end,
      })
    end,
  },

  -- ##Section purpose: conform.nvim — format-on-save with per-formatter existence checks
  -- PR #25: Formatters wrapped in existence check so format-on-save silently skips
  -- missing tools rather than throwing error notifications on each save.
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
        -- ##Condition purpose: Skip format-on-save for buffers in large files
        -- to avoid stalling on 10k+ line generated files.
        if vim.api.nvim_buf_line_count(bufnr) > 5000 then
          return nil
        end
        -- ##Condition purpose: Only run if at least one formatter is available;
        -- prevents noisy "no formatter" errors on filetypes with no formatters set.
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

  -- ##Section purpose: nvim-cmp — completion engine
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
      "onsails/lspkind.nvim",
    },
    config = function()
      local cmp = require("cmp")
      local lspkind = require("lspkind")

      cmp.setup({
        snippet = {
          -- ##Action purpose: Use LuaSnip as the snippet expander
          expand = function(args)
            require("luasnip").lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<C-n>"] = cmp.mapping.select_next_item(),
          ["<C-p>"] = cmp.mapping.select_prev_item(),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "lazydev", group_index = 0 },
          { name = "luasnip" },
          { name = "path" },
        }, {
          { name = "buffer" },
        }),
        formatting = {
          format = lspkind.cmp_format({
            mode = "symbol_text",
            maxwidth = 50,
            ellipsis_char = "...",
          }),
        },
      })
    end,
  },
}
