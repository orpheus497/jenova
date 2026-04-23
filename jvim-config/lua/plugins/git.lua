-- ##Script function and purpose: Configures all git-integration plugins — gitsigns
-- (inline hunk signs and blame), neogit (Magit-like UI), diffview.nvim (side-by-side
-- diffs and merge tool), and vim-fugitive (Git command integration).
-- All keybinds live under <leader>g* — exclusively reserved for git operations.

return {

  -- ##Section purpose: gitsigns — inline git hunk signs in the sign column
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
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

        -- ##Function purpose: Convenience wrapper to bind buffer-local keys
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end

        -- ##Step purpose: Hunk navigation
        map("n", "]h", gs.next_hunk,  "Next Hunk")
        map("n", "[h", gs.prev_hunk,  "Prev Hunk")

        -- ##Step purpose: Hunk actions — stage, reset, preview, blame
        map("n", "<leader>gs", gs.stage_hunk,                                    "Stage Hunk")
        map("n", "<leader>gS", gs.stage_buffer,                                  "Stage Buffer")
        map("n", "<leader>gu", gs.undo_stage_hunk,                               "Undo Stage Hunk")
        map("n", "<leader>gR", gs.reset_buffer,                                  "Reset Buffer")
        map("n", "<leader>gp", gs.preview_hunk,                                  "Preview Hunk")
        map("n", "<leader>gb", function() gs.blame_line({ full = true }) end,    "Blame Line")
        map("n", "<leader>gB", gs.toggle_current_line_blame,                     "Toggle Line Blame")
        map("n", "<leader>gd", gs.diffthis,                                      "Diff This")
        map("n", "<leader>gD", function() gs.diffthis("~") end,                  "Diff This ~")

        -- ##Step purpose: Visual-mode hunk stage/reset
        map("v", "<leader>gs", function() gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Stage Hunk")
        map("v", "<leader>gr", function() gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Reset Hunk")
      end,
    },
  },

  -- ##Section purpose: neogit — Magit-inspired interactive git UI
  {
    "NeogitOrg/neogit",
    dependencies = { "nvim-lua/plenary.nvim", "sindrets/diffview.nvim" },
    keys = {
      { "<leader>gg", "<cmd>Neogit<CR>", desc = "Neogit" },
    },
    opts = {
      integrations = { diffview = true },
    },
  },

  -- ##Section purpose: diffview.nvim — side-by-side diffs and three-way merge tool
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<CR>",            desc = "DiffView Open" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<CR>",   desc = "File History" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<CR>",     desc = "Repo History" },
      { "<leader>gc", "<cmd>DiffviewClose<CR>",           desc = "DiffView Close" },
    },
    opts = {},
  },

  -- ##Section purpose: vim-fugitive — classic :Git command integration
  {
    "tpope/vim-fugitive",
    cmd = { "Git", "G", "Gdiffsplit", "Gread", "Gwrite", "Ggrep", "GMove", "GDelete", "GBrowse" },
    keys = {
      { "<leader>gf", "<cmd>Git<CR>", desc = "Fugitive Status" },
    },
  },

}
