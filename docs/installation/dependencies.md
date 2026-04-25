# Dependencies

Jenova requires several system-level dependencies for building and running the cognitive backend, the editor, and the agent.

## Required Dependencies

| Dependency | FreeBSD Install | Purpose |
|---|---|---|
| `luajit` (OpenResty) | `pkg install luajit-openresty` | LuaJIT runtime for proxy, embedding, and all backend Lua modules |
| `git` | `pkg install git` | Repository management |
| `cmake` | `pkg install cmake` | Building llama.cpp and the bundled jvim editor from source |
| `gettext` | `pkg install gettext-tools` | Required by the jvim build (msgfmt) |
| `vulkan-loader` | `pkg install vulkan-loader` | GPU inference via Vulkan (dual-GPU offload) |
| `lua54` | `pkg install lua54` | Lua 5.4 runtime |
| `curl` | `pkg install curl` | HTTP client |

> The bundled jvim editor (`jvim/`) is built from source as part of `make`. You no longer need to install `neovim` separately — `make jvim` produces `jvim/build/bin/nvim`, and `bin/jvim` prefers that binary automatically.

## Optional Dependencies

| Dependency | FreeBSD Install | Purpose |
|---|---|---|
| `gmake` | `pkg install gmake` | Building telescope-fzf-native |
| `fetch` | *(FreeBSD base system)* | Web search feature in jvim (`<leader>as`) |
| `clangd` | `pkg install llvm` | C/C++ LSP server (optional) |
| `rust-analyzer` | `pkg install rust-analyzer` | Rust LSP server (optional) |
| `lua-language-server` | `pkg install lua-language-server` | Lua LSP server (optional) |
| `pyright` | `pkg install py311-pyright` | Python LSP server (optional) |
| `zls` | `pkg install zig` | Zig LSP server (optional) |
| `bash-language-server` | `npm install -g bash-language-server` | Bash/Shell LSP server (optional) |
| `stylua` | `cargo install stylua` | Lua code formatter (optional) |
| `goimports` | `go install golang.org/x/tools/cmd/goimports@latest` | Go import formatter (optional) |
