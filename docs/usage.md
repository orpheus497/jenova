# Usage

Commands, model management, and the HTTP API.

## The backend — `jenova-ca`

`jenova-ca` supervises `llama-server` (`:8081`), the intelligence proxy (`:8080`) and the
embedding server (`:8082`) as one unit.

```sh
jenova-ca --daemon              # start all three in the background
jenova-ca --daemon --lan        # bind the proxy to 0.0.0.0 instead of 127.0.0.1
jenova-ca --daemon --watch      # also run a health watchdog that restarts failures
jenova-ca status                # PID and alive/dead per service
jenova-ca stop                  # stop everything and clean up PID files
jenova-ca restart               # stop + start
```

`start` is an alias for `--daemon`; `watch` runs the watchdog against an already-running backend.

| Flag | Effect |
|---|---|
| `--daemon` | Fork and supervise |
| `--lan` | Set the proxy bind address to `0.0.0.0`. `:8081` and `:8082` stay on loopback |
| `--watch` | Health monitoring with auto-restart after startup |
| `--port N` | Proxy port (default 8080) |
| `--llama-port N` | Inference port (default 8081) |
| `--embed-port N` | Embedding port (default 8082) |

Runtime state lives under `$JCA_HOME/.system/` (PID and lock files), logs in
`$JCA_HOME/var/log/`, caches in `$JCA_HOME/var/cache/`. `JCA_HOME` defaults to `~/JCA`.

## The interfaces

```sh
jenova         # tray if a display is available and this is not an SSH session; TUI otherwise
jenova-tui     # ncurses TUI directly (a wrapper for `jenova-ui tui`)
jenova-ui      # the Desktop Manager binary; `tui` as its first argument selects the TUI
```

Both the tray and the TUI offer the same operations: start, stop and restart the backend; live
health for each service; toggle LAN/LOCAL; open the Web UI; and switch the active model between
`instruct` and `thinking`.

The `jenova.desktop` entry launches `jenova`.

## Maintenance

```sh
scripts/update.sh --all        # pull, rebuild jenova-ui and the Web UI, re-apply the profile
scripts/cleanup.sh --all       # clear logs, cache, stale PID and lock files
scripts/uninstall.sh           # remove deployed files; models are preserved
scripts/verify-install.sh --full
```

```sh
sudo scripts/jenova-setup            # sysctls, swap, ZFS ARC for the active profile
sudo jenova-swap-mount <size>        # mount a swap-backed mdmfs for model storage
./hardware-profiles/detect-hardware.sh --info
```

---

## Models

### Directory layout

Models live under `$JCA_HOME/models` — `~/JCA/models` by default, **not** in the source
repository.

```
~/JCA/models/
├── agent/      # main inference model
├── draft/      # small model for speculative decoding
├── embed/      # embedding model for retrieval
├── instruct/   # optional — switch target for jenova-model-switch
└── thinking/   # optional — switch target for jenova-model-switch
```

Only `agent/`, `draft/` and `embed/` are scanned automatically. `instruct/` and `thinking/` exist
solely as sources for `jenova-model-switch`.

### Discovery

`lib/jenova-model.sh` runs at startup, sourced by `etc/jenova.conf`. For each directory it takes
the **alphabetically first** `.gguf` file — regular file or symlink — at depth 1:

| Model | Resolution order |
|---|---|
| Agent | `models/agent/*.gguf` → if that directory is empty or absent, `models/*.gguf` in the flat root → otherwise empty |
| Draft | `$JENOVA_DRAFT_MODEL` if set → otherwise `models/draft/*.gguf` → otherwise empty |
| Embed | `$JENOVA_EMBED_MODEL` if set → otherwise `models/embed/*.gguf` → otherwise empty |

`etc/jenova.conf` then applies the agent override: `MODEL_PATH="${JENOVA_MODEL:-$MODEL_AGENT}"`.

