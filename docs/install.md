# Installation

Jenova targets **FreeBSD 15+** (amd64, aarch64). It is the only supported platform.

## Install

```sh
# 1. Clone, with the llama.cpp submodule
git clone --recurse-submodules https://github.com/orpheus497/jenova
cd jenova

# 2. Install the dependencies below, then build
nimble llama     # llama.cpp with Vulkan, into external/ext_bin/
nimble web       # the Web UI, into public/
nimble gui       # bin/jenova, the desktop application

# 3. Detect hardware and deploy the matching profile
./bin/jenova-core hardware apply --best
```

The binaries land in `bin/` and are not installed onto your `PATH`. Every `jenova-core` invocation
below is written bare for readability — run it as `./bin/jenova-core` from the repository root, or
put `bin/` on your `PATH`.

Both binaries land in `bin/`. Run `./bin/jenova` for the desktop application, or
`./bin/jenova-core serve` for the headless server.

### Build targets

| Command | Builds |
|---|---|
| `nimble core` | `bin/jenova-core`, the headless server |
| `nimble gui` | `bin/jenova`, the desktop application |
| `nimble llama` | llama.cpp with Vulkan, into `external/ext_bin/` |
| `nimble web` | The SvelteKit Web UI into `public/` |
| `nimble suites` | Build both binaries, then run every suite under `tests/` |
| `nimble clean` | Remove the binaries and `nimcache` |

The tasks are declared in `jenova_core.nimble`; there is no Makefile.

---

## Dependencies

Everything installs from `pkg(8)`. **There is no optional tier** — a package that cannot be
installed stops the build.

```sh
pkg install nim nimble pkgconf git cmake sqlite3 \
            vulkan-loader shaderc spirv-headers \
            gtk4 libadwaita gtksourceview5 vte3 dbus \
            node npm curl xdg-utils
```

**`nimble` is a separate package.** `lang/nim` does not install it — it is `devel/nimble`, and
without it none of the build tasks in `jenova_core.nimble` can be run.

| Package | Port | Needed for |
|---|---|---|
| `nim` | `lang/nim` | The compiler. Both binaries are Nim |
| `nimble` | `devel/nimble` | The build system. **Not pulled in by `lang/nim`** |
| `pkgconf` | `devel/pkgconf` | Build-time library discovery — the GTK4, GtkSourceView, VTE and D-Bus flags are all resolved with `pkg-config` at compile time |
| `git` | `devel/git` | Cloning, and the `external/llama.cpp` submodule |
| `cmake` | `devel/cmake` | `external/llama.cpp`'s build system. Upstream's choice — nothing in this repository is built with cmake directly |
| `sqlite3` | `databases/sqlite3` | The workspace database and the retrieval index. `src/jenova/db.nim` links `libsqlite3`; FTS5 is checked at runtime and retrieval degrades if absent |
| `vulkan-loader` | `graphics/vulkan-loader` | GPU offload — the default inference backend |
| `shaderc` | `graphics/shaderc` | Provides `glslc`, the Vulkan shader compiler. No `glslc`, no Vulkan build |
| `spirv-headers` | `devel/spirv-headers` | SPIR-V headers for the shader build |
| `gtk4` | `x11-toolkits/gtk40` | The desktop application's toolkit, through owlkettle |
| `libadwaita` | `x11-toolkits/libadwaita` | Adwaita widgets used by the window |
| `gtksourceview5` | `x11-toolkits/gtksourceview5` | Syntax-highlighted code views (`src/jenova/sourceview.nim`) |
| `vte3` | `x11-toolkits/vte3` | The embedded terminal widget (`src/jenova/vte.nim`), built against `vte-2.91-gtk4` |
| `dbus` | `devel/dbus` | The tray item is a `StatusNotifierItem` published on the session bus (`src/jenova/dbus.nim`) |
| `node`, `npm` | `www/node`, `www/npm` | Building the Web UI into `public/` |
| `curl` | `ftp/curl` | HTTPS fallback for web search; base `fetch(1)` is tried first |
| `xdg-utils` | `devel/xdg-utils` | Provides `xdg-open`, used by the "Open Web UI" action |

`owlkettle` is a Nim dependency, not a package: `nimble` fetches it from the requirement declared
in `jenova_core.nimble`.

