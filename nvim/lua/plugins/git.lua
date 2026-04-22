-- ##Script function and purpose: Git integration — gitsigns, neogit, diffview,
-- and vim-fugitive. All keybinds live under <leader>g* (reserved for git).

-- gitsigns — inline hunk signs in the sign column
require("gitsigns").setup({
  signs = {
    add          = { text = "▎" },
    change       = { text = "▎" },
    delete       = { text = "" },
    topdelete    = { text = "" },
    changedelete = { text = "▎" },
    untracked    = { text = "▎" },
  },
  on_attach = function(bufnr)
    local gs = package.loaded.gitsigns
    local function map(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
    end
    map("n", "]h", gs.next_hunk, "Next Hunk")
    map("n", "[h", gs.prev_hunk, "Prev Hunk")
    map("n", "<leader>gs", gs.stage_hunk,                                    "Stage Hunk")
    map("n", "<leader>gS", gs.stage_buffer,                                  "Stage Buffer")
    map("n", "<leader>gu", gs.undo_stage_hunk,                               "Undo Stage Hunk")
    map("n", "<leader>gR", gs.reset_buffer,                                  "Reset Buffer")
    map("n", "<leader>gp", gs.preview_hunk,                                  "Preview Hunk")
    map("n", "<leader>gb", function() gs.blame_line({ full = true }) end,    "Blame Line")
    map("n", "<leader>gB", gs.toggle_current_line_blame,                     "Toggle Line Blame")
    map("n", "<leader>gd", gs.diffthis,                                      "Diff This")
    map("n", "<leader>gD", function() gs.diffthis("~") end,                  "Diff This ~")
    map("v", "<leader>gs", function()
      gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
    end, "Stage Hunk")
    map("v", "<leader>gr", function()
      gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
    end, "Reset Hunk")
  end,
})

-- neogit — Magit-inspired interactive git UI
require("neogit").setup({ integrations = { diffview = true } })
vim.keymap.set("n", "<leader>gg", "<cmd>Neogit<CR>", { desc = "Neogit" })

-- diffview.nvim — side-by-side diffs and three-way merge tool
require("diffview").setup({})
vim.keymap.set("n", "<leader>gv", "<cmd>DiffviewOpen<CR>",          { desc = "DiffView Open" })
vim.keymap.set("n", "<leader>gh", "<cmd>DiffviewFileHistory %<CR>", { desc = "File History" })
vim.keymap.set("n", "<leader>gH", "<cmd>DiffviewFileHistory<CR>",   { desc = "Repo History" })
vim.keymap.set("n", "<leader>gc", "<cmd>DiffviewClose<CR>",         { desc = "DiffView Close" })

-- vim-fugitive — :Git command integration (no setup needed)
vim.keymap.set("n", "<leader>gf", "<cmd>Git<CR>", { desc = "Fugitive Status" })