The flat-root fallback applies to the **agent model only**. There is no fallback for the draft or
embedding model — if `models/draft/` and `models/embed/` are empty, those paths resolve to the
empty string.

### Overrides

Set these in your shell or in `etc/jenova.local.conf`, which survives updates:

```sh
export JENOVA_MODEL=/path/to/agent.gguf
export JENOVA_DRAFT_MODEL=/path/to/draft.gguf
export JENOVA_EMBED_MODEL=/path/to/embed.gguf
```

An override always wins over discovery.

### Downloading

```sh
scripts/model_dl.sh
```

Downloads the defaults into `~/JCA/models/`, the same set for every hardware profile:

| Role | File | Approx. size |
|---|---|---|
| Agent | `Qwen3.5-4B-Q6_K.gguf` | ~3.5 GB |
| Embedding | `Qwen3-Embedding-0.6B-Q8_0.gguf` | ~650 MB |
| Draft | `Qwen3.5-0.8B-Q8_0.gguf` | ~0.8 GB |

It also symlinks `models/jenova.gguf` to the agent model for health checks.

To add your own, drop a `.gguf` into the matching directory and restart:

```sh
cp my-model.gguf ~/JCA/models/agent/
jenova-ca restart
jenova-ca status
```

Requirements are GGUF format and a llama.cpp-supported architecture. Quantisation is your choice;
the profiles are tuned around Q4_K_M through Q8_0.

**Hardware profiles do not select a model.** They set devices, layer offload, context size, batch
sizes, threads and KV cache type. Which model runs is whatever discovery finds.

### Switching between instruct and thinking models

Place `.gguf` files in `models/instruct/` and `models/thinking/`, then use the tray or TUI menu
("Switch to Instruct Model" / "Switch to Thinking Model"), which runs the switch and restarts the
backend.

The underlying tool can also be run directly:

```sh
jenova-model-switch instruct
jenova-model-switch thinking
```

It picks the alphabetically first `.gguf` in the target directory that is not a `.old` backup,
symlinks it into `models/agent/`, and preserves whatever was active by renaming it to `.old` (or
`.old.<n>` if that name is taken). An entry already pointing at the same file is simply removed
rather than backed up. The swap is atomic and validated before anything is replaced.

**Run directly, it does not restart the backend** — the tray and TUI do that for you. From the
command line, follow it with `jenova-ca restart`.

---

## HTTP API

Everything is on `:8080`. Nothing else is client-facing.

### Handled by the proxy

| Route | Purpose |
|---|---|
| `GET /health`, `GET /v1/health` | Liveness |
| `GET /api/storage/` | List workspace files |
| `GET`/`POST`/`DELETE` `/api/storage/<path>` | Read, write, delete a workspace file |
| `GET /api/workspaces` | List workspaces |
| `/api/fs/...` | Filesystem operations, including `POST /api/fs/trash/restore` and `DELETE /api/fs/trash/empty` |
| `/api/db/...` | The SQLite workspace database — `conversations`, `messages`, `workspaces`, `projects`, `folders`, `notes`, `fileAssets`, plus `import` and `cache` |
| `GET /<path>` | Static Web UI assets from `public/`; `/` serves `index.html` |

### Augmented, then forwarded

`POST /v1/chat/completions` and `POST /infill` are intercepted so retrieval context and tool
results can be injected, then forwarded to `llama-server` on `:8081`.

### Forwarded unchanged

Any request that matches nothing above — and any `GET` for a path with no matching file in
`public/` — is proxied to `llama-server`. The rest of its OpenAI-compatible surface, including
`GET /v1/models`, `POST /v1/completions` and `GET /props`, is therefore reachable through `:8080`.

### Example

```sh
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "jenova",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

Any OpenAI-compatible client works — point `base_url` at `http://<host>:8080/v1` and use any
non-empty `api_key`. There is no authentication; access control is the bind address and your
firewall.

Every response carries `Connection: close`. There is no keep-alive, no compression, and no
caching headers.
