# Jenova Vim (jvim) — High-Performance Neovim Distribution & AI IDE

**jvim** is a standalone, lightweight, and blazingly fast Neovim distribution optimized for systems engineering and AI-assisted development. It pairs a **100% first-party native Lua UI stack** with vendored backend dependencies and deep integration with the **Jenova AI** ecosystem (FIM inline completion, multi-turn chat, autonomous agent capabilities, and local network discovery).

---

## Key Features & Philosophy

- **100% First-Party Native UI Architecture**: Replaces generic third-party UI plugins (*Telescope*, *Nvim-Tree*, *Lualine*, *Bufferline*, *Which-Key*, *Indent-Blankline*, *Trouble*, *Edgy*, *Noice*, *Nvim-Notify*) with custom, lightweight, native modules built specifically for Neovim 0.10+.
- **Vendored & Self-Contained Ecosystem**: Core backend capabilities (LSP config, Treesitter, Git integration, Conform formatting, CMP engine) live directly inside the `pack/` directory. Zero package manager overhead and zero internet required on initial boot.
- **Jenova AI Integration**: Built-in local FIM (Fill-in-the-middle) code completion (`llama.vim`), interactive AI Chat drawer, context compaction, autonomous tool execution engine, LAN server discovery, and backend telemetry monitoring.
- **Cross-Platform & FreeBSD Detection**: Automatically detects system compiler and language server versions across Linux, macOS, and FreeBSD (e.g., versioned `clangd19`, `py311-pyright`, `nimlsp`/`nimlangserver`).

---

## Installation & Setup

### Quick Installation (Deploy Script)

Run the provided installation script to symlink the configuration to `~/.config/jvim` and add the `jvi` terminal alias to your shell profile (`~/.bashrc` / `~/.zshrc`):

```bash
./install.sh
```

### Manual Installation

1. Symlink or copy this repository to your Neovim configuration directory:
   ```bash
   ln -s "$(pwd)" ~/.config/jvim
   ```
2. Add the `jvi` alias to your shell configuration (`~/.bashrc` or `~/.zshrc`):
   ```bash
   alias jvi='NVIM_APPNAME=jvim nvim'
   ```
3. Source your shell configuration or open a new terminal:
   ```bash
   source ~/.bashrc
   ```

### Launching the IDE

Start `jvim` using the `jvi` executable alias:

```bash
jvi
```

*(Note: `jvi` accepts standard Neovim command-line flags, e.g., `jvi .` or `jvi src/main.rs`)*.

---

## Directory & Architecture Structure

```
jvim/
├── init.lua                   # Entry point: global options, spec runner, keymaps, health checks
├── install.sh                 # Deployment script for symlinking & shell alias creation
├── LICENSE                    # BSD 2-Clause License
├── README.md                  # Comprehensive user-facing documentation
├── colors/
│   └── jvim.lua               # Custom jvim dark theme and highlight groups
├── doc/
│   └── jvim.txt               # Native Vim help tag documentation (:help jvim)
├── lua/
│   ├── jvim/                  # First-party UI modules
│   │   ├── tree.lua           # File explorer sidebar with Git badges & buffer sync
│   │   ├── finder.lua         # Floating fuzzy finder (files, grep, buffers, help, diagnostics)
│   │   ├── diagnostics_list.lua # Workspace and buffer diagnostic list panel
│   │   ├── layout.lua         # IDE panel coordinator (explorer, diagnostics, terminal)
│   │   ├── notify.lua         # Floating notification queue (replaces nvim-notify)
│   │   ├── messages.lua       # :messages mirror routed through jvim.notify
│   │   ├── statusline.lua     # Global statusline (mode, file, git branch, lsp, FIM state)
│   │   ├── tabline.lua        # Buffer tab bar with modified indicators
│   │   ├── keyhelp.lua        # Leader-prefix popup (replaces which-key.nvim)
│   │   ├── indent_guides.lua  # Extmark-based indent guide lines
│   │   ├── terminal.lua       # Integrated toggleable shell & AI terminals
│   │   ├── dashboard.lua      # Start screen dashboard renderer
│   │   ├── icons.lua          # Filetype glyphs & nvim-web-devicons shim
│   │   └── ui.lua             # Floating overrides for vim.ui.input and vim.ui.select
│   ├── jenova/                # AI Agent & Backend integration
│   │   ├── chat.lua           # Interactive AI Chat, inline rewrites, diagnostic auto-fix
│   │   ├── agent/             # Context compaction, memory, execution engine, tool registry
│   │   ├── lan.lua            # Automated LAN discovery for remote Jenova CA servers
│   │   ├── monitor.lua        # Real-time telemetry dashboard for Jenova CA backend
│   │   ├── health.lua         # Custom :checkhealth jenova diagnostic suite
│   │   ├── spec_runner.lua    # Native plugin spec evaluator
│   │   └── endpoints.lua      # Server URL and port resolution
│   └── plugins/               # Declarative plugin spec configurations
│       ├── editor.lua         # Treesitter & Conform format-on-save
│       ├── git.lua            # Gitsigns, Neogit, Diffview, Fugitive
│       ├── lsp.lua            # LSP config, FreeBSD binary discovery, CMP completion engine
│       ├── llama.lua          # Llama.vim FIM autocomplete setup
│       ├── chat.lua           # Jenova AI module launcher
│       ├── health.lua         # Health check specs
│       ├── ui.lua             # UI hooks
│       ├── mini.lua           # Mini utilities
│       └── dashboard.lua      # Dashboard spec
├── pack/
│   └── jenova/start/          # Vendored community plugins auto-loaded by Neovim
└── plugin/
    ├── jvim_ui.lua            # Startup initialization hook for all jvim native UI modules
    └── jvim_dashboard.lua     # Startup hook for jvim dashboard
```

