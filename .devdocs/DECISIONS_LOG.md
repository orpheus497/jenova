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

## D-004: Kanagawa Dragon is the canonical theme variant
- **Date:** 2026-03-27
- **Decision:** Restore Kanagawa Dragon (darkest) variant
- **Rationale:** Dragon was the user's explicit choice; Branch 1 agent changed to Wave without authorization

## D-005: Edgy owns the three-panel layout exclusively
- **Date:** 2026-03-27
- **Decision:** :IDE simplified to just open NvimTree; Edgy auto-manages all docking
- **Rationale:** Dual layout managers caused race conditions (F1)

## D-006: mini.icons replaces nvim-web-devicons
- **Date:** 2026-03-27
- **Decision:** nvim-web-devicons disabled in lazy.nvim; mini.icons provides all icons via mock
- **Rationale:** Eliminates redundant plugin load

## D-007: FreeBSD binary detection is non-negotiable
- **Date:** 2026-03-27
- **Decision:** get_cmd() restored with versioned clangd, rust-analyzer, pyright, zls, bashls
- **Rationale:** FreeBSD LLVM is versioned, Mason binaries are Linux-only

## D-008: Plugin ports read from environment variables
- **Date:** 2026-03-27
- **Decision:** llama.lua and gp.lua read JENOVA_HOST/JENOVA_PORT/JENOVA_LLAMA_PORT from env
- **Rationale:** Enables jvim launcher to sync ports from jenova.conf
