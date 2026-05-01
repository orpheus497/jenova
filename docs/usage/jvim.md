# Using jvim

`jvim` is the primary interactive interface for Jenova. It is a Neovim hard-fork that integrates the AI agent directly into the editor experience.

## Launching
The recommended way to start your session is via the `jenova` launcher:
```sh
jenova [files...]
```
This starts the backend daemons and opens `jvim`.

## Keymaps (`<leader>a*`)

| Keymap | Mode | Action |
|---|---|---|
| `<leader>at` | n | Toggle chat panel |
| `<leader>an` | n | New chat |
| `<leader>ac` | n | Chat with buffer context |
| `<leader>ar` | n | Respond / send message |
| `<leader>aa` | n | Open / focus agent panel |
| `<leader>ax` | n | Stop generation |
| `<leader>am` | n | Open backend monitor |
| `<leader>ah` | n | Run health check |

## Commands

| Command | Action |
|---|---|
| `:JenovaChat` | Toggle the chat sidebar. |
| `:JenovaChatNew` | Start a fresh conversation. |
| `:JenovaMonitor` | Open a floating window with real-time backend stats. |
| `:JenovaAgentReset` | Reset the agent's internal state/history. |

## Inline Rewriting
Highlight code in visual mode and press `<leader>ai` (if configured) or use the agent panel to request a rewrite. The agent will provide a diff that you can review and apply.

## Backend Monitor
The `:JenovaMonitor` window shows:
- **Service Status**: Online/Offline status of the proxy, llama-server, and embed server.
- **Inference Stats**: Context usage, tokens per second, and GPU layer distribution.
