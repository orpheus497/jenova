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
registered in `jvim-config/lua/jenova/chat.lua`.

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>at` | n | Toggle chat sidebar |
| `<leader>aa` | n | Open / focus chat sidebar |
| `<leader>an` | n | New chat |
| `<leader>aF` | n | Fresh chat (wipe history) |
| `<leader>ac` | n | Chat with current-buffer context |
| `<leader>ar` | n | Respond / send the current input |
| `<leader>ad` | n | Delete the current chat |
| `<leader>ax` | n | Stop generation |
| `<leader>am` | n | Toggle agent / conversation mode |
| `<leader>ai` | n | Inline rewrite under cursor |
| `<leader>as` | n | Web search (uses `fetch` on FreeBSD, `curl` on Linux) |
| `<leader>ae` | v | Send selection to chat (ask about visual range) |
| `<leader>aw` | v | Apply visual selection as agent target |
| `<leader>af` | n | Pick a file to attach as context |

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
