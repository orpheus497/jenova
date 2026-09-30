# Installation

Jenova targets **FreeBSD 15+** (amd64, aarch64) and **Linux — Arch, Debian and Fedora**. The
hardware profiles were measured on FreeBSD and match either OS.

The same source builds on both; the OS is detected when building and when running. Hardware
detection reads `sysctl` and FreeBSD's own tools on FreeBSD, and `/proc` and `/sys` on Linux.

## Install

```sh
# 1. Clone, with the llama.cpp submodule
git clone --recurse-submodules https://github.com/orpheus497/jenova
cd jenova

# 2. Install the dependencies below, then build
nimble llama     # llama-server with Vulkan, into external/ext_bin/bin/
nimble web       # the Web UI, into public/
nimble core      # bin/jenova-core, the headless server
nimble gui       # bin/jenova, the desktop application

# 3. Choose a hardware profile
./bin/jenova-core hardware apply --best
```

Both binaries land in `bin/` and are not installed onto your `PATH`: run `./bin/jenova` for the
desktop application, or `./bin/jenova-core serve` for the headless server. Every `jenova-core`
invocation below is written bare for readability — run it as `./bin/jenova-core` from the
repository root, or put `bin/` on your `PATH`.

### Build targets

| Command | Builds |
|---|---|
| `nimble core` | `bin/jenova-core`, the headless server |
| `nimble gui` | `bin/jenova`, the desktop application |
| `nimble llama` | A static `llama-server` — one file, no shared libraries of its own — into `external/ext_bin/bin/`. Vulkan by default; `JENOVA_BACKEND=cuda` or `JENOVA_BACKEND=cpu` builds the CUDA or the CPU-only backend instead. llama.cpp's own web UI is not downloaded, and its tests are not built |
| `nimble web` | The SvelteKit Web UI into `public/` (runs `npm install`, which fetches from the npm registry) |
| `nimble suites` | Builds both binaries and the Web UI, then runs the 22 `jenova-core <name>-selftest` subcommands, the six `tests/test_*.sh` suites, `tests/gui_check.sh` and `tests/gui_build.sh` (which runs only its build tier when an X display, ImageMagick, `xwininfo`, `xdotool`, `xclip` or `nc` is missing) |
| `nimble clean` | Remove `bin/jenova-core`, `bin/jenova` and `nimcache` |

The tasks are declared in `jenova_core.nimble`; there is no Makefile.

---

## Dependencies

**There is no optional tier** — a missing package stops the build, or the feature named beside it.

Version floors: **Nim 2.2.10** (`jenova_core.nimble`), **GTK 4.10** and **libadwaita 1.4** (the build
passes `-d:gtkminor=10 -d:adwminor=4`). Older stable releases may ship below the toolkit floors —
check with `pkg-config --modversion gtk4 libadwaita-1`.

What the build and the runtime need, by role:

| Need | pkg-config module or command | Why |
|---|---|---|
| Nim compiler and `nimble` | `nim`, `nimble` | Both binaries are Nim; `nimble` runs every build task |
| pkg-config | `pkg-config` | The native libraries below are found with `pkg-config` at compile time, through `src/jenova/pkgconfig.nim`, which stops the compile, names a missing module, and says how to find its package: the FreeBSD port, or the `pacman -F`, `dnf provides` or `apt-file search` that names it |
| HarfBuzz | `harfbuzz` | Maths layout (`src/jenova/mathfont.nim`). **Both binaries** link it — `jenova-core` too, for `math-selftest` |
| zlib | linked as `-lz` | PDF text extraction (`src/jenova/zlib.nim`), both binaries |
| GTK 4, libadwaita | `gtk4`, `libadwaita-1` | The desktop application, through owlkettle |
| GtkSourceView 5 | `gtksourceview-5` | Syntax-highlighted code views (`src/jenova/sourceview.nim`) |
| VTE for GTK 4 | `vte-2.91-gtk4` | The embedded terminal (`src/jenova/vte.nim`) |
| D-Bus | `dbus-1` | The tray item, a `StatusNotifierItem` on the session bus (`src/jenova/tray.nim`, over the binding in `src/jenova/dbus.nim`) |
| FreeType | `freetype2` | The window's maths drawing, by glyph index (`src/jenova/gui.nim`) |
| SQLite | `libsqlite3.so` at run time | The workspace database and the retrieval index. `src/jenova/db.nim` loads it by name when it starts rather than linking it; FTS5 is checked at run time, and without it retrieval skips the keyword index |
| PCRE2 | `libpcre2-8.so.0` at run time | Nim's `std/re`, used by hardware detection; loaded by name, both binaries |
| git | `git` | Cloning and the `external/llama.cpp` submodule, **and at run time**: every workspace is a git repository (`src/jenova/fssync.nim` runs `git init` and `git add`) |
| cmake, a `make` program, a C/C++ compiler | `cmake`, `make`, `cc`/`c++` | `external/llama.cpp`'s build. `nimble llama` runs cmake with its default generator, which needs a `make` program to drive the compile |
| Vulkan loader, `glslc`, SPIR-V headers | `vulkan`, `glslc` | The Vulkan build of llama.cpp and GPU offload |
| Node.js and npm | `node`, `npm` | Building the Web UI into `public/` |
| An HTTPS client | `fetch` or `curl` | Web search. `fetch(1)` is tried first, then `curl`; on Linux that means `curl` |
| `xdg-open` | `xdg-open` | The "Open Web UI" action |
| Neovim | `nvim` | The desktop window's embedded editor page, at run time |
| netcat | `nc` | The test suites only |

