# Jenova Neovim IDE — Comprehensive Audit, Issues, and Roadmap

**Date:** 2026-03-27
**Target OS:** FreeBSD 15.0 (STABLE/CURRENT)
**Target Branch:** `main` (current) → `develop` → feature branches
**Scope:** Neovim configuration (`~/.config/nvim/`) + Jenova backend integration (`~/Projects/jenova/`)

---

## 1. Hardware and Platform Context

This entire configuration targets a single specific machine. Every decision — GPU offload strategy, memory tuning, swap configuration, thread counts — is calibrated to this hardware. None of this is generic.

| Component | Specification | Implication for Neovim IDE |
|---|---|---|
| CPU | Intel i5-1135G7, 4 performance cores / 8 logical threads | `THREADS=4`, `THREADS_BATCH=6` in jenova.conf; LSP servers compete for the same cores as llama-server |
| GPU 0 | NVIDIA GTX 1650 Ti, 4 GiB discrete GDDR6 (Vulkan0) | Primary inference offload; 7B model layers distributed here |
| GPU 1 | Intel Iris Xe TGL GT2, UMA ~7 GiB from system RAM (Vulkan1) | Secondary offload; shares physical RAM with OS, Neovim, LSP servers |
| RAM | 16 GiB DDR4 | Tight budget: ~4 GiB OS+Neovim+LSP, ~2 GiB ZFS ARC, ~3 GiB Iris Xe UMA, rest for llama-server CPU tensors |
| Swap | 27 GiB Intel Optane NVMe (~7 μs random read) | Enables Fluid Memory architecture; cold tensor pages swap without catastrophic latency |
| Storage | ZFS on NVMe | Persistent undo files, ZFS ARC capped at 1-2 GiB via jenova-setup |
| OS | FreeBSD 15 STABLE/CURRENT | No Linux-isms; `gmake` for telescope-fzf-native, BSD socket constants in proxy, `flock` for PID locking |

**Critical constraint:** The Iris Xe's "VRAM" is system RAM. When llama-server allocates tensors on Vulkan1, those pages compete directly with Neovim, tree-sitter, LSP servers, and the OS page cache. Every MB matters. This is why `auto_fim=true` firing HTTP requests on every keystroke pause is a real concern — each request occupies an inference slot (there are only 2) and generates KV cache pressure.

---

## 2. Current State — File-by-File Analysis

### 2.1 Directory Structure

The project files in this repo are the Neovim configuration. They deploy to:

```
~/.config/nvim/
├── init.lua                    ← Main entry point
├── lazy-lock.json              ← Plugin version pins
└── lua/
    └── plugins/                ← lazy.nvim scans this directory
        ├── dashboard.lua       ← Alpha dashboard
        ├── editor.lua          ← NvimTree, Telescope, Treesitter, Trouble
        ├── git.lua             ← Gitsigns, Neogit, Diffview, Fugitive
        ├── gp.lua              ← gp.nvim AI chat (connects to Jenova proxy :8080)
        ├── llama.lua           ← llama.vim FIM completions (connects to :8081)
        ├── lsp.lua             ← Mason, LSP servers, nvim-cmp, conform
        ├── mini.lua            ← mini.nvim utilities
        └── ui.lua              ← Kanagawa, Lualine, Which-key, Noice, Edgy
```

**Important:** `init.lua` line 45 calls `require("lazy").setup("plugins", ...)`. lazy.nvim interprets the string `"plugins"` as a Lua module path, meaning it scans `lua/plugins/` for `*.lua` files. The flat layout in this repo (all `.lua` at root) is the repo structure — when deployed, these files must be at `~/.config/nvim/lua/plugins/`. Any install script must respect this path mapping: `init.lua` → `~/.config/nvim/init.lua`, everything else → `~/.config/nvim/lua/plugins/`.

### 2.2 init.lua — Main Entry Point

**Line 1:** Title says "NEVIM" — typo, should be "NEOVIM".

**Lines 6:** `vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/site")` — FreeBSD-specific path rectification. Correct and necessary because FreeBSD installs site packages to a non-standard location.

**Lines 11-15:** Lazy.nvim bootstrap. Standard pattern, works correctly.

**Lines 19-40:** Editor options. All correct. `opt.clipboard = "unnamedplus"` requires `xclip` or `xsel` installed on FreeBSD (or Wayland equivalent). If running in a pure terminal without X11/Wayland forwarding, this silently fails (no error, but no system clipboard integration).

**Line 45:** `require("lazy").setup("plugins", ...)` — scans `lua/plugins/`. The `rocks = { enabled = false }` is critical for FreeBSD because luarocks has libc conflicts. Correct.

**Lines 72-73:** `<leader>w` and `<leader>q` — save and quit. Fine.

**Line 92:** `<leader>ca` maps to `:term cd ~/Projects/jenova && bin/jenova<CR>` — this opens the CLI agent in a Neovim terminal buffer. **Collision:** `<leader>ca` is also mapped in `lsp.lua` line 95 as `vim.lsp.buf.code_action` on LspAttach. The LSP mapping is buffer-local and fires on LspAttach, so it wins in every buffer with an active LSP server. The Jenova agent keybind is effectively dead in any code file.

**Lines 97-120:** The `:IDE` command. This manually opens NvimTree, Trouble, and GpChat in a three-panel layout. **Conflict with Edgy:** `ui.lua` configures `edgy.nvim` to auto-manage these exact same panels. The `:IDE` command and Edgy are two independent layout managers fighting over the same windows. When Edgy intercepts the NvimTree/Trouble/gp filetypes and pins them, the `:IDE` command's manual `vim.api.nvim_set_current_win()` calls can race with Edgy's window management. One or the other should own the layout, not both.

### 2.3 dashboard.lua — Alpha Dashboard

**Line 11:** ASCII art says "THE ARCANE TABLE". This is leftover branding from before the project was renamed to Jenova. Should be updated to reflect the actual project identity.

**Line 29:** Dashboard button `g` opens Neogit, but `<leader>g` prefix is shared with both gitsigns (git.lua) and gp.nvim (gp.lua). The dashboard shortcut itself is fine since it's only active on the dashboard screen, but the conceptual grouping is misleading.

**Lines 76-80:** Footer hardcodes "FreeBSD 15.0" and "Kanagawa Dragon". The FreeBSD version could be detected dynamically with `vim.fn.system("uname -r")`. Minor.

### 2.4 editor.lua — Core Editor Plugins

**Lines 1-40:** NvimTree. Configuration is clean. `window_picker = { enable = false }` prevents interference with the three-panel layout. `diagnostics = { enable = true, show_on_dirs = true }` means NvimTree connects to the LSP diagnostic system, which is correct.

**Lines 43-67:** Telescope. `build = "gmake"` for telescope-fzf-native is correct for FreeBSD (GNU Make is `gmake`, not `make`). This is a FreeBSD-specific requirement and is already handled.