---

## Keymaps Reference

The leader key is set to `<Space>`.

### 1. Core & Window Navigation

| Keybinding | Mode | Description |
| :--- | :--- | :--- |
| `<leader>w` | Normal | Save current buffer (`:w`) |
| `<leader>q` | Normal | Quit current window (`:q`) |
| `<Esc>` | Normal | Clear search highlight (`:nohlsearch`) |
| `<leader>/` | Normal / Visual | Toggle comment on line / selection (`gcc` / `gc`) |
| `<C-h>` | Normal | Jump to Left Window |
| `<C-j>` | Normal | Jump to Lower Window |
| `<C-k>` | Normal | Jump to Upper Window |
| `<C-l>` | Normal | Jump to Right Window |
| `<S-h>` | Normal | Switch to Previous Buffer |
| `<S-l>` | Normal | Switch to Next Buffer |
| `<leader>bd` | Normal | Delete buffer (preserves window split layout) |
| `<leader>bD` | Normal | Delete buffer forcefully (discard changes) |

---

### 2. File Explorer & Fuzzy Finder (`jvim.tree` & `jvim.finder`)

| Keybinding | Command / Function | Description |
| :--- | :--- | :--- |
| `<leader>e` | `jvim.tree.toggle()` | Toggle File Explorer sidebar |
| `<leader>ff` | `:JvimFindFiles` | Open Fuzzy File Finder (`fd` / `find` / `vim.fs`) |
| `<leader>fg` | `:JvimFindGrep` | Open Live Grep (requires `rg`) |
| `<leader>fb` | `:JvimFindBuffers` | Switch Active Listed Buffers |
| `<leader>fh` | `:JvimFindHelp` | Search Neovim Help Tags |
| `<leader>fo` | `:JvimFindOldfiles` | Browse Recent Files (`vim.v.oldfiles`) |
| `<leader>fd` | `:JvimFindDiagnostics` | Filter Workspace Diagnostics |

---

### 3. LSP & Code Formatting

| Keybinding | Action | Description |
| :--- | :--- | :--- |
| `gd` | `vim.lsp.buf.definition` | Go to Definition under cursor |
| `K` | `vim.lsp.buf.hover` | Show Hover Information popup |
| `<leader>ca` | `vim.lsp.buf.code_action` | Trigger LSP Code Action |
| `<leader>rn` | `vim.lsp.buf.rename` | Rename Symbol under cursor |
| `<leader>cd` | `vim.diagnostic.open_float` | Show Floating Diagnostics for line |
| `<leader>cf` | `conform.format` | Format current buffer (LSP fallback) |
| `[d` | `vim.diagnostic.jump(-1)` | Jump to Previous Diagnostic |
| `]d` | `vim.diagnostic.jump(1)` | Jump to Next Diagnostic |

---

### 4. Git Integration (`gitsigns`, `neogit`, `diffview`, `fugitive`)

| Keybinding | Action | Description |
| :--- | :--- | :--- |
| `]h` / `[h` | `gitsigns.nav_hunk` | Move to Next / Previous Git Hunk |
| `<leader>gs` | `gitsigns.stage_hunk` | Stage Hunk under cursor (or Visual selection) |
| `<leader>gS` | `gitsigns.stage_buffer` | Stage entire Buffer |
| `<leader>gu` | `gitsigns.undo_stage_hunk` | Undo last staged hunk |
| `<leader>gR` | `gitsigns.reset_buffer` | Reset all buffer changes |
| `<leader>gr` | `gitsigns.reset_hunk` | Reset selected hunk in Visual mode |
| `<leader>gp` | `gitsigns.preview_hunk` | Preview Hunk float |
| `<leader>gb` | `gitsigns.blame_line` | Detailed Git Blame for line |
| `<leader>gB` | `gitsigns.toggle_current_line_blame` | Toggle Inline Git Blame |
| `<leader>gd` | `gitsigns.diffthis` | Diff current buffer against index |
| `<leader>gD` | `gitsigns.diffthis("~")` | Diff current buffer against last commit |
| `<leader>gg` | `:Neogit` | Open Neogit interactive status UI |
| `<leader>gv` | `:DiffviewOpen` | Open side-by-side Git Diffview |
| `<leader>gh` | `:DiffviewFileHistory %` | View Git history for current file |
| `<leader>gH` | `:DiffviewFileHistory` | View Git history for entire repository |
| `<leader>gc` | `:DiffviewClose` | Close Diffview panel |
| `<leader>gf` | `:Git` | Open Fugitive status window |

