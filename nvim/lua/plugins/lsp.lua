-- LSP stack: mason, nvim-lspconfig, lazydev, nvim-cmp, conform.

require("lazydev").setup({
  library = { { path = "luvit-meta/library", words = { "vim%.uv" } } },
})

require("mason").setup({
  ui = {
    border = "rounded",
    icons = { package_installed = "✓", package_pending = "➜", package_uninstalled = "✗" },
  },
})
require("mason-lspconfig").setup({ ensure_installed = {}, automatic_installation = false })

vim.diagnostic.config({
  virtual_text = { spacing = 2, prefix = "●", source = "if_many" },
  signs            = true,
  underline        = true,
  update_in_insert = false,
  severity_sort    = true,
  float = { border = "rounded", source = "if_many", header = "", prefix = "" },
})

for sev, icon in pairs({ Error = "", Warn = "", Info = "", Hint = "" }) do
  local hl = "DiagnosticSign" .. sev
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = hl })
end

local capabilities = require("cmp_nvim_lsp").default_capabilities()

local function get_cmd(server)
  if server == "clangd" then
    for _, v in ipairs({ "19", "18", "17", "15", "" }) do
      if vim.fn.executable("clangd" .. v) == 1 then return { "clangd" .. v } end
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
    if vim.fn.executable("bash-language-server") == 1 then return { "bash-language-server", "start" } end
  elseif server == "gopls" then
    if vim.fn.executable("gopls") == 1 then return { "gopls" } end
  end
  return nil
end

for _, server in ipairs({ "clangd", "rust_analyzer", "gopls", "pyright", "zls", "bashls", "lua_ls" }) do
  local config = { capabilities = capabilities }
  local cmd = get_cmd(server)
  if cmd then config.cmd = cmd end
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

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("jenova_lsp_attach", { clear = true }),
  callback = function(ev)
    local o = { buffer = ev.buf }
    vim.keymap.set("n", "gd",         vim.lsp.buf.definition,    o)
    vim.keymap.set("n", "K",          vim.lsp.buf.hover,         o)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action,   o)
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename,        o)
    vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, o)
  end,
})

local cmp     = require("cmp")
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
    format = lspkind.cmp_format({ mode = "symbol_text", maxwidth = 50, ellipsis_char = "..." }),
  },
})

require("conform").setup({
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
  format_on_save = function(bufnr)
    if vim.api.nvim_buf_line_count(bufnr) > 5000 then return nil end
    local ok, conform = pcall(require, "conform")
    if not ok then return nil end
    for _, f in ipairs(conform.list_formatters(bufnr)) do
      if f.available then return { timeout_ms = 500, lsp_fallback = true } end
    end
    return nil
  end,
})
vim.keymap.set("n", "<leader>cf", function()
  require("conform").format({ async = true, lsp_fallback = true })
end, { desc = "Format Buffer" })
