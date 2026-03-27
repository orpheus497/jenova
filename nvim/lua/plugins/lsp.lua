-- ##Script function and purpose: Configures the full LSP stack — Mason package
-- manager for LSP servers, mason-lspconfig bridge, nvim-lspconfig server setup,
-- nvim-cmp completion engine with LSP/buffer/path/snippet sources, LuaSnip snippet
-- engine, lspkind icons, lazydev for Neovim Lua API completion, and conform.nvim
-- formatting triggered on save. <leader>ca stays for LSP code action (no collision).

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

  -- ##Section purpose: Mason — GUI installer for LSP servers, linters, formatters
  {
    "williamboman/mason.nvim",
    build = ":MasonUpdate",
    opts = { ui = { border = "rounded" } },
  },

  -- ##Section purpose: mason-lspconfig — bridges Mason with nvim-lspconfig
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    opts = {
      ensure_installed = {
        "lua_ls",
        "pyright",
        "clangd",
        "bashls",
      },
      automatic_installation = true,
    },
  },

  -- ##Section purpose: nvim-lspconfig — server setup and LspAttach keybinds
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      local lspconfig   = require("lspconfig")
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      -- ##Function purpose: Attach buffer-local LSP keybinds when a server connects
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("jenova_lsp_attach", { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc)
            vim.keymap.set("n", keys, func, { buffer = event.buf, desc = "LSP: " .. desc })
          end

          -- ##Step purpose: Navigation
          map("gd",          vim.lsp.buf.definition,      "Go to Definition")
          map("gD",          vim.lsp.buf.declaration,     "Go to Declaration")
          map("gi",          vim.lsp.buf.implementation,  "Go to Implementation")
          map("gr",          vim.lsp.buf.references,      "References")
          map("K",           vim.lsp.buf.hover,           "Hover Docs")
          map("<C-k>",       vim.lsp.buf.signature_help,  "Signature Help")

          -- ##Step purpose: Edits — rename symbol and code actions
          map("<leader>rn",  vim.lsp.buf.rename,          "Rename Symbol")
          -- <leader>ca is exclusively LSP code action (no collision — gp.nvim moved to <leader>a*)
          map("<leader>ca",  vim.lsp.buf.code_action,     "Code Action")

          -- ##Step purpose: Workspace folders
          map("<leader>wa",  vim.lsp.buf.add_workspace_folder,    "Add Workspace Folder")
          map("<leader>wr",  vim.lsp.buf.remove_workspace_folder, "Remove Workspace Folder")
        end,
      })

      -- ##Step purpose: Configure other LSP servers with shared capabilities
      -- lua_ls is excluded here — it is set up separately below with extra settings
      local servers = { "pyright", "clangd", "bashls" }
      for _, server in ipairs(servers) do
        lspconfig[server].setup({ capabilities = capabilities })
      end

      -- ##Action purpose: Extra lua_ls settings for Neovim runtime globals
      lspconfig.lua_ls.setup({
        capabilities = capabilities,
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
          },
        },
      })
    end,
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
      local cmp     = require("cmp")
      local luasnip = require("luasnip")
      local lspkind = require("lspkind")

      cmp.setup({
        snippet = {
          -- ##Action purpose: Use LuaSnip as the snippet expander
          expand = function(args) luasnip.lsp_expand(args.body) end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-b>"]     = cmp.mapping.scroll_docs(-4),
          ["<C-f>"]     = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"]     = cmp.mapping.abort(),
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          -- ##Action purpose: Tab cycles through snippet placeholders and cmp items
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "lazydev", group_index = 0 },
        }, {
          { name = "buffer" },
          { name = "path" },
        }),
        formatting = {
          -- ##Action purpose: lspkind icons make completion menu readable
          format = lspkind.cmp_format({
            mode = "symbol_text",
            maxwidth = 50,
            ellipsis_char = "...",
          }),
        },
        window = {
          completion    = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
      })
    end,
  },

}
