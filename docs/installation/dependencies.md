# Dependencies

Jenova requires several system-level dependencies for building and running the cognitive backend, the editor, and the agent.

## Required Dependencies

| Dependency | FreeBSD (`pkg`) | Linux (Arch `pacman`) | Linux (Debian `apt`) | Linux (Fedora `dnf`) | macOS (`brew`) |
|------------|-----------------|-----------------------|----------------------|----------------------|----------------|
| `luajit` | `luajit-openresty` | `luajit` | `luajit` | `luajit` | `luajit` |
| `git` | `git` | `git` | `git` | `git` | `git` |
| `cmake` | `cmake` | `cmake` | `cmake` | `cmake` | `cmake` |
| `gmake` | `gmake` | `make` | `make` | `make` | `make` |
| `gettext` | `gettext-tools` | `gettext` | `gettext` | `gettext` | `gettext` |
| `vulkan` | `vulkan-loader` | `vulkan-icd-loader` | `libvulkan1` | `vulkan-loader` | `molten-vk` |
| `lua54` | `lua54` | `lua54` | `liblua5.4-dev` | `lua-devel` | `lua@5.4` |
| `curl` | `curl` | `curl` | `libcurl4-openssl-dev` | `libcurl-devel` | `curl` |

> The bundled jenova-ui editor (`jenova-ui/`) is built from source as part of `make`.
> `jenova-ui/build/bin/nvim` (used as `bin/jenova-ui`).

## Optional Dependencies

| Dependency | Purpose | FreeBSD (`pkg`) | Linux (Arch) | Linux (Debian) | Linux (Fedora) | macOS (`brew`) |
|------------|---------|-----------------|--------------|----------------|----------------|----------------|
| `glslc` | Vulkan shader compiler | `shaderc` | `shaderc` | `glslc` | `glslc` | `shaderc` |
| `clangd` | C / C++ LSP | `llvm` | `clang` | `clangd` | `clang-tools-extra` | `llvm` |
| `stylua` | Lua formatter | `stylua` | `stylua` | `cargo install stylua` | `cargo install stylua` | `stylua` |
| `node` | Web UI build tooling (optional) | `node` | `nodejs` | `nodejs npm` | `nodejs` | `node` |

> The bundled jenova-ui editor (`jenova-ui/`) is built from source as part of `make`.
> `jenova-ui/build/bin/nvim` (used as `bin/jenova-ui`).
>
> `node` / `npm` is optional and only required for the Web UI build via
> `make web` or `./scripts/install-complete.sh` if the frontend is enabled.