Only `jenova` needs the GTK4 group. `nimble core` builds the headless binary without any of it,
which is the point of the two-binary split.

### Base system — do not install these

These ship with FreeBSD and are never packages. Anything telling you to install them is wrong:

`sh(1)` · `cc(1)` · `realpath(1)` · `fetch(1)` · `sysctl(8)` · `swapinfo(8)` · `pciconf(8)` ·
`nvmecontrol(8)` · `zpool(8)` · `ifconfig(8)` · `route(8)` · `mdmfs(8)` · `nc(1)` · `stat(1)`

`fetch(1)` is tried before `curl` throughout; `curl` is the fallback, not an optional extra.

### Deliberately not used

| Tool | Why |
|---|---|
| **GNU make** (`gmake`) and base `make(1)` | There is no Makefile. `nimble` is the build system |
| **GNU coreutils** | Only ever wanted for `realpath(1)`, which FreeBSD has in base |
| **bash** | Every script the product builds or runs is POSIX `/bin/sh` — the six suites under `tests/` and `jca_web/scripts/post-build.sh`. Two Web UI *developer* scripts are `#!/bin/bash` (`jca_web/scripts/dev.sh`, `install-git-hooks.sh`); neither is needed to build or run Jenova |

The first and third are GPL, which this project's dependency policy excludes.

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
jenova-core hardware apply CUDA/dgpu-generic
```

The `nimble llama` task builds with `-DGGML_VULKAN=ON`. For CUDA, configure
`external/llama.cpp` yourself with the CUDA backend and copy the result into
`external/ext_bin/bin/`, then apply the profile above.

---

## Hardware profile

```sh
jenova-core hardware detect     # detection report, no changes
jenova-core hardware list     # list every profile
jenova-core hardware apply --best    # auto-detect and deploy
jenova-core hardware apply Vulkan/dgpu-i5-1135g7
```

The same screen is in the desktop application under the Hardware button, which is the
intended way to do it — the subcommand exists for headless hosts.

`apply` writes `$JCA_HOME/etc/jenova.conf`, and `src/jenova/config.nim` prefers that copy over
the one in the source tree. It never touches your `jenova.local.conf`.

**Jenova applies no kernel tuning.** It reads `sysctl` values to detect the machine and
sets none. Anything under [ZFS](#zfs) below is yours to apply if you want it.

Profiles live at `hardware-profiles/<backend>/<config>/`. See
[../hardware-profiles/README.md](../hardware-profiles/README.md).

### ZFS

On ZFS, cap the ARC so it does not compete with the model for RAM. Add to `/etc/sysctl.conf`:

```
vfs.zfs.arc_max=2147483648
```

Apply it yourself — Jenova does not set kernel tunables.

---

## Models

Put `.gguf` files under `~/Jenova/models/` — `agent/`, `draft/` and `embed/`. Each profile's
`profile.conf` names the model it was sized against under `RECOMMENDED_AGENT_MODEL` and
`RECOMMENDED_EMBED_MODEL`, with the URL to fetch it from.

`jenova-core models list` prints what discovery resolved. See [usage.md](usage.md#models) for the
directory layout, discovery rules and overrides.

---

## Running

```sh
./bin/jenova                  # the desktop application, which is also the server
./bin/jenova-core serve       # headless: the same server without the window
```

Then open <http://localhost:8080>, or use the window.

### LAN access

```sh
./bin/jenova-core serve --lan
```

This binds **the client-facing port** to `0.0.0.0`. The inference and embedding servers stay on
loopback — they are internal backends reached through it.

**Open only port 8080** in your firewall. Never expose 8081 or 8082; they are unauthenticated.

Confirm the bindings:

```sh
sockstat -4l | grep -E '8080|8081|8082'
```

---

## Updating

```sh
git pull
git submodule update --init
nimble llama      # only when external/llama.cpp moved
nimble web
nimble gui
jenova-core hardware apply --best
```

---

## Notes

- Detection reads `kern.ostype`, not `uname -s`, which answers `Linux` under the Linuxulator.
  Before this was fixed, Jenova misdetected its own developer's FreeBSD machine as Fedora.
- Both binaries carry a `when not defined(freebsd)` guard, so a build on another platform fails at
  compile time rather than at run time.
- `external/llama.cpp` is a git submodule. If you cloned without `--recurse-submodules`, run
  `git submodule update --init`.
