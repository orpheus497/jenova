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

nimble llama     # build the llama.cpp backend into external/ext_bin
nimble web       # build the Web UI into public/
nimble gui       # build bin/jenova, the desktop application
./bin/jenova
```

Then open <http://localhost:8080>, or just use the window.

The build system is **nimble**; the tasks are declared in `jenova_core.nimble`. There is no
Makefile, and no build or runtime step shells out to a project script.

Individual tasks: `nimble core` (the headless binary), `nimble gui`, `nimble llama`, `nimble web`,
`nimble suites` (build both binaries and run the test suites).

---

## What Runs

One process owns all three ports: the application starts the HTTP server on `:8080` and supervises
both `llama-server` backends in-process.

| Port | Service | Bind | Purpose |
|---|---|---|---|
| **8080** | Jenova HTTP server | `127.0.0.1`, or `0.0.0.0` under `--lan` | The only client-facing port. Serves the Web UI, the workspace database API, retrieval, web search, and forwards inference |
| 8081 | `llama-server` | loopback always | OpenAI-compatible inference |
| 8082 | `llama-server` (embedding mode) | loopback always | Embeddings for semantic search |

**`:8080` is the only port to open in a firewall.** 8081 and 8082 bind loopback unconditionally —
including under `--lan` — because nothing outside the host addresses them. They are
unauthenticated; exposing them would publish open inference endpoints.

### Web UI

A SvelteKit static SPA served at `:8080`, and the LAN client. Persistent workspaces, branching
conversation history, token streaming with TPS/TTFT metrics, `<think>` reasoning blocks, GFM
markdown, KaTeX math, syntax highlighting, in-browser PDF viewing, and MCP client support.

Workspaces, projects, folders, conversations, messages and notes are stored in SQLite at
`~/Jenova/.system/jenova.db`, managed by the server. Notes and chats are additionally mirrored to
`~/Jenova/Workspaces` as plain Markdown, readable and editable with any text editor.

### Desktop application

`jenova` is a native Nim application built with [owlkettle](https://github.com/can-lehmann/owlkettle)
on GTK4/libadwaita, compiled from `src/jenova_gui.nim`. It offers two surfaces over the same
in-process code:

- **The window** — chat, the workspace tree, notes, a canvas, and backend control: start, stop and
  restart, live per-service health, the LAN toggle, model switching, and the Web UI opener.
- **A system tray item** — the same control surface from a context menu, published over D-Bus as a
  `org.kde.StatusNotifierItem` (`src/jenova/tray.nim`). `--no-tray` runs the window without it.

There is no separate supervisor to start: `jenova` *is* the server. It brings up the HTTP port and
both backends itself and supervises them in-process. `jenova-core` is the same program without the
GTK dependency, for a headless or LAN-server host.

### LAN mode

`jenova-core serve --lan` moves the client-facing port to `0.0.0.0`, making your workspace
reachable from a phone, tablet or second machine at `http://<host-ip>:8080`. The window and the
tray menu toggle the same thing.

---

## Commands

`nimble` builds two binaries into `bin/`:

| Command | Description |
|---|---|
| `jenova` | The desktop application. Starts the server and both backends itself. `--no-tray` suppresses the tray item |
| `jenova-core` | The same program without GTK, for a headless or LAN-server host — see [docs/usage.md](docs/usage.md) |

`jenova-core` carries the operational subcommands: `serve`, `backends`, `models`, `paths`,
`config`, `db-init`, `db-capabilities`, and the self-tests. The desktop application performs the
same operations in-process — backend control, model switching and the LAN toggle are all in its
window and tray menu — and spawns no shell to do any of it.

---

## Hardware

Jenova targets consumer and prosumer laptops. Detection runs at install time and deploys a
matching profile that sets GPU offload, context size, batch sizes and thread counts.

| Profile | Devices | Layers | Context | Drafter |
|---|---|---|---|---|
| `Vulkan/dgpu-i5-1135g7` | `Vulkan0` | 16 | 8K | no |
| `Vulkan/dgpu-igpu-i5-1135g7` | `Vulkan0,Vulkan1` | all | 32K | yes |
| `Vulkan/apu-ryzen7-5700u` | `Vulkan0` | 24 | 16K | yes |
| `Vulkan/dgpu-generic-12gb` | `Vulkan0` | all | 32K | yes |
| `CPU/generic` | `CPU` | 0 | 16K | no |
| `CUDA/dgpu-generic` | `CUDA0` | all | 16K | yes |

**Profiles do not choose your model.** `src/jenova/models.nim` discovers whatever `.gguf` files are
in `~/Jenova/models/` — `models.discover`, called from `config.load`, fills only the model paths the
configuration left empty. Point `JENOVA_MODEL`, `JENOVA_DRAFT_MODEL` or `JENOVA_EMBED_MODEL` at
anything else you like; an explicit path always wins over discovery.

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

Both binaries carry a `when not defined(freebsd)` guard and will not compile anywhere else.
Hardware detection reads `kern.ostype` rather than `uname -s`, which answers `Linux` under the
FreeBSD Linuxulator.

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
├── bin/                # Built binaries: jenova, jenova-core
├── docs/               # This documentation
├── etc/                # Active configuration (jenova.conf, jenova.local.conf)
├── external/
│   ├── ext_bin/        # Compiled backend binaries (llama-server and libraries)
│   └── llama.cpp/      # Inference engine (git submodule)
├── hardware-profiles/  # Per-hardware tuning profiles and auto-detection
├── jca_web/            # Web UI source (SvelteKit)
├── png/                # Icons and branding
├── public/             # Built Web UI, served at :8080 (build output)
├── src/
│   ├── jenova/         # The modules both binaries link
│   ├── jenova_core.nim # Headless server entry point
│   └── jenova_gui.nim  # Desktop application entry point
└── tests/              # Test suites, run by `nimble suites`
```

Your models, database, logs and workspaces live under `~/Jenova`, not in this repository.

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