`owlkettle` is a Nim dependency, not a package: `nimble` fetches it from the requirement declared
in `jenova_core.nimble`, pinned to one commit.

Only `jenova` needs the GTK 4 group — GTK, libadwaita, GtkSourceView, VTE, D-Bus and FreeType.
`nimble core` builds the headless binary without any of it, which is the point of the two-binary
split; it still needs HarfBuzz and zlib.

### FreeBSD

```sh
pkg install nim nimble pkgconf git cmake sqlite3 pcre2 harfbuzz \
            vulkan-loader shaderc spirv-headers \
            gtk4 libadwaita gtksourceview5 vte3 dbus freetype2 \
            node npm curl xdg-utils neovim
```

**`nimble` is a separate package.** `lang/nim` does not install it — it is `devel/nimble`, and
without it none of the build tasks in `jenova_core.nimble` can be run.

| Package | Port | Needed for |
|---|---|---|
| `nim` | `lang/nim` | The compiler |
| `nimble` | `devel/nimble` | The build system. **Not pulled in by `lang/nim`** |
| `pkgconf` | `devel/pkgconf` | `pkg-config` |
| `git` | `devel/git` | Cloning, the submodule, and every workspace's repository |
| `cmake` | `devel/cmake` | `external/llama.cpp`'s build system |
| `sqlite3` | `databases/sqlite3` | `libsqlite3`, loaded at run time |
| `pcre2` | `devel/pcre2` | `libpcre2-8`, loaded at run time |
| `harfbuzz` | `print/harfbuzz` | Maths layout, both binaries |
| `vulkan-loader` | `graphics/vulkan-loader` | GPU offload — the default inference backend |
| `shaderc` | `graphics/shaderc` | Provides `glslc`, the Vulkan shader compiler. No `glslc`, no Vulkan build |
| `spirv-headers` | `devel/spirv-headers` | SPIR-V headers for the shader build |
| `gtk4` | `x11-toolkits/gtk40` | The desktop application's toolkit, through owlkettle |
| `libadwaita` | `x11-toolkits/libadwaita` | Adwaita widgets used by the window |
| `gtksourceview5` | `x11-toolkits/gtksourceview5` | Syntax-highlighted code views |
| `vte3` | `x11-toolkits/vte3` | The embedded terminal, built against `vte-2.91-gtk4` |
| `dbus` | `devel/dbus` | The tray item |
| `freetype2` | `print/freetype2` | The window's maths drawing |
| `node`, `npm` | `www/node`, `www/npm` | Building the Web UI |
| `curl` | `ftp/curl` | HTTPS fallback for web search; base `fetch(1)` is tried first |
| `xdg-utils` | `devel/xdg-utils` | `xdg-open`, used by the "Open Web UI" action |
| `neovim` | `editors/neovim` | The embedded editor page |

These ship with FreeBSD and are not packages: `sh(1)`, `cc(1)`, `make(1)`, `fetch(1)`,
`sysctl(8)`, `swapinfo(8)`, `nvmecontrol(8)`, `zpool(8)`, `nc(1)`, and `libz`.

### Arch Linux

The package names below are the ones that provide each module on an Arch host; `nim` includes
`nimble`.

```sh
pacman -S --needed nim pkgconf git cmake base-devel sqlite pcre2 harfbuzz zlib \
          vulkan-icd-loader shaderc spirv-headers \
          gtk4 libadwaita gtksourceview5 vte4 dbus freetype2 \
          nodejs npm curl xdg-utils neovim openbsd-netcat
```

Add your GPU's Vulkan driver: `vulkan-intel` or `vulkan-radeon` (Mesa), or `nvidia-utils`.

### Debian and Fedora

Install the development packages that provide the pkg-config modules and commands in the table
above — Debian's `-dev` packages, Fedora's `-devel` ones — plus your GPU's Vulkan driver, `curl`
for web search, and Neovim. Check the GTK and libadwaita versions against the floors first.

### Not needed

