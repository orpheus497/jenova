# <img src="png/jenova.png" width="48" height="48" valign="middle"> Jenova Cognitive Architecture

Jenova is a local-first, hardware-aware AI environment designed for consumer laptops, professional workstations, and headless servers. It integrates an inference backend, a purpose-built terminal IDE (`jvim`), a unified native Desktop Application, and an intelligent OS-level System Tray into one cohesive, autonomous ecosystem that runs entirely on your hardware.

## 🌌 The Ecosystem

### 1. Jenova Cognitive Architecture (Core Backend)
The absolute foundation of the system. Written in C, Lua, and Bash, the `jenova-ca` daemon handles hardware-aware model loading (automatically adapting to single-GPU, dual-GPU, or CPU-only constraints via Vulkan). It daemonizes the `llama-server` inference engine and the Lua-based intelligence proxy, establishing the local environment.

### 2. Jenova Desktop Manager (`jenova-ui`)
A lightweight, Kanagawa-themed native desktop application written in **C** with **GTK3** and **Lua** orchestration. It provides both a system tray icon and an ncurses-based TUI for managing the Jenova backend lifecycle.
- Features a **System Tray Icon** with real-time health polling and one-click server controls.
- Includes an **ncurses TUI** for terminal-based management of all Jenova components.
- Supports **FreeBSD**, Linux, and macOS.

### 3. J.C.A. Tray Icon & Server Manager
A persistent, intelligent background controller built directly into your OS taskbar.
- **Real-Time Polling**: A GLib timer actively polls the server's health every 3 seconds via Lua. The tray icon displays in **Full-Color** (`jca.jpg`) when active on port 8080 and automatically degrades to **Grayscale** (`jca_grey.jpg`) when inactive.
- **Native Context Menu**: Right-click to `Start Server`, `Stop Server`, `Restart Server`, or open the Web UI.
- **Minimize-to-Tray**: The backend engine runs safely in the background even if you close the Workstation window.

### 4. Jenova Workspaces (WebUI)
An elegant, browser-based chat and workspace UI. It is compiled seamlessly into the Jenova Workstation app for native desktop use, but remains entirely accessible as a standard web application for flexibility. Workspaces are inherently tied to your local files, ensuring seamless transition between graphical chat and terminal editing.

### 5. Jenova Vim (`jvim`)
The Jenova-specific fork of NeoVim. It is a comprehensive *Interactive Director Environment* (IDE) that provides deep agentic assistance, inline code mathematical grounding, and autonomous LSP-driven actions right inside your terminal.

### 6. Modern C Shell (`mcsh`)
A heavily modernized and deeply integrated C-shell environment tailored to interface beautifully with the Jenova ecosystem.

### 7. OpenAI-Compatible API (`llama-server`)
The core inference engine natively exposes a universally compatible OpenAI API. 
- **Default Routing**: We highly advise routing external tools (like the Leo browser or autonomous scripts) to `http://127.0.0.1:8081/v1/chat/completions`.
- Keeping external API traffic isolated to `8081` ensures that port `8080` remains clean, linear, and dedicated strictly to your visual WebUI Workspaces.

### 8. Jenova Remote Access (Mobile / LAN)
Jenova is explicitly designed to transcend your desktop monitor. By toggling `LAN Mode` via the J.C.A Tray Icon, the backend securely binds to `0.0.0.0`. 
This allows you to open your smartphone, tablet, or another laptop on your local Wi-Fi network, navigate to your host machine's IP, and seamlessly continue interacting with your Jenova Workspaces on the go.

---

## 🚀 Quick Start Installation

```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# 1. Full Build and Environment Setup
./scripts/build-desktop.sh

# 2. System Deployment & Desktop Integration
./scripts/install.sh
```

## 💻 Command Line Interface (CLI)

Jenova retains full, uncompromising terminal support for power users and headless setups.

* `jenova` - Launches the integrated `jvim` terminal editor.
* `jenova-desktop` - Launches the native GUI Workstation.
* `jenova-ca start|stop|restart|status` - Manually controls the core backend daemon.
* `jenova-tui` - A pure bash, Kanagawa-themed terminal UI for managing the server via terminal.
* `jenova-term` - A dedicated terminal environment utilizing the Jenova Modern C Shell.

### Advised Models
Jenova is heavily optimized for fast, accurate local reasoning. We strongly advise using **Qwen-2.5** derivatives (such as `Qwen2.5-Coder-7B` or `Qwen2.5-3B`) heavily quantized into GGUF format for optimal VRAM-to-parameter footprint ratios on consumer hardware.

---

## 📖 Documentation
Detailed documentation lives in `/docs`:
- [Streamlined Installation](docs/installation/STREAMLINED.md) — Complete workflow guide
- [Overview](docs/architecture/overview.md) — Architecture breakdown
- [Cognitive Backend](docs/architecture/backend.md)
- [Unified Agent System](docs/architecture/agent.md)
- [jvim (interactive)](docs/usage/jvim.md)

## ⚖️ Acknowledgements & License
Jenova is built on the profound foundations of [Neovim](https://neovim.io), [llama.cpp](https://github.com/ggml-org/llama.cpp), [tcsh](https://github.com/tcsh-org/tcsh), and [etcsh](https://github.com/Krush206/etcsh).

Licensed under AGPL-3.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
