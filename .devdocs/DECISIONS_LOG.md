# Architectural Decisions Log

## D-001: AI keybinds move to leader-a namespace
- **Date:** 2026-03-27
- **Decision:** All gp.nvim and Jenova AI keybinds use `<leader>a*` instead of `<leader>g*`
- **Rationale:** Eliminates 4 breaking keybind collisions (B2-B5) between gitsigns and gp.nvim
- **Impact:** `<leader>g` = Git only, `<leader>a` = AI only, `<leader>c` = Code only

## D-002: Neovim config stored under nvim/ in repo root
- **Date:** 2026-03-27
- **Decision:** Config files tracked at `nvim/` in repo, deployed to `~/.config/nvim/` by install script
- **Rationale:** Keeps repo organized (nvim config separate from backend code), enables version control

## D-003: Branch 1 fixes combined into single bootstrap PR
- **Date:** 2026-03-27
- **Decision:** Instead of 5 separate PRs, all Branch 1 fixes ship in one PR that also adds the nvim/ directory
- **Rationale:** Files don't exist in repo yet; adding them with bugs already fixed is cleaner than add-then-fix