---

### 5. Diagnostics List & IDE Layout (`jvim.diagnostics_list` & `jvim.layout`)

| Keybinding | Command / Function | Description |
| :--- | :--- | :--- |
| `<leader>xx` | `diagnostics_list.toggle("workspace")` | Toggle Workspace Diagnostics Panel |
| `<leader>xb` | `diagnostics_list.toggle("buffer")` | Toggle Buffer Diagnostics Panel |
| `<leader>xq` | `:copen` | Open Quickfix List |
| `<leader>xl` | `:lopen` | Open Location List |
| `<leader>ti` | `:IDE` | Open/Toggle complete IDE panel layout |

---

### 6. Terminal (`jvim.terminal`)

| Keybinding | Function | Description |
| :--- | :--- | :--- |
| `<leader>tt` | `terminal.toggle_shell()` | Toggle Bottom Shell Terminal |
| `<leader>tn` | `terminal.new_shell()` | Spawn New Shell Terminal Instance |
| `<leader>atj` | `terminal.toggle_jenova()` | Toggle Dedicated Jenova Terminal |

---

### 7. Jenova AI Integration (`jenova.chat`, `llama.vim`, `jenova.lan`, `jenova.monitor`)

| Keybinding | Function | Description |
| :--- | :--- | :--- |
| `<leader>aa` | `chat.toggle_chat()` | Toggle Jenova AI Chat Drawer |
| `<leader>ac` | `chat.chat_with_context()` | Open Chat pre-loaded with current file context |
| `<leader>an` | `chat.open_chat()` | Open New Chat buffer |
| `<leader>ar` | `chat.respond()` | Send prompt response in chat buffer |
| `<leader>ae` | `chat.visual_chat()` | Visual Chat: Send selected text to AI |
| `<leader>aw` | `chat.visual_rewrite()` | Visual Rewrite: Ask AI to refactor selected code |
| `<leader>ai` | `chat.inline_rewrite()` | Trigger Inline Code Rewrite prompt |
| `<leader>as` | `chat.web_search()` | Perform Web Search query via AI agent |
| `<leader>ax` | `chat.stop()` | Stop active AI response generation |
| `<leader>af` | *Toggle FIM* | Toggle Llama.vim Fill-in-the-middle FIM completion |
| `<leader>atd` | *Fix Diagnostics* | Send current buffer LSP errors to AI for auto-fix |
| `<leader>amm` | `chat.toggle_mode()` | Toggle Agent Mode vs. Conversation Mode |
| `<leader>amr` | `chat.agent_reset()` | Reset AI Agent working memory & context |
| `<leader>amf` | `chat.fresh_chat()` | Clear chat history & start fresh session |
| `<leader>amd` | `chat.delete_chat()` | Delete active chat file |
| `<leader>atm` | `:JenovaMonitor` | Open Jenova CA telemetry monitor dashboard |
| `<leader>ath` | `:checkhealth jenova` | Run Jenova health check diagnostic suite |
| `<leader>atl` | `:JenovaLanScan` | Scan local network (LAN) for Jenova CA servers |
| `<leader>h` / `<leader>ah` | `:JvimDashboard` | Open JVim Start Dashboard |

---

## User Commands Reference Table

