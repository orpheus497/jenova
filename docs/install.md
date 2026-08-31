# Installation

Jenova targets **FreeBSD 15+** (amd64, aarch64). It is the only supported platform.

## Install

```sh
# 1. Clone, with the llama.cpp submodule
git clone --recurse-submodules https://github.com/orpheus497/jenova
cd jenova

# 2. Install dependencies and build llama.cpp (Vulkan), jenova-ui, and the Web UI
make

# 3. Detect hardware, deploy to ~/Jenova, link launchers into ~/.local/bin
make install
```

This is the base system `make(1)`. GNU make is not used and is not a dependency.

If `~/.local/bin` is not on your `PATH`, the installer says so. Add it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Build targets

| Command | Builds |
|---|---|
| `make` | Everything — dependencies, llama.cpp, `jenova-ui`, Web UI |
| `make deps` | Dependencies only (`scripts/install-dependencies.sh`) |
| `make llama` | llama.cpp with the selected backend (`scripts/build-llama.sh`) |
| `make jenova-ui` | The GTK3 tray / ncurses TUI |
| `make web` | The SvelteKit Web UI into `public/` |
| `make install` | Build everything, then `scripts/install.sh` |
| `make clean` | Remove build artifacts |
| `make clean-root` | Remove stray artifacts in the repository root |

Every build target depends on `deps`, and the Makefile is `.NOTPARALLEL` so dependencies are
always in place before anything is compiled.

### Installer flags

`make install` runs `scripts/install.sh`, which accepts:

| Flag | Action |
|---|---|
| `--force` | Overwrite existing configuration without prompting |
| `--skip-llama` | Skip the llama.cpp build check |
| `--skip-web` | Skip building the Web UI |
| `--client-only` | LAN-client install — implies `--skip-llama --skip-web` and skips model downloads; talks to a remote backend |

---

## Dependencies

Everything installs from `pkg(8)`. **There is no optional tier** — a package that cannot be
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
| `pkgconf` | Build-time library discovery. Installed first — the `lua54`, `gtk3`, `libappindicator` and `ncurses` checks all use `pkg-config` |
| `git` | Cloning, and the `external/llama.cpp` submodule |
| `cmake` | `external/llama.cpp`'s build system. Upstream's choice — nothing in this repository is built with cmake directly |
| `sqlite3` | The workspace database — `lib/db.lua` loads it through the FFI at runtime |
| `luajit-openresty` | The intelligence proxy and all Lua runtime |
| `lua54` | Interpreter embedded in `jenova-ui` |
| `gettext-tools` | Build tooling |
| `vulkan-loader` | GPU offload — the default inference backend |
| `shaderc` | Provides `glslc`, the Vulkan shader compiler. No `glslc`, no Vulkan build |
| `spirv-headers` | SPIR-V headers for the shader build |
| `gtk3` | `jenova-ui` system tray |
| `libappindicator` | `jenova-ui` tray icon — `ayatana-appindicator` is accepted instead |
| `ncurses` | `jenova-ui` TUI |
| `node`, `npm` | Building the Web UI, which the proxy serves from `public/` |
| `curl` | HTTPS fallback for web search and health probes |
| `xdg-utils` | Provides `xdg-open`, used by the tray's "Open Web UI" action |
| `llvm` | Provides `clangd` |
| `stylua` | Lua formatter |

### Base system — do not install these

These ship with FreeBSD and are never packages. Anything telling you to install them is wrong:

`make(1)` · `cc(1)` · `realpath(1)` · `fetch(1)` · `sysctl(8)` · `swapinfo(8)` · `pciconf(8)` ·
`nvmecontrol(8)` · `zpool(8)` · `ifconfig(8)` · `route(8)` · `mdmfs(8)` · `nc(1)` · `stat(1)`

`fetch(1)` is tried before `curl` throughout; `curl` is the fallback, not an optional extra.

### Deliberately not used

