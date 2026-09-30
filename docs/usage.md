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

`jenova` starts the same server and the same backends in-process — not a client that talks to
one. It differs from `jenova-core serve` in three ways: it runs no watchdog (a backend that dies is
reported, not restarted), it does not honour `JENOVA_NO_BACKENDS`, and when you quit it stops the
embedding server but deliberately leaves `llama-server` running, so the next start does not reload
the model.

The window's menu and the tray menu both offer start, stop and restart for the backends, the LAN
toggle, and Open Web UI. The tray also has "Switch to instruct model" and "Switch to thinking
model"; the window switches through its **Models…** selector instead, which lists the models in
`models/instruct/` and `models/thinking/`. Status is shown for the chat backend only — in the
window's header subtitle (ready, starting or stopped) and as the tray item's Active/Passive state;
the embedding server has no indicator on either.

`bin/jenova.desktop` runs `jenova` from your `PATH` with the icon name `jenova`. Nothing installs
it, the binary or the icon, so it works only once you have put `bin/jenova` on your `PATH` and
installed the entry and an icon yourself.

Keyboard shortcuts, declared in one place (`gui.keyBindings`) and installed on a
`GtkShortcutController` at managed scope, so they answer anywhere in the window:

| Key | Effect |
|---|---|
| `F11` | Toggle fullscreen |
| `Ctrl+N` | New conversation |
| `Ctrl+B` | Show or hide the sidebar |
| `Ctrl+,` | Open or close Settings |
| `Ctrl+Escape` | Stop the generation in progress. Plain `Escape` is left to GTK for popovers and dialogs |

## Intent prefixes

Beginning a message with one of these changes how the pipeline builds the request. The prefix is
**stripped before the model sees it** — it is addressed to Jenova, not to the model. They work
from any client: the window, the Web UI, or `curl`. In the window, the Send button's menu inserts
them for you; elsewhere you type them.

| Prefix | Effect |
|---|---|
| `Web Search:` | Runs a DuckDuckGo search and injects the results. Retrieval is skipped — the context comes from the web. Tools are stripped and `tool_choice` set to `none` |
| `Visual Rewrite:` | One retrieval result; tools stripped and `tool_choice` set to `none` |
| `Open File Chat:` / `Chatbot:` | The file-chat persona, with the same three retrieval results as no prefix |
| `Editor:` | Reads whatever document Neovim currently has open and attaches it. **Only this prefix does** — it is the largest block the pipeline can inject, so it is never attached to a turn that did not ask for it |

With no prefix you get the ordinary persona plus three retrieval results.

**Large payloads.** Whatever the prefix, a message over 2000 characters that carries a `Path:`
marker is treated as mostly file content: the retrieval query becomes the file's basename plus the
prose after the closing code fence, so the search is on your question rather than on the pasted
file, and it retrieves five results — `Web Search:` included.

## Attachments

A long paste is attached as a file instead of filling the message box, so it reaches the model as a
document and your message stays readable. The threshold is `pasteLongTextToFileLen` characters —
2500 by default, 0 to disable, on both surfaces. The window diverts a paste of *at least* that many
characters (counted as UTF-8 characters in the inserted run); the Web UI diverts one of *more* than
that many.

In the window, a file over about 23 MiB — `(32 MiB − 1 MiB) × 3/4`, room for its base64 inside the
server's 32 MiB request limit — is **refused, not shortened**: a truncated document would be answered
as though it were the whole thing. The Web UI has no size check of its own; the server refuses any
request body over 32 MiB with a `413`, also without truncating.

Whether a file is text is decided by reading it, so a `.log`, a `.conf` or a file with no extension
is attachable. The window treats a NUL byte in the first 8 KiB as binary; the Web UI samples the
first 10 KiB and rejects a file with more than two NUL characters, or with more than 15% control or
replacement characters.

PDFs: the window sends a PDF's extracted text, and refuses one with no extractable text. The Web
UI sends extracted text too, unless its `pdfAsImage` setting is on (it is off by default) and the
model supports vision, in which case it sends the pages as images.

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

Two directories grow with use, and both are bounded. What bounds each is in the table — there is
nothing to configure and nothing to prune by hand.

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
nimble suites            # both binaries and the Web UI, every self-test, every shell suite,
                         # then the two GUI harnesses