| User Command | Module | Description |
| :--- | :--- | :--- |
| `:IDE` | `jvim.layout` | Toggle unified IDE panel layout (explorer, diagnostics, terminal) |
| `:JvimDashboard` | `jvim.dashboard` | Open the jvim home dashboard |
| `:JvimFindFiles` | `jvim.finder` | Launch fuzzy file finder |
| `:JvimFindBuffers` | `jvim.finder` | Launch buffer selector |
| `:JvimFindGrep` | `jvim.finder` | Launch live ripgrep picker |
| `:JvimFindHelp` | `jvim.finder` | Search Neovim help documentation tags |
| `:JvimFindOldfiles` | `jvim.finder` | Browse recent files history |
| `:JvimFindDiagnostics` | `jvim.finder` | Search workspace diagnostics |
| `:JenovaChat` | `jenova.chat` | Toggle Jenova AI Chat window |
| `:JenovaChatNew` | `jenova.chat` | Create a new AI chat session |
| `:JenovaChatRespond` | `jenova.chat` | Trigger response generation for active prompt |
| `:JenovaChatDelete` | `jenova.chat` | Delete current chat session file |
| `:JenovaChatFresh` | `jenova.chat` | Clear session context and wipe prompt buffer |
| `:JenovaChatStop` | `jenova.chat` | Abort active streaming generation |
| `:JenovaWebSearch` | `jenova.chat` | Run web search query via Jenova agent |
| `:JenovaChatContext` | `jenova.chat` | Attach current buffer content to new AI chat |
| `:JenovaToggleMode` | `jenova.chat` | Toggle between autonomous Agent mode & Chat mode |
| `:JenovaAgentReset` | `jenova.chat` | Reset agent memory compactor and context window |
| `:JenovaMonitor` | `jenova.monitor` | Open real-time backend telemetry monitor panel |
| `:JenovaLanScan` | `jenova.lan` | Scan local network for remote Jenova CA host |
| `:ConformInfo` | `conform.nvim` | Display registered formatters for current buffer |
| `:checkhealth jenova` | `jenova.health` | Run diagnostic suite for Jenova backend & tools |

---

## First-Party UI Modules & Tooling Details

### 1. `jvim.tree` (File Explorer)
Custom tree explorer replacing `nvim-tree.lua`. Features:
- Real-time Git status indicator badges (`M` modified, `A` added, `?` untracked).
- Automatic synchronization with active editor buffer.
- Keybinds inside tree window: `<CR>` to open, `a` to create file/folder, `d` to delete, `r` to rename, `R` to refresh.

### 2. `jvim.finder` (Fuzzy Finder & Search Tooling)
Fast, native floating picker module replacing `telescope.nvim`.
- **System Binary Dependencies & Fallbacks**:
  - `JvimFindGrep` (`<leader>fg`): Requires **`rg`** (*ripgrep*). Executes synchronous debounced searches against the workspace.
  - `JvimFindFiles` (`<leader>ff`): Prefers **`fd`** if installed, falls back to **`find`**, and ultimately falls back to native `vim.fs` walking.
  - `JvimFindOldfiles` (`<leader>fo`): Inspects Neovim's ShaDa history (`vim.v.oldfiles`), filtering out deleted or unstat'able file paths via `uv.fs_stat`.
  - `JvimFindBuffers` (`<leader>fb`), `JvimFindHelp` (`<leader>fh`), `JvimFindDiagnostics` (`<leader>fd`): Use internal Neovim buffer and diagnostic APIs.

### 3. `jvim.layout` (IDE Layout Coordinator)
Coordinates window arrangements to ensure split boundaries remain clean when opening sidebars, diagnostics lists, and terminals.

### 4. `jvim.notify` & `jvim.messages`
Custom notification system rendering floating status alerts in the top-right corner. `:messages` output is automatically mirrored into `jvim.notify`.

### 5. `jvim.statusline` & `jvim.tabline`
Custom status bar providing vim mode highlights, relative file paths, Git branch name, LSP status, and FIM auto-complete state (`FIM: ON/OFF`).

### 6. `jvim.keyhelp`
Popup menu that appears after pressing leader prefix combinations, displaying available key mappings grouped by category without external dependencies.

---

## Environment Variables & Backend Integration

`jvim` communicates with the local or remote Jenova CA backend using TCP socket probes and HTTP endpoints configured via environment variables:

| Environment Variable | Default Value | Description |
| :--- | :--- | :--- |
| `JENOVA_CONNECT_HOST` | `127.0.0.1` | Explicit remote Jenova CA IP/hostname |
| `JENOVA_HOST` | `127.0.0.1` | Fallback Jenova backend bind host |
| `JENOVA_PORT` | `8080` | Main API proxy & intelligence server port |
| `JENOVA_LLAMA_PORT` | `8081` | Dedicated FIM completion server port |
| `JENOVA_LAN_MODE` | `0` | Set to `1` to force auto-scanning local subnet on startup |
| `JENOVA_ROOT` | *(none)* | Root directory of Jenova system workspace |

---

## Health Checks & Troubleshooting

If AI features or LSP integration exhibit issues:

1. Run the native health check command:
   ```vim
   :checkhealth jenova
   ```
2. Verify system binary availability for finder tools:
   ```bash
   which rg fd clangd rust-analyzer
   ```
3. Test network connectivity to local or remote Jenova CA backend:
   ```vim
   :JenovaLanScan
   ```
4. View real-time backend status and model load:
   ```vim
   :JenovaMonitor
   ```

---

## License

This project is licensed under the BSD 2-Clause License. See the [LICENSE](LICENSE) file for details.
