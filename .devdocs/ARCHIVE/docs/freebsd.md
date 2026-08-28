# Installation

Jenova targets **FreeBSD 15+**. It is the only supported platform.

## Quick Install

```sh
# 1. Clone, with the llama.cpp submodule
git clone --recurse-submodules https://github.com/orpheus497/jenova
cd jenova

# 2. Build everything. `make` installs every dependency first, then builds
#    llama.cpp (Vulkan), jenova-ui, and the Web UI.
make

# 3. Hardware-aware install: deploys to ~/JCA and symlinks into ~/.local/bin
make install
```

That is the base system `make(1)`. GNU make is not used and is not a dependency.

**Dependencies install themselves.** Every build target depends on `make deps`, which runs
`scripts/install-dependencies.sh`. There is no optional tier: if a package cannot be installed,
the build stops. To install dependencies without building:

```sh
make deps
```

The full list is in [`dependencies.md`](dependencies.md).

## Building components individually

| Command | Builds |
|---|---|
| `make deps` | Install every dependency (`scripts/install-dependencies.sh`) |
| `make llama` | llama.cpp with the auto-detected backend (`scripts/build-llama.sh`) |
| `make jenova-ui` | The GTK3 tray / ncurses TUI |
| `make web` | The SvelteKit Web UI into `public/` |
| `make verify` | Verify a deployed installation |
| `make clean` | Remove build artifacts |
| `make clean-root` | Remove leftover artifacts in the repository root |

Each build target depends on `deps`, so dependencies are always in place first.

### GPU backends

Vulkan is the default and is auto-detected. **CUDA is opt-in** and is never selected
automatically — NVIDIA hardware runs through Vulkan by default:

```sh
JENOVA_BACKEND=cuda make llama
```

`JENOVA_BACKEND` accepts `auto` (default), `vulkan`, `cuda`, `hybrid`, `cpu`.

## Installer flags

`scripts/install.sh` accepts:

| Flag | Action |
|---|---|
| `--force` | Overwrite existing config and symlinks without prompting |
| `--skip-llama` | Skip the llama.cpp build check |
| `--skip-web` | Skip building the Web UI |
| `--client-only` | LAN-client install — implies `--skip-llama --skip-web`; talks to a remote backend |

## Hardware profile

After installing, deploy a hardware profile:

```sh
# Detection report
./hardware-profiles/detect-hardware.sh --info

# Apply the matched profile
./hardware-profiles/detect-hardware.sh --apply

# System tuning (sysctls, ZFS ARC, swap)
sudo scripts/jenova-setup
```

Profiles live under `hardware-profiles/<backend>/<config>/`. See
[`../../hardware-profiles/README.md`](../../hardware-profiles/README.md).

## AMD GPU requirements

For an AMD APU or discrete card, install the kernel drivers:

```sh
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
# reboot, then verify
vulkaninfo --summary
```

## ZFS tuning

On ZFS, cap the ARC so it does not compete with the model for RAM. Add to `/etc/sysctl.conf`:

```
vfs.zfs.arc_max=2147483648
```

The per-profile `jenova-setup` scripts apply this and other tunables for you.

## Running

```sh
jenova-ca --daemon        # start the backend
jenova-tui                # operational TUI
```

Then open <http://localhost:8080>.

### LAN access

```sh
jenova-ca --daemon --lan
```

This binds **the proxy** to `0.0.0.0`. The inference and embedding servers stay on loopback —
they are internal backends reached through the proxy.

**Open only port 8080** in your firewall. Never expose 8081 or 8082; they are unauthenticated.

## Notes

- **bash is not required.** Every script here is POSIX `/bin/sh`.
- **Do not install GNU coreutils for `realpath`** — FreeBSD has it in base.
- `fetch(1)` from the base system is tried before `curl` throughout. `curl` is still installed
  and used as a fallback — it is not an optional package.
- Detection reads `kern.ostype`, not `uname -s`, which reports `Linux` under the Linuxulator.
