# Using jvim

`jvim` is the primary interactive interface for Jenova. It is a Neovim
hard-fork (in `jvim/`) with a custom runtime (`jvim-config/`) that hosts the
agent, chat sidebar, backend monitor, health check, LAN model discovery, and
the llama.vim FIM completion plugin.

## Launching

```sh
jenova [files...]      # backend + editor (recommended)
jvim [files...]        # editor only (assumes backend already running)
bin/jenova --check     # print resolved JENOVA_* environment and exit
```

`bin/jenova` accepts:
- `--no-backend` — skip starting `jenova-ca` (just open `jvim`).
- `--daemon-only` — start `jenova-ca` and exit (no editor).

## Keymaps (`<leader>a*`)

All keymaps are normal-mode unless a different mode is shown. They are
registered in `jvim-config/lua/jenova/chat.lua` and `jvim/runtime/plugin/jvim_ui.lua`.

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>aa` | n | Toggle / focus chat sidebar |
| `<leader>ac` | n | Chat with current-buffer context |
| `<leader>an` | n | New chat |
| `<leader>ar` | n | Respond / send the current input |
| `<leader>ai` | n | Inline rewrite under cursor |
| `<leader>as` | n | Web search (uses `fetch` on FreeBSD, `curl` on Linux) |
| `<leader>af` | n | Toggle FIM Autocomplete |
| `<leader>ax` | n | Stop generation |
| `<leader>ae` | v | Send selection to chat (ask about visual range) |
| `<leader>aw` | v | Visual Rewrite (Selection) |
| **Management** | | **(<leader>am*)** |
| `<leader>amm` | n | Toggle Agent ↔ Conversation mode |
| `<leader>amr` | n | Reset Agent Context / Memory |
| `<leader>amf` | n | New Chat (Fresh Context / Wipe history) |
| `<leader>amd` | n | Delete current chat |
| **Tools** | | **(<leader>at*)** |
| `<leader>atm` | n | Open Jenova Monitor (Performance/Metrics) |
| `<leader>ath` | n | Run Jenova Health Check |
| `<leader>atl` | n | Scan LAN for remote Jenova CA |
| `<leader>atd` | n | Fix LSP diagnostics in current buffer |
| `<leader>atj` | n | Toggle Jenova Agent Terminal |

## Commands

| Command | Action |
|---------|--------|
| `:JenovaChat` | Toggle the chat sidebar. |
| `:JenovaChatNew` | Start a fresh conversation. |
| `:JenovaChatRespond` | Send the current chat input. |
| `:JenovaChatStop` | Stop generation. |
| `:JenovaChatDelete` | Delete the current chat. |
| `:JenovaChatFresh` | Wipe all chats and start clean. |
| `:JenovaChatContext` | Open a chat seeded with the current buffer. |
| `:JenovaToggleMode` | Toggle agent ↔ conversation mode. |
| `:JenovaAgentReset` | Reset the agent's internal state/history. |
| `:JenovaWebSearch` | Run a web search and stream the result into the chat. |
| `:checkhealth jenova` | Run the Jenova health check (ports, deps, models, LSP). |

The backend monitor (`jvim-config/lua/jenova/monitor.lua`) is opened via the
public Lua API:

```vim
:lua require("jenova.monitor").open_monitor()
```

It shows service status (proxy / llama-server / embed), tokens-per-second,
context usage, and GPU layer distribution, polled live.

## Inline Rewriting

In visual mode, select a region and press `<leader>ai`. The agent receives
the selection, the surrounding buffer, and any active LSP diagnostics, then
streams a diff back into the chat sidebar that you can apply with the chat
"apply" action.

## Health Check

`:checkhealth jenova` (implemented in `jvim-config/lua/jenova/health.lua`)
verifies:

- backend ports (`8080` / `8081` / `8082`) are reachable
- Neovim version and required runtime files
- declared LSP servers and formatters are installed
- Vulkan loader and at least one Vulkan device is visible
- model files referenced by `etc/jenova.conf` exist
- enough free RAM / VRAM for the active profile
