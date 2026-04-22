-- mini.nvim — ai textobjects, surround, pairs (comment + bufremove + icons
-- are now handled natively by jvim_ui).

require("mini.ai").setup({ n_lines = 500 })
require("mini.surround").setup()
require("mini.pairs").setup()
