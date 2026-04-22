-- ##Script function and purpose: mini.nvim utility modules — ai textobjects,
-- surround, pairs, comment, bufremove, and icons (which mocks nvim-web-devicons
-- in memory so that other plugins requiring web-devicons resolve to mini.icons).

require("mini.icons").setup()
require("mini.icons").mock_nvim_web_devicons()

require("mini.ai").setup({ n_lines = 500 })
require("mini.surround").setup()
require("mini.pairs").setup()
require("mini.comment").setup()
require("mini.bufremove").setup()

vim.keymap.set("n", "<leader>bd", function()
  require("mini.bufremove").delete(0, false)
end, { desc = "Delete Buffer" })

vim.keymap.set("n", "<leader>bD", function()
  require("mini.bufremove").delete(0, true)
end, { desc = "Delete Buffer (Force)" })