**Lines 70-86:** Treesitter. The `ensure_installed` list includes `c`, `rust`, `go`, `python`, `zig`, `bash`, `lua`, `markdown`, `markdown_inline`. This is appropriate for a systems programming IDE. The `pcall` fallback between `nvim-treesitter.configs` and `nvim-treesitter.config` handles API changes between treesitter versions — correct defensive coding.

**Lines 89-129:** Trouble.nvim. The `keys` table inside `opts` (lines 104-118) defines keybindings that fire `require("trouble").jump()` followed by `vim.lsp.buf.code_action()` on a 50ms defer. This is an opinionated workflow where clicking/entering a diagnostic immediately opens the code action menu. The `<LeftMouse>` binding here prevents Trouble from opening items in new tabs on click — intentional.

### 2.5 git.lua — Git Integration

**Lines 7-49:** Gitsigns `on_attach` defines buffer-local keybindings under `<leader>g`:

| Binding | gitsigns action | Collides with gp.lua? |
|---|---|---|
| `<leader>gs` | Stage Hunk | No conflict |
| `<leader>gr` | Reset Hunk | **YES** — gp.lua `<leader>gr` = Chat Respond (normal) / Visual Rewrite (visual) |
| `<leader>gS` | Stage Buffer | No conflict |
| `<leader>gu` | Undo Stage Hunk | No conflict |
| `<leader>gR` | Reset Buffer | No conflict |
| `<leader>gp` | Preview Hunk | No conflict |
| `<leader>gb` | Blame Line | No conflict |
| `<leader>gt` | Toggle Blame | **YES** — gp.lua `<leader>gt` = Toggle Chat |
| `<leader>gd` | Diff This | **YES** — gp.lua `<leader>gd` = Delete Chat |

Because gitsigns maps are buffer-local (set in `on_attach` for each git-tracked buffer), they always win over gp.nvim's global maps. In any git repository — which is every project — `<leader>gr`, `<leader>gt`, and `<leader>gd` execute git operations, not AI chat operations.

**Lines 55-73:** Neogit. Clean configuration. Opens in a new tab, which avoids interference with the three-panel layout.

**Line 85:** Fugitive is loaded unconditionally (`lazy = false` from init.lua defaults). Fugitive provides `:Git` commands which don't conflict with anything, but it's extra startup weight if Neogit is the primary git interface.

### 2.6 gp.lua — AI Chat Integration

**Line 7:** Endpoint is `http://127.0.0.1:8080/v1/chat/completions` — this is the Jenova intelligence proxy, which injects RAG context before forwarding to llama-server. Correct.

**Line 8:** `secret = "sk-not-needed-locally"` — required by gp.nvim's OpenAI provider even for local servers. Correct workaround.

**Line 14:** Model is `qwen2.5-coder-7b` — matches the model loaded by jenova-ca. However, the model name sent in the request body is used by llama-server for logging only (it serves whatever model was loaded at startup). No functional issue but worth noting.

**Lines 38-42:** `<leader>gc` "New Chat (Fresh Context)" previously did `os.execute("rm -rf " .. vim.fn.stdpath("state") .. "/gp/chats/*")`. This was the single most dangerous line in the entire configuration:

1. `os.execute` shells out to `/bin/sh`, which means the path is subject to shell expansion and word splitting.
2. `vim.fn.stdpath("state")` returns a string like `/home/orpheus497/.local/state/nvim`. If this ever returned an empty string, a path with spaces, or was manipulated, the `rm -rf` would be catastrophic.
3. The glob `*` is expanded by the shell, not by Lua. If the directory is empty, `rm -rf /path/to/chats/*` on some shells tries to remove a literal file named `*`.

**Status:** ✅ **FIXED** — Current code uses `vim.fn.delete(chat_dir, "rf")` which is Neovim-native and doesn't shell out (see gp.lua:75).

**Line 43:** `<leader>gt` collides with gitsigns toggle-blame (see above).

**Line 45:** `<leader>gd` collides with gitsigns diff-this (see above).

**Line 46:** `<leader>gr` in visual mode collides with gitsigns reset-hunk in normal mode (different modes, but same key sequence in which-key display, causing confusion).

### 2.7 llama.lua — FIM Inline Completions

**Line 6:** `endpoint_fim = "http://127.0.0.1:8081/infill"` — direct to llama-server, bypassing the proxy. Correct: FIM completions don't need RAG injection and the direct path has lower latency.

**Line 7:** `endpoint_inst = "http://127.0.0.1:8080/v1/chat/completions"` — through the proxy for instruction completions. Correct.

**Line 9:** `auto_fim = true` — this fires a FIM completion request after every pause in typing (debounced by `t_max_prompt_ms = 500`). On this hardware with only 2 inference slots:
- If the user is typing while gp.nvim has an active chat request on the proxy, llama-server is processing a chat completion on slot 0 and a FIM request arrives for slot 1.
- With 16k context and q8_0 KV cache, each slot's KV cache can consume ~500 MiB. Two concurrent slots under pressure means ~1 GiB of KV cache actively in use.
- This is within budget, but on a 16 GiB system with Iris Xe UMA eating ~3 GiB and ZFS ARC at 1-2 GiB, it's tight. If the user has a browser or other applications open, OOM-kill becomes possible.

**Recommendation:** Keep `auto_fim = true` but reduce `n_predict` from 128 to 64 to reduce per-request GPU time, or add a Neovim autocommand that pauses FIM when gp.nvim is actively streaming a response.

### 2.8 lsp.lua — Language Server Protocol

**Lines 3-11:** lazydev.nvim + luvit-meta for Lua LSP intelligence. Correct — this gives `vim.uv` completions for Neovim Lua development.

**Lines 16-20:** Dependencies chain: mason → mason-lspconfig → cmp-nvim-lsp. All present in lazy-lock.json.

**Lines 23-30:** Mason setup. `border = "rounded"` matches the lazy.nvim UI border style. Consistent.

**Lines 34-38:** mason-lspconfig `ensure_installed = { "gopls" }` and `automatic_installation = false`. This is correct for FreeBSD where Mason's prebuilt binaries are Linux-only. Only gopls gets auto-installed (Go binaries are portable); everything else (clangd, rust-analyzer, pyright, lua-language-server) must be installed via FreeBSD `pkg` or ports.

