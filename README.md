# Coder Agent (FreeBSD/Vulkan Optimized)

An agentic coding assistant designed for **FreeBSD 15.0** and **Hybrid GPU** (GTX 1650 Ti + Intel Iris Xe) hardware.

## 🚀 Speed & Intelligence (v2.1)
The project is optimized for a dual-tier model hierarchy:
- **Fast Agent (7B)**: The `coder-agent` uses **Qwen2.5-Coder-7B-Instruct** for rapid tool calling (15-20+ tokens/s).
- **Deep Reasoner (14B)**: The `coder-server` uses **Qwen2.5-Coder-14B-Instruct** with automatic fallback to 7B.
- **Speculative Decoding**: Uses the **0.5B model** as a drafter to accelerate generation by up to 3x.

## 🛠 Features
- **Robust Tooling**: `read_file`, `edit_file`, `write_file`, and a high-speed `grep_search`.
- **Hybrid Search**: BM25 keyword matching + Semantic vector search (Nomic Embed v1.5).
- **FreeBSD First**: Tailored for `cc`, `sysctl`, and Vulkan offloading (NVIDIA + Intel).
- **Session Isolation**: Automatic backups and session-local memory to prevent stale context pollution.

## 📁 Directory Structure
- `bin/`: Launch scripts (`coder-server`, `coder-agent`).
- `lib/`: Core logic (LuaJIT) for the agent, tool execution, and memory.
- `etc/`: Central configuration (`coder.conf`).
- `models/`: Model storage (GGUF format).
- `var/`: Runtime state, logs, and cache.
- `.coder/`: Internal agent state and automated file backups.

## ⚙️ Configuration
Edit `etc/coder.conf` to adjust:
- `MODEL_PATH`: Primary server model (Default: 7B).
- `MODEL_7B`: Agent model (Default: 7B).
- `TENSOR_SPLIT`: Hardware allocation (Optimized for 1650 Ti + Iris Xe).
- `CODER_DRAFT=1`: Enable speculative decoding (Requires 0.5B model).

## 🔒 Security
- All session data, logs, and backups are stored locally in `.coder/` and `var/`.
- Large binary files and personal configuration files are ignored by Git.
- **Never commit `.env` or SSH keys**; these are explicitly blocked in `.gitignore`.

## 🖥 Usage
```bash
# Start the backend server (Fast 7B by default)
./coder-server

# Run the agent in another terminal
./coder-agent
```

## 📋 Neovim Integration
The `coder-server` supports multi-slot usage for both the agent and Neovim FIM (Fill-In-Middle) completions simultaneously.

