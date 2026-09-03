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

`F11` toggles fullscreen. It is the window's only keyboard shortcut.

## Intent prefixes

Beginning a message with one of these changes how the pipeline builds the request. The prefix is
**stripped before the model sees it** — it is addressed to Jenova, not to the model. They work
from any client: the window, the Web UI, or `curl`.

| Prefix | Effect |
|---|---|
| `Web Search:` | Runs a DuckDuckGo search and injects the results. Retrieval is skipped — the context comes from the web. Tools are stripped |
| `Visual Rewrite:` | Minimal retrieval, tools stripped |
| `Open File Chat:` / `Chatbot:` | More retrieval, and for a large payload carrying a `Path:` marker the query is rewritten to the file's basename plus your prose, so the search is on your question rather than on the pasted file |
| `Editor:` | Reads whatever document Neovim currently has open and attaches it. **Only this prefix does** — it is the largest block the pipeline can inject, so it is never attached to a turn that did not ask for it |

With no prefix you get the ordinary persona plus retrieval.

## Attachments

A file over roughly 23 MB is **refused, not shortened**: a truncated document would be answered as
though it were the whole thing. Whether a file is text is decided by reading it — a NUL byte in
the first 8 KiB makes it binary — so a `.log`, a `.conf` or a file with no extension is
attachable. PDFs have their text extracted; PDF pages are not sent as images.

## Maintenance

```sh
jenova-core paths                    # every resolved runtime path
jenova-core config                   # paths plus the resolved configuration
jenova-core db-capabilities          # what the linked libsqlite3 supports
jenova-core hardware detect          # what this machine is, and which profile matched
jenova-core hardware list            # every profile, scored
jenova-core hardware apply --best    # deploy the matched profile
```

The desktop application has the same thing under the Hardware button.

### Disk that Jenova manages itself

Both are bounded, and neither was before — see `.devdocs/03-error-memory-wiring.md`.

| Path | Holds | Bound |
|---|---|---|
| `~/Jenova/var/log/llama-server.log`, `llama-embed.log` | Each backend's stdout and stderr | Rotated to `.log.1` when it passes 8 MB, at the next backend start. One previous generation is kept |
| `~/Jenova/var/cache/attachments/` | Images decoded for thumbnails and previews (`attach-<sha256>`) and images taken off the clipboard (`pasted-<time>.png`) | Swept oldest-first to 256 MB when the desktop application starts |

Neither is rotated or swept while running: a log is rotated only at a start, because that is the
one moment no descriptor is open on it, and the cache is swept only at startup, because statting a
directory on the path that decodes a thumbnail would put filesystem work inside a redraw.

The sweep deletes only from the `attachments/` subdirectory, which Jenova creates for itself, and
only files carrying one of its own two name prefixes. `CACHE_DIR` is yours to point wherever you
like, and a filename is not ownership — so nothing outside that subdirectory is ever a candidate,
whatever it is called.

### Self-tests

```sh
nimble suites            # both binaries, every self-test, every shell suite
jenova-core db-selftest  # or any one of them alone
```

The self-tests are this project's assertion base. Each exits 0 on PASS and 1 on FAIL, and the list
`nimble suites` runs is declared in `jenova_core.nimble` — a self-test that is not in that list is
one nothing runs.

> `db-selftest` measures how much of a reader's run overlapped a concurrent writer and fails below
> 25%. That is a wall-clock measurement, so it can fail on a heavily loaded or single-core machine
> without anything being wrong with the database layer. Re-run it before treating a failure there
> as real.

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

### Discovery is not the same set the switcher offers

**These are two different questions and they read two different sets of directories.** Discovery,
above, answers "which model runs" and searches `models/agent/`, `models/draft/`, `models/embed/`
and the flat `models/` root. The switcher — `jenova-core models switch`, and the desktop
application's Models panel — answers "which model may I switch *to*", and reads only:

```
~/Jenova/models/instruct/
~/Jenova/models/thinking/
```

So a `.gguf` placed in `~/Jenova/models/` or `~/Jenova/models/agent/` **is used for inference and
does not appear in the Models panel.** That is deliberate: those two directories are yours to
organise and the switcher reads them without managing them, while `models/agent/` is the link the
switcher itself maintains. The panel says which two directories it looked in when it finds
nothing.

To make a model switchable, put it in `instruct/` or `thinking/`.

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
| `/api/fs/...` | Filesystem operations, including `POST /api/fs/trash/restore` and `DELETE /api/fs/trash/empty` |
| `/api/db/...` | The SQLite workspace database — `conversations`, `messages`, `workspaces`, `projects`, `folders`, `notes`, `fileAssets`, plus `import` and `cache` |
| `GET /<path>` | Static Web UI assets from `public/`; `/` serves `index.html` |

Workspaces are listed through `GET /api/db/workspaces`, like every other entity. Anything else
under `/api/` answers `404` with a JSON body.

### Augmented, then forwarded

`POST /v1/chat/completions` is intercepted by `src/jenova/pipeline.nim`, which detects and strips
an intent prefix, retrieves context, runs a web search for the web-search intent, reads the live
editor document for the editor intent, injects a persona, **strips** tools for the two intents
that gain nothing from them, and trims the oldest turns if the conversation no longer fits the
context budget. The rewritten body is then forwarded to `llama-server` on `:8081`.

`POST /infill` and `POST /completion` carry a raw prompt rather than a `messages` array, so there
is nothing to inject into: `pipeline.prepare` returns them untouched and they are forwarded
verbatim.

#### Response headers the pipeline adds

Emitted only when there is something to report, so an ordinary turn's response head is unchanged.

| Header | Meaning |
|---|---|
| `X-Cache: HIT` | Answered from the response cache rather than the model |
| `X-Jenova-Trimmed: N` | N oldest turns were dropped to fit the context budget. **The model was not shown the start of this conversation** |
| `X-Jenova-Rag-Hits: N` | N documents were retrieved and injected |
| `X-Jenova-Web-Hits: N` | N web-search results were injected |
| `X-Jenova-Intent: <name>` | An intent prefix was detected and stripped |
| `X-Jenova-Editor-Doc: 1` | A live document was read from Neovim and attached |

### Forwarded to `llama-server` unchanged

**Only these prefixes are forwarded.** There is no catch-all relay: `src/jenova/routes.nim`
classifies a request from its path alone, and anything matching none of the prefixes below is
served from `public/` or answered `404`.

| Prefix | Goes to |
|---|---|
| `/v1/` (other than `/v1/health`), `/completion`, `/infill`, `/chat`, `/props`, `/slots` | inference, `:8081` |
| `/embed`, `/embeddings` | embeddings, `:8082` |

So `GET /v1/models`, `POST /v1/completions` and `GET /props` are reachable through `:8080` because
they match `/v1/` and `/props` — not because unmatched requests fall through. A llama.cpp endpoint
outside these prefixes is **not** reachable.

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