**Lines 43-57:** `get_cmd()` function does binary detection for FreeBSD-specific names:
- `clangd` tries `clangd19`, `clangd18`, `clangd17`, `clangd15`, then bare `clangd`. Correct for FreeBSD where LLVM is versioned.
- `rust-analyzer` checks `rust-analyzer` — installed via `pkg install rust-analyzer` or `rustup component add rust-analyzer`. Correct.
- `lua-language-server` checks bare name — installed via `pkg install lua-language-server`. Correct.
- `pyright` checks bare name — comment says "native py311-pyright" meaning `pkg install py311-pyright`. Correct.
- **Missing:** `zls` (Zig Language Server) is in the `servers` list (line 59) but not in `get_cmd()`. If `zls` is installed to a non-standard path on FreeBSD, it won't be found. Should either add a `get_cmd` entry or remove `zls` from the server list if Zig development isn't active.
- **Missing:** `bashls` (Bash Language Server) is in the `servers` list but not in `get_cmd()`. `bashls` is an npm package (`bash-language-server`) that Mason could install, or it's available via `npm install -g bash-language-server`. On FreeBSD, npm packages work normally. If it's not installed, Neovim silently fails to start it (no error visible unless you check `:LspLog`).

**Lines 61-87:** Server setup loop. Uses Neovim 0.11+ native `vim.lsp.config` / `vim.lsp.enable` if available, falls back to `lspconfig[server].setup()`. This is forward-compatible with Neovim 0.11's built-in LSP config API. Correct.

