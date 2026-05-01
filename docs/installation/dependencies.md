# Dependencies

Jenova requires several system-level dependencies for building and running the cognitive backend, the editor, and the agent.

## Required Dependencies

| Dependency | FreeBSD Install | Purpose |
|------------|-----------------|---------|
| `luajit` (OpenResty) | `pkg install luajit-openresty` | LuaJIT runtime for the intelligence proxy, embedding daemon, agent provider, and all backend Lua modules. |
| `git` | `pkg install git` | Repository / `llama.cpp` checkout management. |
| `cmake` | `pkg install cmake` | Building `llama.cpp` and the bundled jvim editor from source. |
| `gmake` | `pkg install gmake` | **Required on FreeBSD** to build `jvim` and `mcsh` (their build systems are GNU make). |
| `gettext` | `pkg install gettext-tools` | Required by the jvim build (`msgfmt`). |
| `vulkan-loader` | `pkg install vulkan-loader` | GPU inference via Vulkan (single- or dual-GPU offload). |
| `lua54` | `pkg install lua54` | Lua 5.4 runtime (used by jvim plugins). |
| `curl` | `pkg install curl` | HTTP client (RAG / health / web-search fallback). |

> The bundled jvim editor (`jvim/`) and Modern C Shell (`mcsh/`) are both built
> from source as part of `make`. You do **not** need to install `neovim` or
> `tcsh` separately — `make jvim` produces `jvim/build/bin/nvim` (used as
> `bin/jvim`) and `make mcsh` produces `bin/mcsh`.

## Optional Dependencies

| Dependency | FreeBSD Install | Purpose |
|------------|-----------------|---------|
| `dialog` / `whiptail` | `pkg install dialog` | TUI for `scripts/jenova-manager.sh` (only one is needed). |
| `fetch` | *(FreeBSD base)* | Web-search backend for jvim (`<leader>as`). On Linux, `curl` is used. |
| `glslc` / `shaderc` | `pkg install shaderc` | Compile Vulkan shaders for `llama.cpp`. |
| `clangd` | `pkg install llvm` | C / C++ LSP. |
| `rust-analyzer` | `pkg install rust-analyzer` | Rust LSP. |
| `lua-language-server` | `pkg install lua-language-server` | Lua LSP. |
| `pyright` | `pkg install py311-pyright` | Python LSP. |
| `zls` | `pkg install zig` | Zig LSP. |
| `bash-language-server` | `npm install -g bash-language-server` | Bash / shell LSP. |
| `stylua` | `cargo install stylua` | Lua formatter. |
| `goimports` | `go install golang.org/x/tools/cmd/goimports@latest` | Go import formatter. |
