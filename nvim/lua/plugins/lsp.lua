-- ##Script function and purpose: LSP stack — Mason package manager (manual mode
-- only; no auto-installs because Mason's prebuilt binaries are Linux-only),
-- nvim-lspconfig with FreeBSD versioned binary detection, and nvim-cmp
-- completion engine with LSP/buffer/path/snippet sources.

-- lazydev — Lua LSP type annotations for the Neovim API (lua filetypes only)
require("lazydev").setup({
  library = {
    { path = "luvit-meta/library", words = { "vim%.uv" } },
  },
})

-- Mason — package manager UI (no auto-install; FreeBSD/BSD users install LSP
-- servers via pkg/ports, Linux users via their distro package manager).
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
require("mason-lspconfig").setup({
  ensure_installed = {},
  automatic_installation = false,
})

-- ── Diagnostic display ────────────────────────────────────────────────
-- Neovim 0.11 ships with virtual_text DISABLED by default (see
-- :h news-0.11). Without re-enabling it, LSP errors/warnings produce no
-- inline messages — only signs in the gutter — which makes the editor
-- look like linting is broken even when servers are attached. Restore
-- the classic UX: inline virtual text (truncated to the right of code),
-- sign-column markers, underlines, severity-based ordering, and a
-- bordered hover float that names the source server when ambiguous.
vim.diagnostic.config({
  virtual_text = {
    spacing = 2,
    prefix  = "●",
    source  = "if_many",
  },
  signs            = true,
  underline        = true,
  update_in_insert = false,
  severity_sort    = true,
  float = {
    border = "rounded",
    source = "if_many",
    header = "",
    prefix = "",
  },
})

-- Sign column glyphs for each severity (Neovim 0.10+ unified API).
for sev, icon in pairs({ Error = "", Warn = "", Info = "", Hint = "" }) do
  local hl = "DiagnosticSign" .. sev
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = hl })
end

local capabilities = require("cmp_nvim_lsp").default_capabilities()

-- FreeBSD/Linux binary detection — tries versioned names for system-installed
-- LSP servers (FreeBSD LLVM is versioned: clangd19, etc.)
local function get_cmd(server)
  if server == "clangd" then
    for _, v in ipairs({ "19", "18", "17", "15", "" }) do
      local name = "clangd" .. v
      if vim.fn.executable(name) == 1 then return { name } end
    end
  elseif server == "rust_analyzer" then
    if vim.fn.executable("rust-analyzer") == 1 then return { "rust-analyzer" } end
  elseif server == "lua_ls" then
    if vim.fn.executable("lua-language-server") == 1 then return { "lua-language-server" } end
  elseif server == "pyright" then
    if vim.fn.executable("pyright") == 1 then return { "pyright" } end
  elseif server == "zls" then
    if vim.fn.executable("zls") == 1 then return { "zls" } end
  elseif server == "bashls" then
    if vim.fn.executable("bash-language-server") == 1 then
      return { "bash-language-server", "start" }
    end
  elseif server == "gopls" then
    if vim.fn.executable("gopls") == 1 then return { "gopls" } end
  end
  return nil
end

local servers = { "clangd", "rust_analyzer", "gopls", "pyright", "zls", "bashls", "lua_ls" }
for _, server in ipairs(servers) do
  local config = { capabilities = capabilities }
  local custom_cmd = get_cmd(server)
  if custom_cmd then config.cmd = custom_cmd end
  if server == "lua_ls" then
    config.settings = { Lua = { telemetry = { enable = false } } }
  end
  if vim.lsp.config then
    vim.lsp.config(server, config)
    vim.lsp.enable(server)
  else
    require("lspconfig")[server].setup(config)
  end
end

-- Buffer-local LSP keymaps when a server attaches
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("jenova_lsp_attach", { clear = true }),
  callback = function(ev)
    local o = { buffer = ev.buf }
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, o)
    vim.keymap.set("n", "K",  vim.lsp.buf.hover,      o)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, o)
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename,      o)
    vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, o)
  end,
})

-- nvim-cmp — completion engine
local cmp = require("cmp")
local lspkind = require("lspkind")
cmp.setup({
  snippet = {
    expand = function(args) require("luasnip").lsp_expand(args.body) end,
  },
  mapping = cmp.mapping.preset.insert({
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<CR>"]      = cmp.mapping.confirm({ select = true }),
    ["<C-n>"]     = cmp.mapping.select_next_item(),
    ["<C-p>"]     = cmp.mapping.select_prev_item(),
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
