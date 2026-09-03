-- ##Plugin purpose: Auto-load the native jvim dashboard at startup when the
-- editor is launched without file arguments. This consolidates the legacy
-- nvi-style intro and the former alpha-nvim IDE dashboard into a single
-- built-in home screen — no external plugin manager is required.
--
-- Users may opt out by setting `g:jvim_dashboard_disable = 1` before this
-- plugin loads (e.g. in init.vim / init.lua) or by adding "I" to 'shortmess'.

if vim.g.loaded_jvim_dashboard then
  return
end
vim.g.loaded_jvim_dashboard = 1

-- ##Step purpose: Track whether stdin was piped — :Man and similar workflows
-- pass content through stdin and should not be replaced by the dashboard.
vim.api.nvim_create_autocmd("StdinReadPre", {
  once = true,
  callback = function()
    vim.g.jvim_stdin_used = true
  end,
})

-- ##Step purpose: Suppress the legacy C-level intro_message so it does not
-- briefly flash before the dashboard renders. We record whether the user had
-- already set 'I' so should_autoshow() can distinguish our own change from a
-- genuine user opt-out.
if not vim.g.jvim_dashboard_disable then
  vim.g.jvim_dashboard_user_shm_I = vim.o.shortmess:find("I", 1, true) ~= nil
  pcall(function() vim.opt.shortmess:append("I") end)
end

-- ##Step purpose: User commands to invoke the dashboard explicitly, mirroring
-- :intro for the legacy intro screen.
vim.api.nvim_create_user_command("JvimDashboard", function()
  require("jvim.dashboard").open()
end, { desc = "Open the jvim home / dashboard screen" })

vim.api.nvim_create_user_command("JvimDashboardToggle", function()
  require("jvim.dashboard").toggle()
end, { desc = "Toggle the jvim home / dashboard screen" })

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  nested = true,
  callback = function()
    local ok, dash = pcall(require, "jvim.dashboard")
    if not ok then return end
    if dash.should_autoshow() then
      dash.open()
    end
  end,
})
