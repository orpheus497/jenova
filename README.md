# Jenova Cognitive Architecture

<img src="png/splash_top.png" width="100%" alt="Jenova Cognitive Architecture banner">

Jenova is a personal AI system that runs entirely on your own FreeBSD machine. No cloud account,
no subscription, no telemetry. Inference, retrieval, and your workspace all live on your hardware.

It is built for the person who wants an assistant that works *with* them — one that keeps context
across long sessions, surfaces connections, and helps articulate what you already know. The work
and the judgment stay yours.

---

## Quick Start

```sh
git clone --recurse-submodules https://github.com/orpheus497/jenova
cd jenova

make             # install every dependency, then build everything
make install     # deploy to ~/Jenova and link launchers into ~/.local/bin
jenova-ca --daemon
```

Then open <http://localhost:8080>.

`make` is the FreeBSD base system `make(1)`. GNU make, GNU coreutils and bash are not used and
are not dependencies — every script here is POSIX `/bin/sh`.

Dependencies install themselves: every build target runs `scripts/install-dependencies.sh` first,
and a package that cannot be installed stops the build. There is no optional tier.

Individual targets: `make deps`, `make llama`, `make jenova-ui`, `make web`, `make core`.

---

## What Runs

`jenova-ca` supervises three daemons as a single unit.

| Port | Service | Bind | Purpose |
|---|---|---|---|
| **8080** | Intelligence proxy | `127.0.0.1`, or `0.0.0.0` under `--lan` | The only client-facing port. Serves the Web UI, the workspace database API, retrieval, web search, and forwards inference |
| 8081 | `llama-server` | loopback always | OpenAI-compatible inference |
| 8082 | `llama-server` (embedding mode) | loopback always | Embeddings for semantic search |

**`:8080` is the only port to open in a firewall.** 8081 and 8082 bind loopback unconditionally —
including under `--lan` — because nothing outside the host addresses them. They are
unauthenticated; exposing them would publish open inference endpoints.

### Web UI

A SvelteKit static SPA served by the proxy at `:8080`. Persistent workspaces, branching
conversation history, token streaming with TPS/TTFT metrics, `<think>` reasoning blocks, GFM
markdown, KaTeX math, syntax highlighting, in-browser PDF viewing, and MCP client support.

Workspaces, projects, folders, conversations, messages and notes are stored in SQLite at
`~/Jenova/var/jenova.db`, managed by the proxy. Notes and chats are additionally mirrored to
`~/Jenova/Workspaces` as plain Markdown, readable and editable with any text editor.

### Desktop Manager

`jenova-ui` is a native C application offering two interfaces over the same code:

- **System tray** (GTK3 + appindicator) — health polling and server control from a context menu.
- **ncurses TUI** (`jenova-tui`, or `jenova-ui tui`) — the same control surface without a
  graphical environment, for headless and terminal-centric use.

`jenova` picks the tray when a display is available and is not an SSH session, and falls back to
the TUI otherwise.

### LAN mode

`jenova-ca --daemon --lan` moves the proxy to `0.0.0.0`, making your workspace reachable from a
phone, tablet or second machine at `http://<host-ip>:8080`. The tray and TUI can toggle this.

---

## Commands

`make install` links these into `~/.local/bin`:

| Command | Description |
|---|---|
| `jenova` | Start the tray, or the TUI if there is no display |
| `jenova-ca` | Backend supervisor — see [docs/usage.md](docs/usage.md) |
| `jenova-tui` | ncurses manager (`jenova-ui tui`) |
| `jenova-ui` | Desktop Manager binary |
| `jenova-swap-mount` | Mount an NVMe/Optane-backed swap filesystem for model storage |
| `jenova-model-switch` | Swap the active agent model to `instruct` or `thinking` |

`bin/jenova-term` is an internal helper that finds a terminal emulator; it is not linked onto
your `PATH`.

Updating:

```sh
./scripts/update.sh --all      # pull, rebuild UI and Web UI, re-apply the hardware profile
```

---

## Hardware

Jenova targets consumer and prosumer laptops. Detection runs at install time and deploys a
matching profile that sets GPU offload, context size, batch sizes and thread counts.

