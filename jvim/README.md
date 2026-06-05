<h1 align="center">
  jvim
  <br>
  <em>Jenova Vim — The integrated editor frontend for the <a href="https://github.com/orpheus497/jenova">Jenova Cognitive Architecture</a></em>
</h1>

<p align="center">
  <a href="./BUILD.md">Build</a> |
  <a href="./INSTALL.md">Install</a> |
  <a href="./CONTRIBUTING.md">Contributing</a> |
  <a href="./PLUGINS.md">Plugins &amp; Compatibility</a> |
  <a href="https://github.com/orpheus497/jenova">Jenova Monorepo</a>
</p>

Overview
--------

**jvim** (Jenova Vim) is a terminal-native IDE and AI inference machine
purpose-built for the
[Jenova Cognitive Architecture](https://github.com/orpheus497/jenova) — a
high-performance, local-first cognitive engine that turns a workstation into a
persistent, systems-level AI environment.

jvim is designed to be developer-focused, learning-focused, and
empowerment-focused. It features a three-panel structure, a dashboard, and
deep integration with local `llama.cpp` inference — all optimised for offline
capacity and personal productivity.

As the primary interactive interface of Jenova, jvim hosts the **Unified Agent**
and provides a unified UI for inference monitoring, health checks, and
RAG-aware chat.

> **Unified Monorepo:** *jvim* is built and distributed as part of the
> [Jenova](https://github.com/orpheus497/jenova) project. Use the root
> `Makefile` to build the entire stack.

Features
--------

- **Unified Agent** — An autonomous coding partner embedded directly in the
  editor, with native access to buffers, LSP servers, and the shell.
- **Zero-third-party native UI suite** — File explorer, fuzzy finder,
  diagnostics list, statusline, tabline, indent guides, key-help popup,
  notifications, dashboard, and layout coordinator are all shipped as
  first-party Lua modules.
- **Local Inference** — Deep integration with `llama.cpp` for non-cloud AI
  assistance.
- **Backend Monitoring** — Real-time tracking of inference metrics (TPS,
  context usage, GPU offload).
- **Embedded Terminal** — Scriptable terminal emulator using the system shell
  (or any shell set via `$SHELL`).

Install from source
-------------------

jvim is built as part of the Jenova unified build system.

```bash
# From the Jenova root directory
make jvim       # build only jvim
make            # build everything (llama.cpp + jvim)
make install    # deploy to ~/.local/bin
```

Launching
---------

After building and installing, launch jvim via the top-level launcher:

```sh
jenova [files...]
```

When launched via `jenova`, the backend daemons are started automatically
on demand. Without the Jenova backend, jvim operates as a standalone
terminal IDE.

Project layout
--------------

    ├─ cmake/           CMake utils
    ├─ cmake.config/    CMake defines
    ├─ cmake.deps/      subproject to fetch and build dependencies (optional)
    ├─ runtime/         plugins and docs (includes runtime/doc/jvim.txt)
    ├─ src/nvim/        application source code (see src/nvim/README.md)
    └─ test/            tests (see test/README.md)

License
-------

jvim is a derivative work of [Neovim](https://neovim.io). Neovim
contributions since [b17d96][license-commit] are licensed under the Apache 2.0
license. New jvim-specific contributions are also licensed under Apache 2.0.
See [LICENSE.txt](./LICENSE.txt) for full details.

The Jenova Cognitive Architecture proper (the backend) is released under AGPL-3.0.

[license-commit]: https://github.com/neovim/neovim/commit/b17d9691a24099c9210289f16afb1a498a89d803

<!-- vim: set tw=80: -->