| Tool | Why |
|---|---|
| **bash** | Every script the product builds or runs is POSIX `/bin/sh` — the eight scripts under `tests/` (the six `test_*.sh` suites and the GUI harnesses `gui_check.sh` and `gui_build.sh`) and `jca_web/scripts/post-build.sh`. Two Web UI *developer* scripts are `#!/bin/bash` (`jca_web/scripts/dev.sh`, which `npm run dev` runs, and `install-git-hooks.sh`), as are some vendored Neovim plugin scripts under `jvim/pack/`; none is needed to build or run Jenova |
| **GNU coreutils** | Nothing calls `realpath(1)` or `stat(1)` |

---

## GPU setup

### Vulkan (default)

Vulkan is what `nimble llama` builds, and what NVIDIA, AMD and Intel hardware all use by default.

For AMD graphics on FreeBSD, install the kernel drivers:

```sh
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
# reboot, then verify
vulkaninfo --summary
```

On Linux the kernel drivers ship with the distribution; install the Vulkan driver named above.

`llama-server --list-devices` shows how the driver numbered the GPUs, and the order differs between
systems: FreeBSD numbers the i5-1135G7 laptop's GTX 1650 Ti `Vulkan0`, Linux its Iris Xe. So the
profiles name their GPUs — `DEVICES="NVIDIA,Intel.*(Iris|Xe)"` — and when Jenova starts the backend it gives
each name the number of the first device whose name matches it. `jenova-core backends args` shows
the result.

### CUDA (opt-in)

CUDA is **never auto-selected** — the `CUDA/dgpu-generic` profile sets `PROFILE_OPT_IN=1`, which
excludes it from detection. To use it deliberately:

```sh
jenova-core hardware apply CUDA/dgpu-generic
```

and build the backend with CUDA (`-DGGML_CUDA=ON`), which needs the CUDA toolkit:

```sh
JENOVA_BACKEND=cuda nimble llama
```

---

## Hardware profile

```sh
jenova-core hardware detect     # detection report, no changes
jenova-core hardware list     # list every profile
jenova-core hardware apply --best    # score the profiles and deploy the winner
jenova-core hardware apply Vulkan/dgpu-i5-1135g7   # deploy one by name
```

The same screen is in the desktop application under the Hardware button; the subcommand exists
for headless hosts.

`apply` copies the profile's `jenova.conf` whole over `$JCA_HOME/etc/jenova.conf`, and
`src/jenova/config.nim` then reads `$JCA_HOME/etc/` instead of the repository's `etc/` — both files:
from then on your overrides belong in `$JCA_HOME/etc/jenova.local.conf`, and the repository's
`etc/jenova.local.conf` no longer applies. `apply` never touches a `jenova.local.conf`.

**Jenova applies no kernel tuning.** It reads `sysctl` (FreeBSD) or `/proc` (Linux) to detect
the machine and sets nothing. Anything under [ZFS](#zfs) below is yours to apply if you want it.

Profiles live at `hardware-profiles/<backend>/<config>/`. See
[../hardware-profiles/README.md](../hardware-profiles/README.md).

### ZFS

On FreeBSD with ZFS, cap the ARC so it does not compete with the model for RAM. Add to
`/etc/sysctl.conf`:

```
vfs.zfs.arc_max=2147483648
```

Apply it yourself — Jenova does not set kernel tunables.

---

## Models

Put `.gguf` files under `~/Jenova/models/` — `agent/`, `draft/` and `embed/`. Five of the six
profiles' `profile.conf` name the models they were sized against under `RECOMMENDED_AGENT_MODEL` and
`RECOMMENDED_EMBED_MODEL`, with download URLs in `RECOMMENDED_AGENT_URL` and
`RECOMMENDED_EMBED_URL`; `Vulkan/dgpu-igpu-i5-1135g7` names none.

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
Port 8080 relays embedding requests (`/embed*`, `/v1/embeddings`) to 8082, so under `--lan` those
are reachable too, unauthenticated.

Confirm the bindings:

```sh
sockstat -4l | grep -E '8080|8081|8082'    # FreeBSD
ss -ltn | grep -E '8080|8081|8082'         # Linux
```

---

## Updating

```sh
git pull
git submodule update --init
nimble llama      # only when external/llama.cpp moved
nimble web
nimble core
nimble gui
jenova-core hardware apply <your profile>   # or --best
```

Re-applying the profile is what carries changes to it into `$JCA_HOME/etc/jenova.conf`, which it
replaces whole; your `jenova.local.conf` is kept.

---

## Notes

- Detection reports the OS the binary was built for — `FreeBSD` or `Linux` — and the release of the
  running kernel (`kern.osrelease`, or `/proc/sys/kernel/osrelease`).
- `external/llama.cpp` is a git submodule. If you cloned without `--recurse-submodules`, run
  `git submodule update --init`.
