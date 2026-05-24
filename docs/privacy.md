# Privacy & Data Security

Jenova is designed as a **local-first** cognitive architecture. This means your data stays on your hardware.

## Data Locations

The following directories and files contain user data and are **automatically ignored** by git to prevent accidental uploads:

| Path | Description | Why it is private |
|------|-------------|-------------------|
| `models/` | AI Model Weights (`.gguf`, etc.) | Multi-GB files, user-specific selection. |
| `.jenova/` | Runtime State & PIDs | Local process management. |
| `var/log/` | System & Agent Logs | May contain chat snippets or system paths. |
| `var/cache/` | Embeddings & RAG Cache | Local semantic index of your files. |
| `etc/*.local.conf` | Local Config Overrides | May contain local API keys or custom paths. |
| `*.sqlite`, `*.db` | Databases | Chat history and persistent memory. |
| Browser IndexedDB | WebUI client-side storage (Dexie) | Conversations, workspaces, cached responses. |
| `.env`, `*.key` | Secrets | Credentials and encryption keys. |

## Privacy Guarantee

1. **No Cloud Phoning**: Jenova does not send your data to any external servers unless you explicitly configure a remote LLM provider (like OpenAI or Anthropic) in the configuration.
2. **Local Inference**: By default, all reasoning happens on your GPU/CPU via `llama.cpp`.
3. **Transparent Source**: All scripts and the core logic are open-source and can be audited.
4. **Isolated Environments**: Jenova components are designed to run with minimal privileges required for their tasks.

## Best Practices

- Do not commit files with sensitive information to the repository.
- Use `etc/jenova.local.conf` for any configuration that contains private data.
- Regularly check `var/log/` if you want to see what information the agent is processing.
