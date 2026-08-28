# Dependencies

Jenova targets FreeBSD 15+. Everything installs from `pkg(8)`.

**There is no optional tier.** Every package below is required. `make` runs
`scripts/install-dependencies.sh` before any build target, and a package that cannot be
installed stops the build.

```sh
make deps
```

Or install them yourself:

```sh
pkg install pkgconf git cmake sqlite3 luajit-openresty lua54 gettext-tools \
            vulkan-loader shaderc spirv-headers gtk3 libappindicator ncurses \
            node npm curl xdg-utils llvm stylua
```

| Package | Needed for |
|---|---|
| `pkgconf` | Build-time library discovery. Installed first — the checks for `lua54`, `gtk3`, `libappindicator` and `ncurses` all use `pkg-config` |
| `git` | Cloning, and the `external/llama.cpp` submodule |
| `cmake` | **`external/llama.cpp`'s** build system. Upstream's choice — nothing in this repository is built with cmake directly |
| `sqlite3` | Workspace database — `lib/db.lua` loads it through the FFI at runtime |
| `luajit-openresty` | The intelligence proxy and all Lua runtime |
| `lua54` | Interpreter embedded in `jenova-ui` |
| `gettext-tools` | Build tooling |
| `vulkan-loader` | GPU offload — the default inference backend |
| `shaderc` | Provides `glslc`, the Vulkan shader compiler. No glslc, no Vulkan build |
| `spirv-headers` | SPIR-V headers for the shader build |
| `gtk3` | `jenova-ui` system tray |
| `libappindicator` | `jenova-ui` tray icon — `ayatana-appindicator` is accepted instead |
| `ncurses` | `jenova-ui` TUI |
| `node`, `npm` | Building the Web UI, which the proxy serves from `public/` |
| `curl` | HTTPS client for the web-search and health-probe fallbacks |
| `xdg-utils` | Provides `xdg-open`, used by the tray's "Open Web UI" action |
| `llvm` | Provides `clangd` |
| `stylua` | Lua formatter |

## GPU drivers

For AMD graphics:

```sh
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
# reboot, then confirm
vulkaninfo --summary
```

## Base system — do not install these

These are part of FreeBSD and are never packages. Anything telling you to install them is
wrong:

`make(1)` · `cc(1)` · `realpath(1)` · `fetch(1)` · `sysctl(8)` · `swapinfo(8)` · `pciconf(8)` ·
`nvmecontrol(8)` · `zpool(8)` · `ifconfig(8)` · `route(8)` · `mdmfs(8)` · `nc(1)` · `stat(1)`

## Not required

Three GPL tools that a Linux-derived setup would pull in, and that Jenova deliberately does
not use:

| Tool | Why it is not needed |
|---|---|
| **GNU make** (`gmake`) | Both Makefiles build with the base system `make(1)`. No GNU-only syntax — no `$(shell)`, no `ifeq`, no `:=`. Library discovery happens in the shell at recipe time |
| **GNU coreutils** | Only ever wanted for `realpath(1)`, which FreeBSD has in base |
| **bash** | Every script in this repository is POSIX `/bin/sh` |

All three are GPL, which this project's dependency policy excludes.

## CUDA

CUDA is opt-in and never auto-detected. NVIDIA hardware runs through Vulkan by default. If you
have a CUDA toolchain and want to use it:

```sh
JENOVA_BACKEND=cuda make llama
./hardware-profiles/detect-hardware.sh --apply-profile CUDA/dgpu-generic
```