| Profile | Devices | Layers | Context | Drafter |
|---|---|---|---|---|
| `Vulkan/dgpu-i5-1135g7` | `Vulkan0` | all | 16K | yes |
| `Vulkan/dgpu-igpu-i5-1135g7` | `Vulkan0,Vulkan1` | all | 32K | no |
| `Vulkan/apu-ryzen7-5700u` | `Vulkan0` | 24 | 16K | yes |
| `Vulkan/dgpu-generic-12gb` | `Vulkan0` | all | 32K | yes |
| `CPU/generic` | `CPU` | 0 | 16K | no |
| `CUDA/dgpu-generic` | `CUDA0` | all | 16K | yes |

**Profiles do not choose your model.** `lib/jenova-model.sh` discovers whatever `.gguf` files are
in `~/Jenova/models/`, and `scripts/model_dl.sh` downloads the same default set on every profile:
Qwen3.5-4B-Q6_K (agent), Qwen3-Embedding-0.6B-Q8_0 (embedding), Qwen3.5-0.8B-Q8_0 (drafter).
Point `JENOVA_MODEL` at anything else you like.

Rough VRAM guide: about **0.75 GB per 1B parameters** at Q4_K_M.

Full detail — scoring, the priority ladder, every setting, and how to add a profile — is in
[hardware-profiles/README.md](hardware-profiles/README.md).

---

## Platform Support

**Jenova is a FreeBSD program**, not a portable program that runs on FreeBSD. The source contains
no other platform: one kernel ABI, one package manager, one hardware-profile tree.

| | |
|---|---|
| **Target** | FreeBSD 15+ (amd64, aarch64) |
| **Storage** | ZFS or UFS; ZFS ARC tuning shipped per profile |
| **GPU** | Vulkan by default. CUDA is opt-in and never auto-selected |
| **Swap** | Swap-backed model store via `mdmfs`, tuned for NVMe/Optane |
| **Not supported** | Linux, macOS, Windows |

`lib/detect-env.sh` identifies the kernel through `kern.ostype` and refuses to run on anything
else. It does not use `uname -s`, which answers `Linux` under the FreeBSD Linuxulator.

---

## Documentation

| Topic | Path |
|---|---|
| Installation and dependencies | [docs/install.md](docs/install.md) |
| Commands, models, HTTP API | [docs/usage.md](docs/usage.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
| How content reaches the model | [docs/context-and-retrieval.md](docs/context-and-retrieval.md) |
| Hardware profiles | [hardware-profiles/README.md](hardware-profiles/README.md) |
| Privacy | [docs/privacy.md](docs/privacy.md) |
| Web UI development | [jca_web/README.md](jca_web/README.md) |

---

## Repository Layout

```
jenova/
├── bin/                # Launchers and tool scripts
├── docs/               # This documentation
├── etc/                # Active configuration (jenova.conf, jenova.local.conf)
├── external/
│   ├── ext_bin/        # Compiled backend binaries (llama-server and libraries)
│   └── llama.cpp/      # Inference engine (git submodule)
├── hardware-profiles/  # Per-hardware tuning profiles and auto-detection
├── jca_web/            # Web UI source (SvelteKit)
├── jenova-ui/          # Desktop Manager source (C)
├── lib/                # Lua modules and shell libraries
├── png/                # Icons and branding
├── public/             # Built Web UI, served by the proxy (build output)
├── scripts/            # Build, install, update and maintenance scripts
├── tests/              # Test scripts
└── var/                # Runtime database, logs and cache (gitignored)
```

Your models, database, logs and workspaces live under `~/Jenova`, not in this repository.
`make install` deploys a self-contained system there that does not depend on the source tree.

---

## Privacy

- **Local inference** — every token is generated on your own GPU or CPU.
- **No telemetry** — nothing is reported anywhere.
- **Your data is yours** — SQLite and Markdown in your home directory, not a vendor's database.
- **One outbound exception** — the web-search tool queries DuckDuckGo when a model invokes it.

Details, including exactly what leaves the machine and when, in [docs/privacy.md](docs/privacy.md).

---

## Acknowledgements and License

Built on [llama.cpp](https://github.com/ggml-org/llama.cpp). Licensed under AGPL-3.0 — see
[LICENSE](LICENSE), [NOTICE](NOTICE) and [UPSTREAM-COPYRIGHT](UPSTREAM-COPYRIGHT).

---

<img src="png/splash_bottom.png" width="100%" alt="Jenova Cognitive Architecture footer">