jenova-core db-selftest  # or any one of them alone
```

The self-tests are this project's assertion base. Each exits 0 on PASS and 1 on FAIL, and the list
`nimble suites` runs is declared in `jenova_core.nimble` — a self-test that is not in that list is
one nothing runs.

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

Only `agent/`, `draft/` and `embed/` are scanned automatically, plus the flat `models/` root
itself as the last fallback for the agent model. Discovery never scans `instruct/` and
`thinking/`: they are the sources a switch draws from — `jenova-core models switch`, the tray's two
switch items, and the window's Models… selector.

### Discovery

`src/jenova/models.nim` resolves the three model paths. `models.discover` is called from
`config.load` at startup, **and only for a path the configuration left empty** — an explicit
`MODEL_PATH`, `MODEL_DRAFT` or `MODEL_EMBED` in `jenova.conf` or `jenova.local.conf` is never
overridden by a directory scan. Those two files are read from `$JCA_HOME/etc/` once a hardware
profile has been applied there, and from the repository's `etc/` until then — never from both.

For each directory it takes the **alphabetically first** `.gguf` — regular file or symlink, at
depth 1 only, no recursion. The sort is explicit, so the choice is deterministic when a directory
holds several rather than depending on filesystem order. A symlink counts because
`jenova-core models switch` makes the active model one.

| Model | Resolution order |
|---|---|
| Agent | `$JENOVA_MODEL` if set → otherwise `models/agent/active.gguf` → otherwise `models/agent/*.gguf` → otherwise `models/*.gguf` in the flat root → otherwise empty |
| Draft | `$JENOVA_DRAFT_MODEL` if set → otherwise `models/draft/*.gguf` → otherwise empty |
| Embed | `$JENOVA_EMBED_MODEL` if set → otherwise `models/embed/*.gguf` → otherwise empty |

The flat-root fallback applies to the **agent model only**. There is no fallback for the draft or
embedding model — if `models/draft/` and `models/embed/` are empty, those paths resolve to the
empty string. A backup is never discovered: any name ending in `.old` or containing `.old.` is
skipped (`models.isBackup`), which covers the `.gguf.old` a switch leaves and a hand-made
`X.old.gguf` alike. A link that does not resolve is skipped too.

**`models/agent/active.gguf` is the exception to the alphabetical rule, and it is the point.**
A switch always writes the link under that one name, so where a switch has run the slot is read by
lookup and nothing else in the directory can change the answer. The alphabetical scan is the
fallback for a slot no switch has written — an install predating the fixed name, or one you fill by
hand. Before it, a second `.gguf` in `models/agent/` — dropped in yourself, or left behind by a
cleanup that could not remove it — sorted ahead of the switched model and quietly became the model
that ran.

`jenova-core models list` prints what discovery resolved, following the link so it names the model
rather than the slot.

### Discovery is not the same set the switcher offers

**These are two different questions and they read two different sets of directories.** Discovery,
above, answers "which model runs" and searches `models/agent/`, `models/draft/`, `models/embed/`
and the flat `models/` root. The switcher — `jenova-core models switch`, and the desktop
application's Models panel — answers "which model may I switch *to*", and reads only:

```
~/Jenova/models/instruct/
~/Jenova/models/thinking/
```

So a `.gguf` placed in `~/Jenova/models/` or `~/Jenova/models/agent/` **never appears in the
Models panel**, and it is used for inference only as a fallback: one in `models/agent/` only while
`models/agent/active.gguf` does not resolve, one in the flat `models/` root only when
`models/agent/` yields nothing. That split is deliberate: `instruct/` and `thinking/` are yours to
organise, and the switcher reads them without writing to them; it never reads the flat root; and
`models/agent/` is the slot the switcher manages — it writes `active.gguf` there, removes displaced
links, and renames a `.gguf` you put there by hand to `.old`. The panel says which two directories
it looked in when it finds nothing.

To make a model switchable, put it in `instruct/` or `thinking/`.

### Overrides

Two kinds, set in two places:

```sh
# In the environment of the jenova or jenova-core process — your shell, a launcher:
export JENOVA_MODEL=/path/to/agent.gguf
export JENOVA_DRAFT_MODEL=/path/to/draft.gguf
export JENOVA_EMBED_MODEL=/path/to/embed.gguf
```

```sh
# In jenova.local.conf, which survives updates:
MODEL_PATH=/path/to/agent.gguf
MODEL_DRAFT=/path/to/draft.gguf
MODEL_EMBED=/path/to/embed.gguf
```

The `JENOVA_*_MODEL` names **work only in the process environment**: the conf files are evaluated
in a separate `/bin/sh` and only the configuration keys are read back, so an `export` of them in
`jenova.local.conf` has no effect. `MODEL_PATH`, `MODEL_DRAFT` and `MODEL_EMBED` are configuration
keys, and discovery never overrides one that is set. Either kind wins over directory discovery,
and a `MODEL_PATH` wins over `JENOVA_MODEL`, because discovery — which is what reads
`JENOVA_MODEL` — runs only for a path the configuration left empty.

### Adding a model

For a draft or embedding model, or an agent model on an install no switch has touched, drop the
`.gguf` into the matching directory and restart:

```sh
cp my-model.gguf ~/Jenova/models/agent/
jenova-core backends restart
jenova-core backends status
```

Once any switch has run, `models/agent/active.gguf` wins: a file dropped into `models/agent/` is
ignored, and the next switch renames it to `.old`. To add an agent model then, put it in
`models/instruct/` or `models/thinking/` and switch to it.

Five of the six profiles' `profile.conf` name the models they were sized against, in
`RECOMMENDED_AGENT_MODEL` and `RECOMMENDED_EMBED_MODEL`, with download URLs in
`RECOMMENDED_AGENT_URL` and `RECOMMENDED_EMBED_URL`; `Vulkan/dgpu-igpu-i5-1135g7` names none.

Requirements are GGUF format and a llama.cpp-supported architecture. Quantisation is your choice;
the profiles are tuned around Q4_K_M through Q8_0.

**Hardware profiles do not select a model.** They set devices (`DEVICES`), layer offload
(`NGL_AGENT`), context size and slots (`CTX_SIZE`, `NUM_SLOTS`), threads (`THREADS`,
`THREADS_BATCH`) and KV cache type (`KV_CACHE_TYPE`); the four Vulkan profiles also set batch sizes
(`BATCH_SIZE`, `UBATCH_SIZE`), and the CPU and CUDA profiles leave them at the defaults, 2048 and
512. Which model runs is whatever discovery finds.

### Switching between instruct and thinking models

Place `.gguf` files in `models/instruct/` and `models/thinking/`, then switch: from the tray
("Switch to instruct model" / "Switch to thinking model"), or from the window's **Models…**
selector, which lists every model in those two directories and switches to the one you choose.
Neither restarts the backend — both relink `models/agent/active.gguf` and end their notice with
"restart to load it"; then use Restart backend.

The same operation is available headless:

```sh
jenova-core models switch instruct
jenova-core models switch thinking
```

**Thinking follows the folder.** A model switched in from `models/instruct/` runs with thinking off
(`llama-server --reasoning off`), because some instruct models otherwise answer inside an unclosed
`<think>` block, which arrives as reasoning with an empty answer. A model from `models/thinking/`
keeps llama-server's automatic setting, which thinks when the model's template supports it. Set
`JENOVA_REASONING` to `on`, `off` or `auto` in `jenova.local.conf` (or the environment) to override
either; `jenova-core backends args` shows what will be passed.

It picks the alphabetically first `.gguf` in the target directory that is not a `.old` backup and
symlinks it to `models/agent/active.gguf` **by a relative path**, so the tree survives being moved.
The link is always that name, never the model's own — which is what lets discovery read the slot by
lookup. **The previously active model is not backed up**: it was a link under that same fixed name,
and the rename replaces it atomically, leaving the file it pointed at untouched in its own source
folder. What does get preserved, as `.old` (or `.old.<n>` if that name is taken), is a real `.gguf`
you put in `models/agent/` by hand, because that copy may be the only one. A link that already
resolves to the target is removed rather than backed up, since a second name for one file is
pointless. The replacement link is built under a temporary name and its
resolved target checked before anything active is touched, and the swap itself is a rename — so a
failure part way leaves the old model in place, and no reader ever sees `models/agent/` without
one.

**No switch restarts the backend**, headless or not. From the command line, follow it with
`jenova-core backends restart`.

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

Every forwarded request with a body passes through `src/jenova/pipeline.nim`, and one whose body is
a JSON object carrying a `messages` array is rewritten — `POST /v1/chat/completions` above all, and
the same body on any other forwarded path. The pipeline detects and strips an intent prefix,
**strips** tools for the two intents that gain nothing from them, retrieves context, runs a web
search for the web-search intent, reads the live editor document for the editor intent, injects a
persona, and trims the oldest turns if the conversation no longer fits the context budget. The
rewritten body is then forwarded to `llama-server` on `:8081`.

`POST /infill` and `POST /completion` carry a raw prompt rather than a `messages` array, so there
is nothing to inject into: `pipeline.prepare` returns them untouched and they are forwarded
verbatim.

#### Request header: retrieval scope

`X-Jenova-Scope: folder=<id>;project=<id>;workspace=<id>` limits retrieval to one container of the
workspace tree — a folder's own items, a project and its folders, or a whole workspace. **Without
it, retrieval sees only items that belong to no workspace.** The desktop window sends it for the
open conversation; the Web UI does not, so a Web UI chat inside a workspace does not retrieve that
workspace's notes, files or chats. Any client may send it.

#### Response headers the pipeline adds

Most are emitted only when there is something to report: `X-Jenova-Trimmed`, `-Trimmed-Bytes`,
`-Rag-Hits`, `-Web-Hits`, `-Intent`, `-Editor-Doc` and `-Hit`. But every rewritten chat request
carries `X-Jenova-Msg-Count` and `X-Jenova-Body-Bytes`, and an ordinary turn also carries
`X-Jenova-Sys-Bytes` and `X-Jenova-Injected: persona`, because the persona is a system message the
pipeline injected — so an ordinary turn's response head does change.

| Header | Meaning |
|---|---|
| `X-Cache: HIT` | Answered from the response cache rather than the model |
| `X-Jenova-Trimmed: N` | N oldest turns were dropped to fit the context budget. **The model was not shown the start of this conversation** |
| `X-Jenova-Rag-Hits: N` | N documents were retrieved and injected |
| `X-Jenova-Web-Hits: N` | N web-search results were injected |
| `X-Jenova-Intent: <name>` | An intent prefix was detected and stripped |
| `X-Jenova-Editor-Doc: 1` | A live document was read from Neovim and attached |
| `X-Jenova-Trimmed-Bytes: N` | How many bytes those dropped turns were — the turn count alone does not say whether what was lost was a sentence or a file |
| `X-Jenova-Msg-Count: N` | How many messages were actually sent to the model |
| `X-Jenova-Body-Bytes: N` | The size of the request body as sent |
| `X-Jenova-Sys-Bytes: N` | The size of the system message as sent, counted separately because it is the part the window never typed |
| `X-Jenova-Injected: <names>` | Which standing blocks were joined to the system message. The wire names are `persona`, `rag`, `web` and `editor` — the persona or agent mandate, the retrieved context, the web-search results, and the document read from Neovim — comma-separated and always in that order, so two identical rewrites produce identical bytes. They are a fixed enum (`inspect.InjectedBlock`) rather than free text, because a value that can carry a CRLF is response splitting |
| `X-Jenova-Hit: <score>;<bm25>;<semantic>;<line>;<path>` | One per retrieved chunk, with its scores and the line it starts at. The path is the **retrieval index's own** — `note/<id>`, `file/<id>`, `chat/<convId>/<role>/<id>` — and never a location on disk. It is percent-encoded because it is the first value in this set that is not an integer or a fixed enum, and a raw one could split the header |

**Every header above is what the window's inspector reads** — it calls no pipeline code directly and
displays exactly what it parses off the response, so **anything the inspector can show you is
equally available to any LAN client**, with no authentication in front of it.
A cache hit reports **the request being served**, not the turn that filled the cache:
`upstream.forward` stores the upstream's head from before the diagnostic splice, and on a hit the
server splices in the current request's diagnostic headers, then `X-Cache: HIT`.

### Forwarded to `llama-server` unchanged

**Only these prefixes are forwarded**, and those carrying a `messages` body are rewritten on the
way (above). There is no catch-all relay: `src/jenova/routes.nim` classifies a request from its path
alone. Besides `/health`, `/api/` and the prefixes below, `/debug/` is its own class, answering
`404` unless debug endpoints are enabled. Every other path is static: a `GET` or `HEAD` is served
from `public/` or answered `404` (`403` if the path escapes the root), and any other method gets
`405`.

| Prefix | Goes to |
|---|---|
| `/v1/` (other than `/v1/health` and `/v1/embeddings`), `/completion`, `/infill`, `/chat`, `/props`, `/slots` | inference, `:8081` |
| `/embed`, `/embeddings`, `/v1/embeddings` | embeddings, `:8082` |

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

Every response Jenova builds itself carries `Connection: close`, with no keep-alive, no compression
and no caching headers, and each connection closes after one response. Forwarded inference and
embedding responses, and cache-hit replays, carry `llama-server`'s own response head as it came,
apart from the spliced diagnostic headers.