**Lines 90-99:** LspAttach autocommand maps:
- `gd` → go to definition
- `K` → hover
- `<leader>ca` → code action (**COLLISION** with init.lua's Jenova agent terminal binding)
- `<leader>rn` → rename
- `<leader>cd` → open diagnostic float

These are buffer-local and override any global binding with the same key.

**Lines 104-146:** nvim-cmp configuration. Sources include `nvim_lsp`, `lazydev` (group_index 0 for priority), `luasnip`, `path`, then `buffer` as fallback. Standard and correct. The `lazydev` source gives Neovim Lua API completions when editing Lua files.

**Lines 149-164:** conform.nvim for format-on-save. Formatters listed:
- `lua` → `stylua` (must be installed: `cargo install stylua` or `pkg install stylua`)
- `python` → `isort`, `black` (must be installed: `pip install isort black`)
- `rust` → `rustfmt` (comes with Rust toolchain)
- `go` → `gofmt`, `goimports` (come with Go toolchain; `goimports` needs `go install golang.org/x/tools/cmd/goimports@latest`)
- `c` → `clang-format` (comes with LLVM/Clang on FreeBSD)

**Missing formatters:** `zig` (uses `zig fmt`, could add), `bash` (uses `shfmt`, could add). Not critical since format-on-save has `lsp_fallback = true`.

### 2.9 mini.lua — Utility Plugins

Clean. `mini.ai`, `mini.surround`, `mini.pairs`, `mini.icons` are all lightweight and conflict-free. `mini.icons.mock_nvim_web_devicons()` means mini.icons replaces nvim-web-devicons for icon rendering — but `nvim-web-devicons` is still listed as a dependency in multiple plugins (alpha-nvim, nvim-tree, lualine). This works because the mock creates the `nvim-web-devicons` module in memory, satisfying `require("nvim-web-devicons")` calls. However, the actual `nvim-web-devicons` plugin is still cloned and loaded by lazy.nvim. **Minor waste:** nvim-web-devicons is loaded then immediately overridden by mini.icons. Could mark nvim-web-devicons as `enabled = false` in lazy.nvim to skip loading it entirely, since mini.icons handles everything.

### 2.10 ui.lua — Visual Layer

**Lines 1-29:** Kanagawa theme with `dragon` variant. Priority 1000 ensures it loads before other plugins. Correct.

**Lines 32-43:** Lualine with `globalstatus = true` (single statusline across all windows, not per-window). This is correct for the three-panel layout — you don't want three statuslines.

**Lines 46-66:** Which-key groups:
- `<leader>f` → "Find" — correct (Telescope bindings)
- `<leader>g` → "Git" — **WRONG** — this group contains both git operations (gitsigns, neogit) AND AI chat operations (gp.nvim). The label "Git" is misleading.
- `<leader>c` → "Code" — correct (code action, config)
- `<leader>r` → "Rename" — correct (LSP rename)

**Missing which-key groups:**
- `<leader>x` → should be "Diagnostics" (Trouble bindings from editor.lua)
- `<leader>a` → proposed new group for "AI" (if we move gp.nvim bindings to `<leader>a`)

**Lines 69-103:** Noice.nvim configuration.

**Line 77:** `"vim.lsp.util.styled_pa_lines"` — **THIS IS A BUG.** The correct function name is `"vim.lsp.util.stylize_markdown"`. The string `styled_pa_lines` does not correspond to any function in Neovim's LSP utilities. What happens at runtime: noice.nvim tries to override a function that doesn't exist. Depending on the noice version, this either silently fails (meaning the LSP markdown rendering override never activates, and you get raw markdown in hover windows instead of rendered markdown) or throws an error that gets swallowed by pcall.

**Line 100:** `pcall(require("telescope").load_extension, "notify")` — loads the Telescope notify extension. This gives `:Telescope notify` to search through notification history. Fine, but Telescope is lazy-loaded via `keys` in editor.lua. If noice/notify loads before Telescope (both are `VeryLazy`), this pcall will fail because Telescope isn't loaded yet. The pcall prevents a crash but the extension silently doesn't load. Should either add an explicit dependency on telescope or defer this call.

**Lines 107-143:** Edgy.nvim configuration. This is the window layout manager:
- Left panel top: NvimTree (pinned, 50% height)
- Left panel bottom: Trouble diagnostics (pinned, 50% height)
- Right panel: gp.nvim AI chat (pinned, 30% width)

Edgy intercepts windows with matching filetypes and docks them into these positions. This means the `:IDE` command in init.lua is redundant — Edgy already handles the layout. The `:IDE` command should either be removed entirely (let Edgy manage layout) or Edgy should be removed (let `:IDE` manage layout manually). Having both is the source of race conditions.

**Edgy filetype detection for gp.nvim:** Edgy expects `ft = "gp"` but gp.nvim's chat buffers use filetype `markdown`. Unless gp.nvim sets a custom filetype (some versions do set `gp` as a filetype for chat buffers, some use `markdown`), Edgy may not detect them. This needs to be verified against the installed gp.nvim version (commit `c37f154`).

### 2.11 lazy-lock.json — Plugin Version Pins

27 plugins pinned. All commits are specific SHAs. Key observations:

- `llama.vim` commit `a1c8e6e` — this is `ggml-org/llama.vim`, the official llama.cpp Neovim integration. Correct source.
- `gp.nvim` commit `c37f154` — needs verification that this version sets `ft = "gp"` for chat buffers (required for Edgy integration).
- `nvim-treesitter` commit `6620ae1` — treesitter is pinned, meaning parsers are also pinned. Running `:TSUpdate` will update parsers but the plugin version stays locked until `lazy-lock.json` is updated.
- No plugin has a `tag` pin — all are on branch HEAD commits. This means `Lazy update` moves every plugin to latest. Consider pinning critical plugins (treesitter, lspconfig, gp.nvim) to tags for stability.

---

## 3. Backend Integration Analysis

### 3.1 Process Architecture

The Jenova backend consists of three daemon processes managed as a unit by `bin/jenova-ca`:

| Process | Port | Role | Resource Profile |
|---|---|---|---|
| `llama-server` | 8081 | Main inference: 7B model, 16k ctx, 2 slots, dual Vulkan GPU, speculative decoding (0.5B drafter) | ~4.4 GiB GPU across both Vulkan devices + KV cache |
| `proxy.lua` | 8080 | Non-blocking async I/O proxy: RAG injection, intent routing, hybrid search, coroutine multiplexing | ~50-100 MiB RAM (LuaJIT + index data) |
| `llama-server --embedding` | 8082 | CPU-only embedding: nomic-embed-text-v1.5, 4k ctx | ~1 GiB RAM (model weights, CPU-only, Vulkan disabled) |

PID tracking: `.jenova/jenova-ca.pid` contains space-separated PIDs: `LLAMA_PID PROXY_PID [EMBED_PID]`.

### 3.2 Neovim Connections to Backend

Two Neovim plugins connect to the backend:

| Plugin | Endpoint | Connection Pattern |
|---|---|---|
| `llama.vim` | `:8081/infill` (direct) and `:8080/v1/chat/completions` (proxy) | Auto-fires on typing pause (500ms debounce). Uses slot for FIM completions. |
| `gp.nvim` | `:8080/v1/chat/completions` (proxy only) | User-initiated via keybinds. Uses slot for chat completions. RAG context injected by proxy. |

### 3.3 The Missing `jvim` Launcher

Currently there is no unified command that:
1. Ensures the Jenova CA backend is running
2. Sets LD_LIBRARY_PATH for llama.cpp shared libraries
3. Launches Neovim
4. On Neovim exit, conditionally stops the backend

`bin/jenova` does exactly this pattern for the CLI agent (lines 77-120: health check → start if needed → `STARTED_BY_THIS_INVOCATION` guard → run agent → cleanup on exit). `bin/llama-server-nvim` does steps 1-2 but exits after the health check — it doesn't launch Neovim or handle cleanup.

What's needed is `bin/jvim`: a script that mirrors `bin/jenova`'s lifecycle pattern but replaces `luajit "$AGENT_PATH"` with `nvim "$@"`.

### 3.4 `llama-server-nvim` HOST vs CONNECT_HOST Bug

`bin/llama-server-nvim` line 28 uses `"$HOST"` for the health check. `bin/jenova` line 30 uses `"$CONNECT_HOST"` (which defaults to `127.0.0.1`). If `HOST` is set to `0.0.0.0` (bind on all interfaces), `llama-server-nvim`'s health check tries to connect to `0.0.0.0` — which may work on some systems but is technically incorrect and fails on others. Should use `CONNECT_HOST` consistently.

### 3.5 `embed.lua` CTX_SIZE Residual Mismatch

`lib/embed.lua` line 20 hardcodes `local CTX_SIZE = 2048` with comment "nomic context window (max tokens)". The FIX.md ledger claims this was raised to 4096. The actual embed server launch in `bin/jenova-ca` uses `-c 4096`. The Lua-side variable is stale — though it's only used for documentation/reference in the current code (the actual context limit is enforced server-side), it's a consistency issue that could cause bugs if the variable is ever used for truncation logic.

---

## 4. Complete Issue Registry

Every issue found, categorised by severity, with exact file and line references.

### 4.1 SEVERITY: BREAKING (will cause runtime errors or dead functionality)

| # | File | Line(s) | Issue | Impact |
|---|---|---|---|---|
| B1 | `ui.lua` | 77 | `"vim.lsp.util.styled_pa_lines"` is not a real Neovim function. Should be `"vim.lsp.util.stylize_markdown"`. | Noice LSP markdown rendering override silently fails. Hover windows show raw markdown instead of rendered text. |
| B2 | `init.lua` + `lsp.lua` | 92, 95 | `<leader>ca` mapped globally to Jenova agent terminal AND buffer-locally to `vim.lsp.buf.code_action` on LspAttach. | Code Action always wins in code files. Jenova agent keybind is dead. |
| B3 | `gp.lua` + `git.lua` | 45, 41 | `<leader>gd` mapped globally to GpChatDelete AND buffer-locally to gitsigns `diffthis`. | In git repos, `<leader>gd` always diffs, never deletes chat. |
| B4 | `gp.lua` + `git.lua` | 44, 39 | `<leader>gr` mapped globally to GpChatRespond AND buffer-locally to gitsigns `reset_hunk`. | In git repos, `<leader>gr` always resets hunk, never responds to chat. |
| B5 | `gp.lua` + `git.lua` | 43, 48 | `<leader>gt` mapped globally to GpChatToggle AND buffer-locally to gitsigns `toggle_current_line_blame`. | In git repos, `<leader>gt` always toggles blame, never toggles chat. |

### 4.2 SEVERITY: FUNCTIONAL (things that work but produce wrong results or conflicts)

| # | File | Line(s) | Issue | Impact |
|---|---|---|---|---|
| F1 | `ui.lua` + `init.lua` | 113-143, 97-120 | Edgy.nvim and `:IDE` command both manage the three-panel layout. Two independent layout managers for the same windows. | Race conditions on panel open/focus. Double-opens, focus fighting, inconsistent state. |
| F2 | `gp.lua` | 39 | `os.execute("rm -rf " .. path .. "/*")` shells out unsafely. | If `stdpath("state")` returns unexpected value, destructive. Even normally, shell expansion edge cases. |
| F3 | `ui.lua` | 100 | `pcall(require("telescope").load_extension, "notify")` runs at noice/notify load time, but telescope may not be loaded yet. | Telescope notify extension silently fails to load. `:Telescope notify` command doesn't work. |
| F4 | `ui.lua` | 136-139 | Edgy expects `ft = "gp"` for AI Chat panel, but gp.nvim chat buffers may use `ft = "markdown"`. | If filetype mismatch, Edgy never captures gp.nvim windows into the right panel. Chat opens as a regular vsplit. |
| F5 | `llama.lua` | 5-6 | Hardcoded ports `8081` and `8080`. | If `jenova.conf` changes `LLAMA_PORT` or `PORT`, Neovim plugins still point to the old ports. Should be configurable or read from conf. |
| F6 | `gp.lua` | 7 | Hardcoded endpoint `http://127.0.0.1:8080`. | Same issue as F5 — not synced with jenova.conf. |
| F7 | `bin/llama-server-nvim` | 28 | Health check uses `$HOST` instead of `$CONNECT_HOST`. | Fails when HOST=0.0.0.0. |

### 4.3 SEVERITY: DESIGN (things that work but are suboptimal, inconsistent, or misleading)

| # | File | Line(s) | Issue | Impact |
|---|---|---|---|---|
| D1 | `ui.lua` | 51 | Which-key labels `<leader>g` as "Git" but it contains AI chat bindings too. | Confusing which-key popup. User thinks `<leader>g` is all git, doesn't find AI bindings. |
| D2 | `dashboard.lua` | 11 | ASCII art says "THE ARCANE TABLE" — old project name. | Branding inconsistency. Should say "JENOVA" or similar. |
| D3 | `init.lua` | 1 | Title says "NEVIM" — typo. | Should be "NEOVIM". |
| D4 | `mini.lua` + multiple | 16 | `mini.icons.mock_nvim_web_devicons()` replaces nvim-web-devicons but the actual plugin is still loaded. | Wasted startup time loading a plugin that's immediately overridden. |
| D5 | `git.lua` | 85 | vim-fugitive loaded unconditionally despite Neogit being the primary git interface. | Extra startup weight. Could be lazy-loaded via `cmd = "Git"`. |
| D6 | `lsp.lua` | 59 | `zls` and `bashls` in server list but no `get_cmd()` entries for FreeBSD path detection. | If installed to non-standard FreeBSD paths, silently fails to start. |
| D7 | `llama.lua` | 9, 13 | `auto_fim = true` with `n_predict = 128` fires constant HTTP requests using inference slots. | Slot contention with gp.nvim chat. Potential latency spikes under load. |
| D8 | `lsp.lua` | 151-163 | conform.nvim lists formatters (stylua, isort, black, goimports) without checking they're installed. | Format-on-save throws errors if a formatter is missing. `lsp_fallback = true` mitigates but user sees error notifications. |
| D9 | `lib/embed.lua` | 20 | `CTX_SIZE = 2048` hardcoded but embed server runs with `-c 4096`. | Stale variable. Not currently used for truncation but inconsistency risks future bugs. |
| D10 | — | — | No install, uninstall, or update script exists for the Neovim configuration. | Manual file copying, no dependency verification, no rollback path. |
| D11 | — | — | No `jvim` unified launcher script. | Backend lifecycle disconnected from Neovim lifecycle. Daemons pile up. |

---

## 5. Dependency Inventory

### 5.1 FreeBSD System Packages (required via `pkg install`)

| Package | Required By | Verified? |
|---|---|---|
| `neovim` (0.10+ or 0.11+) | Everything | Must support `vim.lsp.config` for 0.11+ path in lsp.lua |
| `git` | Lazy.nvim bootstrap, gitsigns, neogit, fugitive, diffview | Standard |
| `gmake` | telescope-fzf-native build | FreeBSD-specific: GNU Make |
| `luajit` | Jenova agent, proxy, embed, healthcheck | Required by jenova-ca |
| `llvm` (any supported version) | clangd (C/C++ LSP) | `get_cmd` tries clangd19..clangd15 |
| `rust-analyzer` | Rust LSP | Via `pkg` or `rustup component add` |
| `lua-language-server` | Lua LSP | `pkg install lua-language-server` |
| `py311-pyright` | Python LSP | `pkg install py311-pyright` |
| `go` | gopls (Go LSP) + goimports | gopls installed via mason or `go install` |
| `npm` or `node` | bashls (if desired) | `npm install -g bash-language-server` |
| `xclip` or `xsel` | `clipboard = "unnamedplus"` | Only needed for X11 clipboard integration |
| `vulkan-loader`, `vulkan-headers` | llama.cpp Vulkan backend | Required for dual-GPU inference |

### 5.2 Optional Formatters (required by conform.nvim)

| Formatter | Language | Install Method |
|---|---|---|
| `stylua` | Lua | `cargo install stylua` or `pkg install stylua` |
| `isort` | Python | `pip install isort` |
| `black` | Python | `pip install black` |
| `rustfmt` | Rust | Comes with Rust toolchain |
| `gofmt` | Go | Comes with Go toolchain |
| `goimports` | Go | `go install golang.org/x/tools/cmd/goimports@latest` |
| `clang-format` | C/C++ | Comes with LLVM package |
| `shfmt` | Shell (missing) | `pkg install shfmt` (if adding bash formatting) |

### 5.3 Neovim Plugins (27 total, managed by lazy.nvim)

All plugins are specified in the Lua files and pinned in `lazy-lock.json`. No missing dependencies — every plugin's `dependencies` field references plugins that are defined elsewhere in the configuration. The dependency graph is complete.

### 5.4 Missing Runtime Dependencies

| Missing | Impact | Fix |
|---|---|---|
| No check that jenova-ca backend is reachable before gp.nvim/llama.vim try to connect | Timeout errors and frozen UI on first AI request if backend is down | Add a health check autocommand or startup notification |
| No LD_LIBRARY_PATH set for llama.cpp shared libraries when launching Neovim directly | llama.vim may fail to connect if llama-server can't find its own .so files | Handled by `jvim` launcher |

---

## 6. Branching Strategy and Roadmap

Your proposed structure is close. Here's the corrected version that follows standard gitflow with topical branches:

```
main (stable, current, what's deployed now)
│
└─→ develop (integration branch — all PRs merge here first, only merge to main when stable)
    │
    ├─→ fix/nvim-bugs                    (Branch 1: all verified bugs)
    │   ├── PR #1: Fix noice styled_pa_lines typo
    │   ├── PR #2: Resolve all keybind collisions
    │   ├── PR #3: Replace os.execute rm -rf with vim.fn.delete
    │   ├── PR #4: Fix llama-server-nvim HOST vs CONNECT_HOST
    │   └── PR #5: Fix embed.lua CTX_SIZE to 4096
    │       → merge to develop → test → delete branch
    │
    ├─→ refactor/nvim-structure          (Branch 2: cohesion, structure, deduplication)
    │   ├── PR #6: Remove :IDE command, let Edgy own layout
    │   ├── PR #7: Split <leader>g namespace: git stays, AI moves to <leader>a
    │   ├── PR #8: Update which-key groups to match new namespaces
    │   ├── PR #9: Update dashboard branding to Jenova
    │   ├── PR #10: Fix init.lua title typo
    │   ├── PR #11: Lazy-load vim-fugitive via cmd = "Git"
    │   ├── PR #12: Disable nvim-web-devicons (mini.icons handles it)
    │   ├── PR #13: Restructure repo with install script and proper path mapping
    │   └── PR #14: Add deploy paths documentation
    │       → merge to develop → test → delete branch
    │
    ├─→ feat/nvim-lifecycle              (Branch 3: missing implementations)
    │   ├── PR #15: Create bin/jvim unified launcher
    │   ├── PR #16: Create install.sh (deps check + file deployment + conf sync)
    │   ├── PR #17: Create uninstall.sh (clean removal)
    │   ├── PR #18: Create update.sh (pull + lazy sync + mason update)
    │   ├── PR #19: Add Neovim startup health check for backend connectivity
    │   ├── PR #20: Add FreeBSD-specific LSP path entries for zls, bashls
    │   └── PR #21: Sync llama.vim/gp.nvim ports with jenova.conf (read from env or conf)
    │       → merge to develop → test → delete branch
    │
    └─→ feat/nvim-polish                 (Branch 4: tuning, UX, hardware optimization)
        ├── PR #22: Tune llama.vim: reduce n_predict, add FIM pause during chat
        ├── PR #23: Fix Telescope notify extension loading order
        ├── PR #24: Verify and fix Edgy ft="gp" detection for gp.nvim chat buffers
        ├── PR #25: Add conform.nvim formatter existence checks
        ├── PR #26: Add lualine component showing backend status (connected/disconnected)
        └── PR #27: Add Neovim checkhealth module for full Jenova diagnostics
            → merge to develop → test → delete branch

develop (all branches merged and tested)
│
└─→ main (final merge: new stable release)
```

---

## 7. Detailed PR Specifications

### Branch 1: `fix/nvim-bugs` — Verified Bugs Only

**PR #1: Fix noice `styled_pa_lines` typo**
- File: `ui.lua` line 77
- Change: `"vim.lsp.util.styled_pa_lines"` → `"vim.lsp.util.stylize_markdown"`
- Test: Open a file with LSP active, hover over a symbol with `K`. Verify the hover popup renders markdown (bold, code blocks) instead of showing raw markdown syntax.

**PR #2: Resolve all keybind collisions**
- Files: `init.lua`, `gp.lua`, `git.lua`, `lsp.lua`
- Changes:
  - Move ALL gp.nvim keybindings from `<leader>g*` to `<leader>a*` (AI namespace):
    - `<leader>ae` → Visual Chat (was `<leader>ge`)
    - `<leader>ac` → New Chat Fresh Context (was `<leader>gc`)
    - `<leader>at` → Toggle Chat (was `<leader>gt`)
    - `<leader>ar` → Chat Respond (was `<leader>gr`)
    - `<leader>ad` → Delete Chat (was `<leader>gd`)
    - `<leader>aw` → Visual Rewrite (was `<leader>gr` visual)
    - `<leader>ai` → Inline Rewrite (was `<leader>gi`)
  - Move Jenova agent terminal from `<leader>ca` to `<leader>aj` (AI → Jenova agent):
    - `<leader>aj` → `:term cd ~/Projects/jenova && bin/jenova<CR>`
  - `<leader>ca` now exclusively belongs to LSP code action (no collision).
- Test: In a git-tracked code file with LSP active, verify:
  - `<leader>gd` opens diff (gitsigns)
  - `<leader>ad` deletes chat (gp.nvim)
  - `<leader>ca` opens code action menu (LSP)
  - `<leader>aj` opens Jenova agent terminal

**PR #3: Replace unsafe `os.execute` with `vim.fn.delete`**
- File: `gp.lua` lines 38-42
- Change:
  ```lua
  vim.keymap.set("n", "<leader>ac", function()
      local chat_dir = vim.fn.stdpath("state") .. "/gp/chats"
      if vim.fn.isdirectory(chat_dir) == 1 then
          vim.fn.delete(chat_dir, "rf")
          vim.fn.mkdir(chat_dir, "p")
      end
      vim.cmd("1,$GpChatNew vsplit")
  end, opts("New Chat (Fresh Context)"))
  ```
- Test: Run `<leader>ac`, verify new chat opens and old chats are gone. Verify `~/.local/state/nvim/gp/chats/` is recreated.

**PR #4: Fix `llama-server-nvim` HOST vs CONNECT_HOST**
- File: `bin/llama-server-nvim` line 28
- Change: Add `CONNECT_HOST="${JENOVA_CONNECT_HOST:-127.0.0.1}"` after conf loading, and change `check_health()` to use `"$CONNECT_HOST"` and `"$PORT"` instead of `"$HOST"` and `"$PORT"`.
- Also update the endpoint display lines to use `CONNECT_HOST`.
- Test: Set `JENOVA_HOST=0.0.0.0` in jenova.conf, run `bin/llama-server-nvim`, verify health check succeeds.

**PR #5: Fix embed.lua CTX_SIZE**
- File: `lib/embed.lua` line 20
- Change: `local CTX_SIZE = 2048` → `local CTX_SIZE = 4096`
- Also update comment: `-- nomic context window (max tokens) — must match -c in jenova-ca`
- Test: Verify embed server still starts and returns embeddings.

### Branch 2: `refactor/nvim-structure` — Cohesion and Structure

**PR #6: Remove `:IDE` command, let Edgy own layout**
- File: `init.lua` lines 96-120
- Change: Delete the entire `:IDE` command. Edgy already manages NvimTree (left top), Trouble (left bottom), and gp.nvim chat (right). Users trigger the layout by opening any of these panels — Edgy automatically docks them.
- Add a replacement convenience command that just opens the first file and lets Edgy do its thing:
  ```lua
  vim.api.nvim_create_user_command("IDE", function()
    if vim.bo.filetype == "alpha" then vim.cmd("bd") end
    vim.cmd("NvimTreeOpen")
  end, { desc = "Open IDE panels (Edgy auto-manages layout)" })
  ```
- Test: Run `:IDE`, verify NvimTree opens on left, Trouble appears below it, and opening a gp.nvim chat docks to the right.

**PR #7: Split `<leader>g` namespace**
- Already done in PR #2 (keybind changes). This PR ensures all references in comments and documentation are updated.

**PR #8: Update which-key groups**
- File: `ui.lua` lines 50-55
- Change:
  ```lua
  spec = {
    { "<leader>f", group = "Find" },
    { "<leader>g", group = "Git" },
    { "<leader>a", group = "AI" },
    { "<leader>c", group = "Code" },
    { "<leader>r", group = "Rename" },
    { "<leader>x", group = "Diagnostics" },
  },
  ```

**PR #9: Update dashboard branding**
- File: `dashboard.lua` line 11
- Change: Replace "THE ARCANE TABLE" ASCII art with "JENOVA" ASCII art.
- Also update the comment on line 10 from `-- THE ARCANE TABLE ASCII Art Header` to `-- JENOVA ASCII Art Header`.

**PR #10: Fix init.lua title typo**
- File: `init.lua` line 2
- Change: `NEVIM` → `NEOVIM`

**PR #11: Lazy-load vim-fugitive**
- File: `git.lua` line 85
- Change: `{ "tpope/vim-fugitive" }` → `{ "tpope/vim-fugitive", cmd = { "Git", "G", "Gwrite", "Gread", "Gdiffsplit" } }`
- Test: Fugitive commands still work when invoked, but don't load at startup.

**PR #12: Disable nvim-web-devicons**
- File: `mini.lua` — add to mini.nvim spec:
  ```lua
  { "nvim-tree/nvim-web-devicons", enabled = false },
  ```
  This tells lazy.nvim to skip loading it entirely. mini.icons' mock satisfies all `require("nvim-web-devicons")` calls.
- Test: Icons still render correctly in NvimTree, Telescope, Lualine, Alpha.

**PR #13: Create install script and restructure repo**
- See Section 8 below for full script specification.

**PR #14: Add deploy paths documentation**
- Add a `DEPLOY.md` documenting the mapping between repo files and filesystem locations.

### Branch 3: `feat/nvim-lifecycle` — Missing Implementations

**PR #15: Create `bin/jvim`**
- New file: `bin/jvim`
- Pattern: Mirror `bin/jenova` lifecycle exactly:
  1. Source `etc/jenova.conf`
  2. Set `CONNECT_HOST`, `LD_LIBRARY_PATH`
  3. Health check → start `jenova-ca --daemon` if needed → track `STARTED_BY_THIS_INVOCATION`
  4. Wait for ready (health check loop with fast-fail on dead PIDs)
  5. `exec nvim "$@"` (replaces shell process with Neovim)
  6. Trap EXIT/INT/TERM → if started by this invocation, run `jenova-ca stop`
- Note: because `exec nvim` replaces the process, the cleanup trap fires when Neovim exits.
- Test: Run `jvim somefile.lua`, verify backend starts, Neovim opens, llama.vim/gp.nvim connect. Exit Neovim, verify backend stops (if started by jvim). Run `jvim` when backend is already running from `bin/jenova`, verify backend stays running after Neovim exits.

**PR #16: Create `install.sh`**
- New file: `install.sh` (in Neovim config repo root)
- Functions:
  1. Check FreeBSD version (`uname -s` = FreeBSD, `uname -r` ≥ 15)
  2. Check required packages: `neovim`, `git`, `gmake`, `luajit`
  3. Check optional packages: list missing LSP servers and formatters, warn but don't fail
  4. Create `~/.config/nvim/` directory structure
  5. Deploy `init.lua` → `~/.config/nvim/init.lua`
  6. Deploy all other `.lua` files → `~/.config/nvim/lua/plugins/`
  7. Deploy `lazy-lock.json` → `~/.config/nvim/lazy-lock.json`
  8. If Jenova is installed (`~/Projects/jenova/etc/jenova.conf` exists), offer to install `jvim` symlink to `~/Projects/jenova/bin/jvim`
  9. Print summary of what was installed and what's missing

**PR #17: Create `uninstall.sh`**
- Removes `~/.config/nvim/` contents (with confirmation prompt)
- Does NOT remove `~/.local/share/nvim/` (plugin data, lazy.nvim) or `~/.local/state/nvim/` (undo files, shada)
- Optionally remove plugin data with `--purge` flag

**PR #18: Create `update.sh`**
- Pulls latest from git repo
- Redeploys files (same logic as install.sh)
- Runs `nvim --headless "+Lazy restore" +qa` to sync plugins to lock file
- Optionally runs `nvim --headless "+Lazy update" +qa` with `--upgrade` flag to update plugins

**PR #19: Neovim startup health check**
- Add to `init.lua`: an autocommand that checks backend connectivity on `VimEnter`:
  ```lua
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
      vim.defer_fn(function()
        local ok = pcall(vim.fn.system, "curl -sf -o /dev/null http://127.0.0.1:8080/health")
        if not ok or vim.v.shell_error ~= 0 then
          vim.notify("Jenova CA backend not running. AI features unavailable.\nRun: jvim or bin/llama-server-nvim", vim.log.levels.WARN)
        end
      end, 1000) -- 1s delay to not block startup
    end,
    once = true,
  })
  ```

**PR #20: Add FreeBSD LSP path entries**
- File: `lsp.lua` `get_cmd()` function
- Add entries:
  ```lua
  elseif server == "zls" then
    if vim.fn.executable("zls") == 1 then return { "zls" } end
  elseif server == "bashls" then
    if vim.fn.executable("bash-language-server") == 1 then return { "bash-language-server", "start" } end
  ```

**PR #21: Sync plugin ports with jenova.conf**
- Read ports from environment variables or a Neovim-accessible config:
  ```lua
  -- In llama.lua:
  local fim_port = vim.env.JENOVA_LLAMA_PORT or "8081"
  local proxy_port = vim.env.JENOVA_PORT or "8080"
  vim.g.llama_config = {
    endpoint_fim  = "http://127.0.0.1:" .. fim_port .. "/infill",
    endpoint_inst = "http://127.0.0.1:" .. proxy_port .. "/v1/chat/completions",
    ...
  }
  ```
- Same pattern in `gp.lua` for the OpenAI endpoint.
- This means `jvim` exports these env vars before launching Neovim, and the plugins pick them up dynamically.

### Branch 4: `feat/nvim-polish` — Tuning and UX

**PR #22: Tune llama.vim FIM behavior**
- File: `llama.lua`
- Changes:
  - Reduce `n_predict` from 128 to 64 (faster completions, less slot time)
  - Reduce `n_prefix` from 256 to 128 (less context sent per request)
  - Add a note about `auto_fim = false` as an option for constrained systems

**PR #23: Fix Telescope notify extension loading**
- File: `ui.lua` lines 96-101
- Change: Move the `load_extension` call to a `VeryLazy` autocommand or use Telescope's `extensions` config:
  ```lua
  config = function(_, opts)
    local notify = require("notify")
    notify.setup(opts)
    vim.notify = notify
    -- Defer telescope extension load until telescope is available
    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyLoad",
      callback = function(ev)
        if ev.data == "telescope.nvim" then
          pcall(require("telescope").load_extension, "notify")
          return true -- remove autocmd after firing
        end
      end,
    })
  end,
  ```

**PR #24: Verify Edgy gp.nvim filetype detection**
- Check gp.nvim commit `c37f154` to determine the filetype set on chat buffers.
- If `ft = "markdown"`, change Edgy config:
  ```lua
  right = {
    {
      title = "AI Chat",
      ft = "markdown",
      filter = function(buf)
        return vim.b[buf].gp_chat ~= nil
      end,
      pinned = true,
      size = { width = 0.3 },
    },
  },
  ```
- Or, if gp.nvim does set `ft = "gp"`, no change needed. Must verify.

**PR #25: Add conform.nvim formatter checks**
- File: `lsp.lua` conform.nvim config
- Wrap `format_on_save` in a check:
  ```lua
  format_on_save = function(bufnr)
    local ft = vim.bo[bufnr].filetype
    local formatters = require("conform").list_formatters(bufnr)
    if #formatters == 0 then return end -- no formatter available, skip silently
    return { timeout_ms = 500, lsp_fallback = true }
  end,
  ```

**PR #26: Lualine backend status component**
- File: `ui.lua` lualine config
- Add a custom component that shows "AI: ●" (green) or "AI: ○" (red) based on a cached health check result:
  ```lua
  sections = {
    lualine_x = {
      {
        function()
          return vim.g.jenova_connected and "AI: ●" or "AI: ○"
        end,
        color = function()
          return { fg = vim.g.jenova_connected and "#98BB6C" or "#FF5D62" }
        end,
      },
      "encoding", "fileformat", "filetype",
    },
  },
  ```
  With a timer-based health check that runs every 30 seconds and updates `vim.g.jenova_connected`.

**PR #27: Checkhealth module**
- New file: `lua/plugins/health.lua` (or as part of init.lua)
- Creates a `:checkhealth jenova` command that verifies:
  1. Jenova CA backend reachable on proxy port
  2. llama-server reachable on FIM port
  3. Embedding server reachable on embed port
  4. All required FreeBSD packages installed
  5. All formatters installed
  6. GPU status (Vulkan devices detected)
  7. Memory pressure (free RAM vs expected usage)

---

## 8. Install / Uninstall / Update Script Specifications

### 8.1 `install.sh`

```
Usage: ./install.sh [--force] [--link]

Options:
  --force    Overwrite existing ~/.config/nvim without prompting
  --link     Use symlinks instead of copies (for development)

Steps:
  1. Verify FreeBSD >= 15
  2. Check required packages (exit 1 if missing critical ones)
  3. Check optional packages (warn for missing)
  4. Backup existing ~/.config/nvim to ~/.config/nvim.bak.TIMESTAMP
  5. Create directory structure
  6. Deploy files (copy or symlink based on --link)
  7. Print dependency status summary
  8. Print "Run :Lazy install inside Neovim to install plugins"
```

### 8.2 `uninstall.sh`

```
Usage: ./uninstall.sh [--purge]

Options:
  --purge    Also remove plugin data (~/.local/share/nvim/lazy/)

Steps:
  1. Confirm with user
  2. Remove ~/.config/nvim/init.lua and lua/plugins/*.lua
  3. Optionally remove lazy.nvim data
  4. Keep undo files, shada, state (user data)
```

### 8.3 `update.sh`

```
Usage: ./update.sh [--upgrade-plugins]

Options:
  --upgrade-plugins    Run :Lazy update (move to latest versions)
                       Without this flag, runs :Lazy restore (pin to lock file)

Steps:
  1. git pull (update config repo)
  2. Redeploy files to ~/.config/nvim
  3. Run headless Neovim to sync plugins
  4. Print changelog summary
```

---

## 9. FreeBSD and Hardware Optimizations

### 9.1 Already Implemented (in jenova-setup)

- `vm.panic_on_oom = 0` — prevents kernel panic under OOM, lets pager work
- `vm.disable_swapspace_pageouts = 0` — ensures swap is active
- `vm.pageout_update_period = 1` — fast pageout cycle for aggressive swapping of cold pages
- `vm.v_free_target` = 2 GiB worth of pages — keeps headroom for Iris Xe UMA allocations
- `vm.v_inactive_target` = 3 GiB worth of pages — large inactive pool for swap candidates
- `vm.inact_scan_laundry_weight = 25` — aggressive inactive page scanning
- `vfs.zfs.arc_max = 1073741824` (1 GiB) — caps ZFS ARC to preserve RAM for GPU
- NVMe interrupt coalescing disabled — lowest possible swap latency

### 9.2 Neovim-Specific Optimizations to Add

| Optimization | Where | Rationale |
|---|---|---|
| `vim.opt.swapfile = false` | `init.lua` | Swap files are redundant with ZFS snapshots and persistent undo. Eliminates periodic disk writes. |
| `vim.opt.lazyredraw = true` | `init.lua` | Prevents screen redraws during macros and commands. Reduces CPU load during batch operations. |
| Disable LSP servers for non-project filetypes | `lsp.lua` | Don't start pyright when editing a Makefile. Add filetype guards to server setup. |
| Reduce treesitter `ensure_installed` to actually used languages | `editor.lua` | Every parser consumes RAM. If Zig isn't being used, don't load the parser. |
| Set `vim.opt.maxmempattern = 2000` | `init.lua` | Default is 1000. Large pattern matching in treesitter can hit this limit on complex files. FreeBSD's memory is tight but pattern memory is tiny. |

### 9.3 Memory Budget

Estimated RAM usage when fully operational with `jvim`:

| Component | Estimated RAM |
|---|---|
| FreeBSD kernel + base | ~500 MiB |
| ZFS ARC (capped) | 1024 MiB |
| Iris Xe UMA allocation (Vulkan1) | ~3000 MiB (from system RAM) |
| llama-server main (CPU tensors, mmap'd) | ~2000 MiB resident (rest paged to Optane) |
| llama-server embed (CPU-only, nomic) | ~1000 MiB |
| proxy.lua (LuaJIT) | ~100 MiB |
| Neovim + plugins | ~200 MiB |
| LSP servers (all active) | ~500 MiB (clangd is the heavy one) |
| **Total resident** | **~8.3 GiB** |
| Available for page cache / headroom | ~7.7 GiB |
| Optane swap available | 27 GiB (for cold tensor pages) |

This fits within 16 GiB with headroom, but only because cold tensor pages swap to Optane. If multiple LSP servers are active simultaneously (clangd + pyright + gopls + rust-analyzer), the LSP budget can spike to 1+ GiB.

---

## 10. Execution Order

1. **Create `develop` branch from `main`:** `git checkout -b develop main`
2. **Branch 1 (`fix/nvim-bugs`):** 5 PRs, all surgical fixes. Merge to develop. Test all plugins load without error, all keybinds work as intended, health checks pass.
3. **Branch 2 (`refactor/nvim-structure`):** 9 PRs, structural changes. Merge to develop. Test layout management (Edgy only), which-key groups, branding, install script.
4. **Branch 3 (`feat/nvim-lifecycle`):** 7 PRs, new functionality. Merge to develop. Test `jvim` full lifecycle, install/uninstall/update scripts, backend connectivity notification.
5. **Branch 4 (`feat/nvim-polish`):** 6 PRs, tuning and UX. Merge to develop. Test FIM performance, lualine status, checkhealth output.
6. **Final: merge `develop` → `main`.** Tag as release. This is the new stable baseline.

Total PRs: 27. Estimated scope: Branches 1-2 are quick (mostly line edits). Branch 3 is the bulk of new code (jvim script, install scripts, health checks). Branch 4 is iterative tuning.
