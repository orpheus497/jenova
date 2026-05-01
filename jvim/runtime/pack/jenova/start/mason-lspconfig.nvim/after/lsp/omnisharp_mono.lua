return vim.tbl_extend("force", vim.lsp.config.omnisharp or {}, {
    cmd = { "omnisharp-mono" },
})
