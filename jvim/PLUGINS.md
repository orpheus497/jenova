External Plugin Dependencies & Compatibility
=============================================

This document catalogues every external plugin that jvim and the
[Jenova Cognitive Architecture](https://github.com/orpheus497/jenova) currently
depend on, analyses their compatibility with jvim, and outlines the
roadmap for replacing them with jvim-native implementations.

> **Naming convention:** *jvim* is the editor (this repository). *Jenova* is
> the cognitive architecture ([orpheus497/jenova](https://github.com/orpheus497/jenova)).

## Installing jvim alongside Jenova

The two repositories are designed to be installed together:

1. **Build & install jvim** (this repo) so the `jvim` binary on `PATH`
   reports a `JVIM` version string:

   ```sh
   git clone https://github.com/orpheus497/jvim
   cd jvim
   make CMAKE_BUILD_TYPE=RelWithDebInfo
   sudo make install
   jvim --version | head -n 1   # should start with "JVIM v0.x.x"
   ```

2. **Clone and install Jenova**:

   ```sh
   git clone https://github.com/orpheus497/jenova
   cd jenova
   ./install.sh                   # full backend + nvim config
   # …or:
   ./install.sh --client-only     # LAN client only — no llama.cpp build
   ```

3. **Launch through the `jvim` binary**, which when the Jenova environment
   is set up, exports `JENOVA_*` environment variables and starts `jenova-ca`
   on demand:

   ```sh
   jvim somefile.lua
   jvim --check               # dump resolved env and exit
   ```

   If `jvim` detects it is running without the Jenova backend, it operates
   as a standalone editor — Jenova plugins will fall back to LAN scanning.

`./uninstall.sh` in the Jenova repo only removes the Jenova half. The jvim
binary is uninstalled separately from this repository's source tree with
`sudo cmake --build build/ --target uninstall`.

## Gratitude & Inspiration: Native UI Modules

jvim features a **zero-third-party native UI suite**. These modules were built from the ground up to provide a cohesive, high-performance experience that is tightly integrated with the Jenova Cognitive Architecture. 

While these modules are first-party Lua code, their design and functionality were heavily inspired by the incredible work of the Neovim plugin community. We would like to express our deep gratitude to the authors and maintainers of the following projects:

| jvim native module | Inspired by / Built as a tribute to |
|--------------------|--------------------------------------|
| `jvim.finder`      | [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) |
| `jvim.tree`        | [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) |
| `jvim.statusline`  | [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) |
| `jvim.diagnostics_list` | [trouble.nvim](https://github.com/folke/trouble.nvim) |
| `jvim.keyhelp`     | [which-key.nvim](https://github.com/folke/which-key.nvim) |
| `jvim.messages`    | [noice.nvim](https://github.com/folke/noice.nvim) |
| `jvim.notify`      | [nvim-notify](https://github.com/rcarriga/nvim-notify) |
| `jvim.icons`       | [mini.icons](https://github.com/echasnovski/mini.icons) and [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) |
| `jvim.indent_guides` | [indent-blankline.nvim](https://github.com/lukas-reineke/indent-blankline.nvim) |
| `jvim.layout`      | [edgy.nvim](https://github.com/folke/edgy.nvim) |

---

## Current external plugin dependencies

The following plugins are loaded by the Jenova configuration
(`jvim/init.lua` in the [orpheus497/jenova](https://github.com/orpheus497/jenova)
repository) when jvim is launched with the Jenova environment. They are
**not** bundled with jvim itself.

### 1. llama.vim

| Attribute       | Value |
|-----------------|-------|
| **Repository**  | [ggml-org/llama.vim](https://github.com/ggml-org/llama.vim) |
| **Purpose**     | FIM (Fill-in-the-Middle) infill code completions |
| **Endpoint**    | `http://127.0.0.1:8081` (llama-server) |
| **License**     | MIT |
| **API surface** | Vimscript/Lua, uses `vim.fn.jobstart()` / HTTP |

**Compatibility status:** ✅ Fully compatible. Pure Vimscript/Lua plugin that
communicates over HTTP with `llama-server`. No internal API beyond
stable `vim.*` functions.

**Risk:** Low. The plugin depends only on the stable API (`jobstart`,
`nvim_buf_*`, `nvim_win_*`), all of which jvim inherits unchanged.

### 2. gp.nvim

| Attribute       | Value |
|-----------------|-------|
| **Repository**  | [Robitx/gp.nvim](https://github.com/Robitx/gp.nvim) |
| **Purpose**     | Chat completions (RAG-aware proxy) |
| **Endpoint**    | `http://127.0.0.1:8080` (proxy.lua) |
| **License**     | MIT |
| **API surface** | Lua, uses `vim.fn.jobstart()`, `vim.api.*`, floating windows |

**Compatibility status:** ✅ Fully compatible. Uses stable Lua APIs.
The Jenova proxy (`proxy.lua`) presents an OpenAI-compatible API, so `gp.nvim`
sees a standard LLM endpoint.

**Risk:** Medium. `gp.nvim` is a general-purpose ChatGPT plugin. It does not
know about Jenova-specific features (`:JenovaMonitor`, LAN scanning, backend
lifecycle). Future jvim-native replacements can integrate more tightly.

---

## Bundled core dependencies

These are compiled into jvim (or downloaded at build time) and are **not**
external plugins. They are listed here for completeness. Where the build
uses a pinned upstream snapshot rather than a numbered release, the exact
tarball/commit SHA is recorded in `cmake.deps/deps.txt`.

| Dependency           | Version                                     | License  | Purpose |
|----------------------|---------------------------------------------|----------|---------|
| LuaJIT               | pinned snapshot (see `cmake.deps/deps.txt`) | MIT      | JIT Lua runtime |
| Lua                  | 5.1.5                                       | MIT      | Fallback Lua runtime |
| libuv                | 1.52.1                                      | Node.js  | Async I/O event loop |
| Luv                  | 1.52.1-0                                    | Apache-2 | Lua bindings for libuv |
| tree-sitter (core)   | pinned snapshot (see `cmake.deps/deps.txt`) | MIT      | Incremental parsing |
| tree-sitter-c        | 0.24.1                                      | MIT      | C grammar |
| tree-sitter-lua      | 0.5.0                                       | MIT      | Lua grammar |
| tree-sitter-vim      | 0.8.1                                       | MIT      | Vimscript grammar |
| tree-sitter-vimdoc   | 4.1.0                                       | MIT      | Help-file grammar |
| tree-sitter-query    | 0.8.0                                       | MIT      | TS query grammar |
| tree-sitter-markdown | 0.5.3                                       | MIT      | Markdown grammar |
| lpeg                 | 1.1.0                                       | MIT      | Parsing expression grammars |
| lua-compat-5.3       | 0.13                                        | MIT      | Lua 5.3 compat layer |
| utf8proc             | 2.11.3                                      | MIT      | Unicode processing |
| libmpack             | vendored                                    | MIT      | MessagePack (RPC) |
| lua-cjson            | vendored                                    | MIT      | JSON encoding |
| xdiff                | vendored                                    | LGPL-2   | Diff algorithm |
| Klib                 | vendored                                    | MIT/X11  | Generic C data structures |
| unibilium            | 2.1.2                                       | LGPL-3   | Terminal capabilities (deprecated) |

See `cmake.deps/deps.txt` for exact URLs and commit hashes.

---

## Built-in optional plugins

These ship with jvim under `runtime/pack/dist/opt/` and can be loaded
with `:packadd`:

| Plugin           | Purpose |
|------------------|---------|
| cfilter          | Filter quickfix/location lists |
| justify          | Text justification |
| matchit          | Enhanced `%` matching |
| netrw            | File/network browser |
| nohlsearch       | Auto-disable search highlighting |
| nvim.difftool    | Unified diff viewing |
| nvim.tohtml      | HTML export |
| nvim.undotree    | Undo tree visualisation |
| swapmouse        | Swap mouse buttons |
| termdebug        | Terminal debugger interface |

---

## Built-in Lua modules

jvim ships these as part of the runtime (under `runtime/lua/vim/`):

- **vim.lsp** — Full LSP client (completion, diagnostics, codelens, semantic
  tokens, inlay hints, inline completion, etc.)
- **vim.treesitter** — Tree-sitter integration (highlighting, folding,
  incremental selection, query linting)
- **vim.health** — Plugin health checks
- **vim.ui** — UI utilities (input, select)
- **vim.fs** — Filesystem utilities
- **vim.net** — Network utilities
- **vim.filetype** — Filetype detection

No external plugin manager (lazy.nvim, packer.nvim, mason.nvim, etc.) is
required. jvim uses the built-in `vim.pack` / `:packadd` mechanism.

---

## Compatibility analysis

### API compatibility

jvim maintains full API compatibility with the upstream Neovim API. The
following APIs are **identical** to upstream and are guaranteed to work with
existing plugins:

- **Lua API** (`vim.api.*`, `vim.fn.*`, `vim.lsp.*`, `vim.treesitter.*`)
- **Remote API** (msgpack-rpc, used by GUIs and external tools)
- **Vimscript API** (`:command`, autocommands, `has()`, `exists()`)
- **Plugin host** (`:lua`, `rplugin`, provider interfaces)
- **Event loop** (libuv-backed)
- **File formats** (shada, swap, undo, viminfo-compatible)

### What jvim changes

jvim modifies **only** these surface areas:

1. **Version string** — `JVIM v0.x.x` instead of `NVIM v0.x.x`
2. **Binary name** — `jvim` instead of `nvim`
3. **Help documentation** — `intro.txt` and `jvim.txt` carry jvim branding
4. **Issue/bug URLs** — Point to `orpheus497/jvim` instead of
   `neovim/neovim`
5. **Default config directory** — `~/.config/jvim/` instead of `~/.config/nvim/`

This means:

- ✅ Plugins that check `has('nvim')` **will work** (jvim reports both
  `has('nvim')` and `has('jvim')`).
- ✅ Plugins that check `has('nvim-0.x')` **will work** (version APIs are
  unchanged).
- ✅ Plugins using `vim.version()` **will work**.
- ⚠️  Plugins that regex-match the exact string `"NVIM"` in `:version` output
  may not detect jvim. This is rare and easily patched.

### Compatibility with popular plugin managers

| Manager         | Compatible | Notes |
|-----------------|------------|-------|
| lazy.nvim       | ✅ Yes     | Uses `vim.fn`, `vim.api` — fully compatible |
| packer.nvim     | ✅ Yes     | Uses `vim.fn`, `vim.cmd` — fully compatible |
| vim-plug        | ✅ Yes     | Pure Vimscript — fully compatible |
| mini.deps       | ✅ Yes     | Uses `vim.fn`, `vim.api` — fully compatible |

### Compatibility with popular plugins

| Plugin           | Compatible | Notes |
|------------------|------------|-------|
| nvim-lspconfig   | ✅ Yes     | Uses `vim.lsp.*` — fully compatible |
| telescope.nvim   | ✅ Yes     | Uses `vim.api.*` — fully compatible |
| nvim-treesitter  | ✅ Yes     | Uses `vim.treesitter.*` — fully compatible |
| nvim-cmp         | ✅ Yes     | Uses `vim.api.*` — fully compatible |
| mason.nvim       | ✅ Yes     | Uses `vim.fn`, HTTP — fully compatible |
| gitsigns.nvim    | ✅ Yes     | Uses `vim.api.*` — fully compatible |
| which-key.nvim   | ✅ Yes     | Uses `vim.api.*` — fully compatible |
| neo-tree.nvim    | ✅ Yes     | Uses `vim.api.*` — fully compatible |
| lualine.nvim     | ✅ Yes     | Uses `vim.api.*` — fully compatible |

---

## Configuring extra plugins (lazy.nvim)

jvim ships its baseline plugin set as lazy.nvim specs under
`runtime/lua/jvim_plugins/` (treesitter, LSP, mini, gitsigns, llama.vim,
…). The bootstrap in `runtime/lua/jvim_ide.lua` calls
`require("lazy").setup(...)` with **two import roots**:

1. `jvim_plugins` — the shipped baseline (always loaded).
2. `plugins` — your personal `~/.config/jvim/lua/plugins/*.lua` (loaded
   automatically when that directory exists).

Define your own plugins by dropping `*.lua` files into
`~/.config/jvim/lua/plugins/`. Each file should `return` a list of lazy
specs. Your specs are merged on top of the shipped baseline. Because
user specs are imported from `plugins.*` and shipped specs from
`jvim_plugins.*`, matching filenames do **not** override shipped
modules. To customize or override a shipped plugin, redefine the same
lazy spec (that is, the same plugin/repository identity) in your own
returned spec list.

> **Note (rename in 0.13):** the shipped specs were previously located
> under `runtime/lua/plugins/`, which collided with the user
> `lua/plugins/` import root and caused user files to silently shadow the
> shipped specs (breaking the native UI). They now live under
> `jvim_plugins/`, so user filenames no longer shadow shipped modules.
> Out-of-tree forks that mirrored the old path should rename
> accordingly; user configurations require no change.

---

## Roadmap: jvim-native Jenova plugins

Going forward, jvim will develop Jenova integration plugins **directly in
this repository** (under `runtime/`) instead of relying on external
plugins. This provides:

- Tighter integration with the jvim editor core
- Single-repo development, testing, and release cycle
- No dependency on third-party plugin maintenance
- Jenova-aware features not possible with generic plugins

### Planned native replacements

| External plugin  | jvim-native replacement | Status |
|------------------|-------------------------|--------|
| llama.vim        | `runtime/lua/jvim/fim.lua` — FIM completions | Planned |
| gp.nvim          | `runtime/lua/jvim/chat.lua` — Jenova chat interface | Planned |
| *(custom)*       | `runtime/lua/jvim/monitor.lua` — `:JenovaMonitor` | Planned |
| *(custom)*       | `runtime/lua/jvim/lanscan.lua` — `:JenovaLanScan` | Planned |
| *(custom)*       | `runtime/lua/jvim/health.lua` — `:checkhealth jvim` | Planned |

### Migration path

1. External plugins will continue to work during the transition period.
2. jvim-native plugins will be opt-in initially (`:packadd jvim`).
3. Once stable, jvim-native plugins will become the default when running
   under `jvim`.
4. External plugin fallbacks will remain for users who prefer them.

---

## License compatibility

All external dependencies and plugins used by jvim are compatible with the
Apache 2.0 license:

| Component        | License   | Compatible with Apache 2.0? |
|------------------|-----------|-----------------------------|
| Neovim (base)    | Apache-2  | ✅ Yes (same license) |
| Vim (patches)    | Vim       | ✅ Yes (permissive, kept as-is) |
| llama.vim        | MIT       | ✅ Yes |
| gp.nvim          | MIT       | ✅ Yes |
| LuaJIT           | MIT       | ✅ Yes |
| libuv            | Node.js   | ✅ Yes |
| tree-sitter      | MIT       | ✅ Yes |
| xdiff            | LGPL-2    | ✅ Yes (linked, not modified) |
| unibilium        | LGPL-3    | ✅ Yes (linked, not modified) |

The Apache 2.0 license permits forking, modification, and redistribution. jvim
complies with all upstream license requirements by:

- Retaining the full Neovim Apache 2.0 license text in `LICENSE.txt`
- Retaining the Vim license for Vim-originated code
- Listing all third-party dependencies and their licenses
- Adding prominent notices about jvim being a derivative work

<!-- vim: set tw=78: -->
