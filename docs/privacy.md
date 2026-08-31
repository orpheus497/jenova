# Privacy

Jenova is local-first: inference, retrieval and storage all happen on your machine, and there is
no telemetry of any kind. This page states precisely what that does and does not mean.

## What never leaves your machine

- **Every generated token.** Inference runs in `llama-server` on your own GPU or CPU. No prompt,
  completion or embedding is sent to a model provider — there is no provider, and no code path to
  configure one.
- **Your conversations, notes and files.** They live in SQLite at `~/Jenova/var/jenova.db` and as
  Markdown under `~/Jenova/Workspaces`.
- **Your retrieval index.** Embeddings are computed locally by the embedding server and cached in
  `~/Jenova/var/cache`.

No usage data, crash reports or analytics are collected. There is no analytics code in the Web UI.

## What does leave your machine

Four things reach the network. Three are deliberate; one is a defect.

| What | Where it goes | When |
|---|---|---|
| **Web search** | `api.duckduckgo.com`, `html.duckduckgo.com` | Only when a model invokes the web-search tool. Your query text is sent |
| **Model downloads** | `huggingface.co` | Only when you run `scripts/model_dl.sh` or accept the installer's download prompt |
| **Package and source updates** | FreeBSD `pkg` mirrors, `github.com` | Only during `make deps`, `git clone`, and `scripts/update.sh` |
| **Web UI webfonts** ⚠️ | `fonts.googleapis.com`, `fonts.gstatic.com` | **Every Web UI page load**, from your browser |

The webfont import at `jca_web/src/app.css:3` is inconsistent with this project's local-first
intent: it means a browser with network access contacts Google on every load, which exposes your
IP address and the fact that you are using Jenova. It is logged as a defect to fix by
self-hosting the two font families. Until then, a browser extension that blocks the request, or
an offline machine, prevents it; the UI falls back to system fonts.

**MCP servers you configure yourself** are an additional outbound path under your control. A
remote MCP server receives whatever the model sends it.

## No authentication

The proxy on `:8080` has **no authentication**. Access control is the bind address and your
firewall, nothing else.

- Default (`jenova-ca --daemon`) binds `127.0.0.1` — reachable only from this machine.
- `--lan` binds `0.0.0.0` — reachable by **anyone on your network**, with full access to your
  workspaces, files and inference.

Only enable LAN mode on a network you trust, and open only port 8080. Ports 8081 and 8082 always
stay on loopback; exposing them would publish unauthenticated inference endpoints.

## Where your data is

All paths are relative to `$JCA_HOME`, which defaults to `~/Jenova`.

| Path | Contents |
|---|---|
| `var/jenova.db` | Conversations, messages, workspaces, projects, folders, notes, file assets |
| `Workspaces/` | Markdown mirror of notes and chats, plus uploaded file assets |
| `var/cache/` | Embedding index and retrieval snapshots — a semantic index of your content |
| `var/log/` | Daemon logs. May contain prompts, paths and error context |
| `.system/` | PID and lock files |
| `models/` | GGUF model weights |
| `etc/jenova.local.conf` | Your configuration overrides |

To inspect what the system has been doing, read `var/log/`. To wipe derived state without losing
your work, `scripts/cleanup.sh --all` clears logs, cache and stale PID files; the database and
`Workspaces/` are untouched.

## Keeping data out of git

The repository `.gitignore` excludes model weights (`*.gguf`, `*.safetensors`), databases
(`*.sqlite`, `*.db`), `var/log/` and `var/cache/`, runtime state directories, `etc/jenova.local.conf`,
and secrets (`.env`, `*.key`, `*.pem`, `*.token`, `credentials.json`).

Two habits matter anyway:

- Put anything private in `etc/jenova.local.conf`, never in `etc/jenova.conf` — the latter is
  overwritten whenever a hardware profile is applied.
- Your data lives in `~/Jenova`, outside this repository. A `make install` deployment is
  self-contained there and is not affected by anything you do to the source tree.

## Auditing this yourself

Every claim above is checkable. The outbound calls are the only `http` URLs in the runtime:

```sh
grep -rn 'https\?://' lib/ bin/ scripts/          # backend
grep -rn 'https\?://' jca_web/src/                # Web UI
sockstat -4l | grep -E '8080|8081|8082'           # what is actually listening
```