| Tool | Why |
|---|---|
| **GNU make** (`gmake`) | Both Makefiles build with base `make(1)`. No `$(shell)`, no `ifeq`, no `:=` — library discovery happens in the shell at recipe time |
| **GNU coreutils** | Only ever wanted for `realpath(1)`, which FreeBSD has in base |
| **bash** | Every script in this repository is POSIX `/bin/sh` |

All three are GPL, which this project's dependency policy excludes.

---

## GPU setup

### Vulkan (default)

Vulkan is auto-detected and is what NVIDIA, AMD and Intel hardware all use by default.

For AMD graphics, install the kernel drivers:

```sh
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
# reboot, then verify
vulkaninfo --summary
```

### CUDA (opt-in)

CUDA is **never auto-selected** — the `CUDA/dgpu-generic` profile sets `PROFILE_OPT_IN=1`, which
excludes it from detection. To use it deliberately:

```sh
JENOVA_BACKEND=cuda make llama
./hardware-profiles/detect-hardware.sh --apply-profile CUDA/dgpu-generic
```

`JENOVA_BACKEND` accepts `auto` (default), `vulkan`, `cuda`, `hybrid`, `cpu`.

---

## Hardware profile

`make install` applies a profile automatically. To inspect or change it:

```sh
./hardware-profiles/detect-hardware.sh --info     # detection report, no changes
./hardware-profiles/detect-hardware.sh --list     # list every profile
./hardware-profiles/detect-hardware.sh --apply    # auto-detect and deploy
./hardware-profiles/detect-hardware.sh --apply-profile Vulkan/dgpu-i5-1135g7

sudo scripts/jenova-setup                         # sysctls, swap, ZFS ARC
```

Profiles live at `hardware-profiles/<backend>/<config>/`. See
[../hardware-profiles/README.md](../hardware-profiles/README.md).

### ZFS

On ZFS, cap the ARC so it does not compete with the model for RAM. Add to `/etc/sysctl.conf`:

```
vfs.zfs.arc_max=2147483648
```

Each profile's `jenova-setup` applies this and other tunables for you.

---

## Models

`scripts/install.sh` offers to download the default model set, or run it later:

```sh
scripts/model_dl.sh
```

That fetches Qwen3.5-4B-Q6_K (agent), Qwen3-Embedding-0.6B-Q8_0 (embedding) and
Qwen3.5-0.8B-Q8_0 (drafter) into `~/Jenova/models/`. See [usage.md](usage.md#models) for the
directory layout, discovery rules and overrides.

---

## Running

```sh
jenova-ca --daemon        # start the backend
jenova                    # tray, or TUI if there is no display
```

Then open <http://localhost:8080>.

### LAN access

```sh
jenova-ca --daemon --lan
```

This binds **the proxy** to `0.0.0.0`. The inference and embedding servers stay on loopback —
they are internal backends reached through the proxy.

**Open only port 8080** in your firewall. Never expose 8081 or 8082; they are unauthenticated.

Confirm the bindings:

```sh
sockstat -4l | grep -E '8080|8081|8082'
```

---

## Updating and removing

```sh
scripts/update.sh --all           # pull, rebuild UI and Web UI, re-apply the profile
scripts/update.sh --no-pull       # rebuild without pulling
scripts/update.sh --skip-rebuild  # pull only

scripts/cleanup.sh --all          # clear logs, cache and stale PID files
scripts/cleanup.sh --logs --rotate

scripts/uninstall.sh              # remove deployed files; models are preserved
scripts/uninstall.sh --clean-runtime --clean-builds
```

---

## Notes

- Detection reads `kern.ostype`, not `uname -s`, which answers `Linux` under the Linuxulator.
  Before this was fixed, Jenova misdetected its own developer's FreeBSD machine as Fedora.
- `external/llama.cpp` is a git submodule. If you cloned without `--recurse-submodules`, run
  `git submodule update --init`.
