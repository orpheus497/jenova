# Jenova Project — Current Briefing

## Project
Jenova Cognitive Architecture — a 100% FOSS local AI coding assistant for FreeBSD.

## Architecture
- **Backend:** llama.cpp (Vulkan dual-GPU), LuaJIT proxy with RAG, embedding server
- **Frontend:** Neovim IDE with gp.nvim (chat), llama.vim (FIM), full LSP stack
- **Hardware:** FreeBSD 15 | i5-1135G7 | GTX 1650 Ti + Intel Iris Xe | 16GB RAM | 27GB Optane swap

## Current Phase
**Branch 1: fix/nvim-bugs** — Bootstrap Neovim config into repo + fix all verified bugs

## Progress
- [x] Audit complete (JENOVA-NVIM-ROADMAP.md)
- [x] Branch 1 PR created
- [ ] Branch 2: refactor/nvim-structure (9 PRs)
- [ ] Branch 3: feat/nvim-lifecycle (7 PRs)
- [ ] Branch 4: feat/nvim-polish (6 PRs)

## Next Steps
1. Review and merge Branch 1 PR
2. Begin Branch 2: Remove :IDE command, split namespaces, install infrastructure
3. Create bin/jvim unified launcher (Branch 3)
