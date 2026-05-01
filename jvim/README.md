<h1 align="center">
  jvim
  <br>
  <em>Jenova Vim — A terminal-native IDE for the <a href="https://github.com/orpheus497/jenova">Jenova Cognitive Architecture</a></em>
</h1>

<p align="center">
  <a href="./BUILD.md">Build</a> |
  <a href="./INSTALL.md">Install</a> |
  <a href="./CONTRIBUTING.md">Contributing</a> |
  <a href="./PLUGINS.md">Plugins &amp; Compatibility</a> |
  <a href="https://github.com/orpheus497/jenova">Jenova Backend</a> |
  <a href="https://github.com/orpheus497/jenova-cli">Jenova CLI</a>
</p>

> **The Jenova trinity.** Jenova is partitioned across three repositories
> that together form the complete system:
>
> | Repo | Role | Stack |
> |------|------|-------|
> | [`orpheus497/jenova`](https://github.com/orpheus497/jenova) | **Cognitive backend** — `llama-server`, LuaJIT `lib/proxy.lua`, embedding daemon, `jenova-ca` supervisor | C/C++ + LuaJIT |
> | [`orpheus497/jvim`](https://github.com/orpheus497/jvim) *(this repo)* | **Editor / IDE** — terminal-native IDE and AI inference frontend | C + Lua |
> | [`orpheus497/jenova-cli`](https://github.com/orpheus497/jenova-cli) | **Terminal agent** — Standalone CLI for headless inference and automation | Lua 5.4 + Rust + C/C++ |

Overview
--------

**jvim** (Jenova Vim) is a terminal-native IDE and AI inference machine
purpose-built for the
[Jenova Cognitive Architecture](https://github.com/orpheus497/jenova) — a
high-performance, low-latency, FreeBSD-first cognitive engine that turns a
workstation into a persistent, systems-level AI environment.

jvim is designed to be developer-focused, learning-focused, education-focused,
and empowerment-focused for the end user. It features a three-panel structure,
a dashboard, and deep integration with local `llama.cpp` inference — all
optimised for offline capacity and personal productivity.

This repository ships the jvim editor core. The cognitive backend
(`llama-server`, the LuaJIT `lib/proxy.lua` intelligence layer, the embedding
daemon, and the `jenova-ca` process supervisor) lives in the
[orpheus497/jenova](https://github.com/orpheus497/jenova) repository.

> **Naming convention:** *jvim* is the editor (this repository). *Jenova* is
> the cognitive architecture it integrates with
> ([orpheus497/jenova](https://github.com/orpheus497/jenova)).

Relationship to Jenova
----------------------

The [Jenova project](https://github.com/orpheus497/jenova) is partitioned
into four conceptual streams:

- **The Architect** — daemonized process management (`bin/jenova-ca`).
- **The Signal** — non-blocking I/O loop with LuaJIT coroutines (`lib/proxy.lua`).
- **The Mind** — hybrid BM25 + semantic vector retrieval.
- **The Voice** — hardware-aware CLI (`jenova-cli`) and the editor frontend (`jvim`).

The terminal agent side of The Voice lives in
[`orpheus497/jenova-cli`](https://github.com/orpheus497/jenova-cli),
published as **jenova-cli** — a terminal agent that speaks
directly to the backend proxy (`lib/proxy.lua`) on port 8080 and shares the keybinding conventions
defined in the [Jenova backend](https://github.com/orpheus497/jenova) configuration repository so the editor and CLI
stay in lock-step.

**This repository is The Voice's editor frontend.** It is launched directly
as the `jvim` binary. When the Jenova backend is available, the editor
loads the Jenova configuration and wires up:

- `llama.vim` / FIM infill completions against `http://127.0.0.1:8081`
- `gp.nvim` chat completions through the RAG-aware proxy at `http://127.0.0.1:8080`
- `:JenovaMonitor` — real-time backend status and inference metrics
- `:JenovaLanScan` — LAN discovery for remote Jenova CA instances
- Integrated health checks against the embedding daemon on `:8082`

See [`:help jvim`](./runtime/doc/jvim.txt) for the in-editor reference and
[PLUGINS.md](./PLUGINS.md) for a full analysis of external plugin
dependencies and compatibility.

Features
--------

- Terminal-native IDE with three-panel structure and dashboard.
- **Zero-third-party native UI suite** — file explorer, fuzzy finder,
  diagnostics list, statusline, tabline, indent guides, key-help popup,
  notifications, dashboard, layout coordinator and devicons are all
  shipped as first-party Lua modules under `runtime/lua/jvim/*.lua`,
  with no dependency on telescope, nvim-tree, trouble, lualine,
  which-key, noice, edgy, nvim-notify, mini.icons, nvim-web-devicons or
  indent-blankline.
- First-class integration with the
  [Jenova Cognitive Architecture](https://github.com/orpheus497/jenova).
- Local `llama.cpp` inference — offline-capable AI assistance.
- Jenova CLI integration for headless automation.
- Modern terminal UI and rich API access from any language.
- Embedded, scriptable terminal emulator.
- Asynchronous job control and shared data (shada) across instances.
- XDG base directories support.
- Compatible with most Vim and Neovim plugins (see [PLUGINS.md](./PLUGINS.md)).

Install from source
-------------------

See [BUILD.md](./BUILD.md) for the full build matrix. The short version:

```bash
git clone https://github.com/orpheus497/jvim
cd jvim
make CMAKE_BUILD_TYPE=RelWithDebInfo
sudo make install
```

To install to a non-default location:

```bash
make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=/full/path/
make install
```

CMake hints:

- `cmake --build build --target help` lists all build targets.
- `build/CMakeCache.txt` (or `cmake -LAH build/`) contains resolved CMake
  variable values.
- `build/compile_commands.json` shows full compiler invocations per
  translation unit.

On FreeBSD 15 (the primary Jenova target):

```sh
sudo pkg install cmake gmake luajit-openresty git curl wget gettext sha \
  vulkan-loader
gmake CMAKE_BUILD_TYPE=RelWithDebInfo
sudo gmake install
```

Launching
---------

After building and installing, launch jvim directly:

```sh
jvim [files...]
```

For full Jenova cognitive backend integration, set the Jenova environment
variables before launching:

```sh
# Set up Jenova environment (or use the Jenova repo's bin/jvim wrapper)
export JENOVA_ROOT=/path/to/jenova
export JENOVA_CONNECT_HOST=127.0.0.1
export JENOVA_PORT=8080
jvim [files...]
```

When launched with the Jenova environment active, jvim loads the Jenova
configuration and connects to the cognitive backend automatically. Without
the Jenova backend, jvim operates as a standalone terminal IDE — Jenova
plugins will fall back to `:JenovaLanScan` to find a running backend.

Project layout
--------------

    ├─ cmake/           CMake utils
    ├─ cmake.config/    CMake defines
    ├─ cmake.deps/      subproject to fetch and build dependencies (optional)
    ├─ runtime/         plugins and docs (includes runtime/doc/jvim.txt)
    ├─ src/nvim/        application source code (see src/nvim/README.md)
    │  ├─ api/          API subsystem
    │  ├─ eval/         Vimscript subsystem
    │  ├─ event/        event-loop subsystem
    │  ├─ generators/   code generation (pre-compilation)
    │  ├─ lib/          generic data structures
    │  ├─ lua/          Lua subsystem
    │  ├─ msgpack_rpc/  RPC subsystem
    │  ├─ os/           low-level platform code
    │  └─ tui/          built-in UI
    └─ test/            tests (see test/README.md)

Reporting problems
------------------

Issues specific to jvim — branding, Jenova integration, or the
jvim-triggered code paths — should be filed here:

> https://github.com/orpheus497/jvim/issues

License
-------

Copyright © 2025 orpheus497. Licensed under the Apache License, Version 2.0.

jvim is a derivative work of [Neovim](https://neovim.io). Neovim
contributions since [b17d96][license-commit] are licensed under the Apache 2.0
license, except for contributions copied from Vim (identified by the
`vim-patch` token). New jvim-specific contributions are licensed under
Apache 2.0. See [LICENSE.txt](./LICENSE.txt) for full details.

The Jenova Cognitive Architecture proper (the
[orpheus497/jenova](https://github.com/orpheus497/jenova) repository) is
released under AGPL-3.0.

[license-commit]: https://github.com/neovim/neovim/commit/b17d9691a24099c9210289f16afb1a498a89d803

<!-- vim: set tw=80: -->
