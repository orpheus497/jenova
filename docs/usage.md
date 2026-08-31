# Usage

Commands, model management, and the HTTP API.

## The headless server — `jenova-core`

`jenova-core serve` is the HTTP server on `:8080` **and** the supervisor for `llama-server`
(`:8081`) and the embedding server (`:8082`). There is no separate "start the server" step: one
process owns all three, so "the daemon is up" and "`:8080` answers" cannot disagree.

```sh
jenova-core serve                   # server plus both backends, in the foreground
jenova-core serve --lan             # bind the client port to 0.0.0.0 instead of 127.0.0.1
jenova-core backends status         # pids, per backend
jenova-core backends health         # does the port answer — not the same question
jenova-core backends restart        # stop and start both backends
jenova-core backends args           # print the exact llama-server command lines
```

| `serve` flag | Effect |
|---|---|
| `--lan` | Set the client-facing bind address to `0.0.0.0`. `:8081` and `:8082` stay on loopback |
| `--port N` | Client-facing port (default 8080) |
| `--llama-port N` | Inference port (default 8081) |
| `--embed-port N` | Embedding port (default 8082) |

A watchdog runs on its own thread inside `serve`: it polls every 30 s, acts after 3 consecutive
failures, and holds off for 60 s after a restart. **It checks health, not liveness** — a wedged
`llama-server` keeps its pid and stops serving, and only the port tells the truth.

`JENOVA_NO_BACKENDS=1` serves without starting the backends; the test suites set it so running
them never loads a model onto the GPU.

Runtime state lives under `$JCA_HOME/.system/` (the database, pid files), logs in
`$JCA_HOME/var/log/`. `JCA_HOME` defaults to `~/Jenova`.

## The desktop application — `jenova`

```sh
jenova             # the window, plus a tray item
jenova --no-tray   # the window alone
```

`jenova` starts the same server and the same backends in-process — it is `jenova-core` with a
GTK4 window attached, not a client that talks to one. The window and the tray menu offer the same
operations: start, stop and restart the backends; live health per service; toggle LAN/LOCAL; open
the Web UI; and switch the active model between `instruct` and `thinking`.

The `jenova.desktop` entry launches `jenova`.

## Maintenance

```sh
jenova-core paths                    # every resolved runtime path
jenova-core config                   # paths plus the resolved configuration
jenova-core db-capabilities          # what the linked libsqlite3 supports
./hardware-profiles/detect-hardware.sh --info
sudo hardware-profiles/<backend>/<config>/jenova-setup   # sysctls, swap, ZFS ARC
```

---

## Models

### Directory layout

Models live under `$JCA_HOME/models` — `~/Jenova/models` by default, **not** in the source
repository.

```
~/Jenova/models/
├── agent/      # main inference model
├── draft/      # small model for speculative decoding
├── embed/      # embedding model for retrieval
├── instruct/   # optional — switch target for `models switch`
└── thinking/   # optional — switch target for `models switch`
```

Only `agent/`, `draft/` and `embed/` are scanned automatically. `instruct/` and `thinking/` exist
solely as sources for `jenova-core models switch`.

### Discovery

`src/jenova/models.nim` resolves the three model paths. `models.discover` is called from
`config.load` at startup, **and only for a path the configuration left empty** — an explicit
`MODEL_PATH`, `MODEL_DRAFT` or `MODEL_EMBED` in `etc/jenova.conf` or `etc/jenova.local.conf` is
never overridden by a directory scan.

For each directory it takes the **alphabetically first** `.gguf` — regular file or symlink, at
depth 1 only, no recursion. The sort is explicit, so the choice is deterministic when a directory
holds several rather than depending on filesystem order. A symlink counts because
`jenova-core models switch` makes the active model one.

| Model | Resolution order |
|---|---|
| Agent | `$JENOVA_MODEL` if set → otherwise `models/agent/*.gguf` → otherwise `models/*.gguf` in the flat root → otherwise empty |
| Draft | `$JENOVA_DRAFT_MODEL` if set → otherwise `models/draft/*.gguf` → otherwise empty |
| Embed | `$JENOVA_EMBED_MODEL` if set → otherwise `models/embed/*.gguf` → otherwise empty |

The flat-root fallback applies to the **agent model only**. There is no fallback for the draft or
embedding model — if `models/draft/` and `models/embed/` are empty, those paths resolve to the
empty string. A `.gguf.old` backup left by a model switch is not discovered, because it no longer
ends in `.gguf`.

`jenova-core models list` prints what discovery resolved.

### Overrides

Set these in your shell or in `etc/jenova.local.conf`, which survives updates:

```sh
export JENOVA_MODEL=/path/to/agent.gguf
export JENOVA_DRAFT_MODEL=/path/to/draft.gguf
export JENOVA_EMBED_MODEL=/path/to/embed.gguf
```

An override always wins over discovery.

### Adding a model

Drop a `.gguf` into the matching directory and restart:

```sh
cp my-model.gguf ~/Jenova/models/agent/
jenova-core backends restart
jenova-core backends status
```

Each profile's `profile.conf` names a `RECOMMENDED_AGENT_MODEL` and `RECOMMENDED_EMBED_MODEL` with
the URL it was sized against.

Requirements are GGUF format and a llama.cpp-supported architecture. Quantisation is your choice;
the profiles are tuned around Q4_K_M through Q8_0.

**Hardware profiles do not select a model.** They set devices, layer offload, context size, batch
sizes, threads and KV cache type. Which model runs is whatever discovery finds.

### Switching between instruct and thinking models

Place `.gguf` files in `models/instruct/` and `models/thinking/`, then use the window or the tray
menu ("Switch to Instruct Model" / "Switch to Thinking Model"), which runs the switch and restarts
the backend.

The same operation is available headless:

```sh
jenova-core models switch instruct
jenova-core models switch thinking
```

It picks the alphabetically first `.gguf` in the target directory that is not a `.old` backup and
symlinks it into `models/agent/` **by a relative path**, so the tree survives being moved. Whatever
was active is preserved by renaming it to `.old` (or `.old.<n>` if that name is taken); an entry
that already resolves to the same file is removed rather than backed up, since a second name for
one file is pointless. The replacement link is built under a temporary name and its resolved target
checked before anything active is touched, and the swap itself is a rename — so a failure part way
leaves the old model in place, and no reader ever sees `models/agent/` without one.

**Run headless, it does not restart the backend** — the window and tray do that for you. From the
command line, follow it with `jenova-core backends restart`.

---

## HTTP API

Everything is on `:8080`. Nothing else is client-facing.

### Handled by the server

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
`public/` — is relayed verbatim to `llama-server`. The rest of its OpenAI-compatible surface, including
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
