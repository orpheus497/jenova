# Privacy

Jenova is local-first: inference, retrieval and storage all happen on your machine, and there is
no telemetry of any kind. This page states precisely what that does and does not mean.

## What never leaves your machine

- **Every generated token.** Inference runs in `llama-server` on your own GPU or CPU. No prompt,
  completion or embedding is sent to a model provider — there is no provider, and no code path to
  configure one.
- **Your conversations, notes and files.** They live in SQLite at `~/Jenova/.system/jenova.db` and
  as Markdown under `~/Jenova/Workspaces`.
- **Your retrieval index.** Embeddings are computed locally by the embedding server on `:8082` and
  stored in the same database.

No usage data, crash reports or analytics are collected. There is no analytics code in the Web UI.

## What does leave your machine

Three things reach the network, all deliberate.

| What | Where it goes | When |
|---|---|---|
| **Web search** | `api.duckduckgo.com`, `html.duckduckgo.com` | Only when a model invokes the web-search tool. Your query text is sent |
| **Model downloads** | `huggingface.co` | Only when you fetch a model yourself |
| **Package and source updates** | FreeBSD `pkg` mirrors, `github.com`, the `nimble` registry | Only during `pkg install`, `git clone` and `nimble` builds |

**The Web UI fetches no webfonts.** `jca_web/src/app.css` imported Inter and JetBrains Mono from
`fonts.googleapis.com`, so a browser with network access contacted Google on every page load —
exposing your IP address and the fact that you are running Jenova. That import was removed on
2026-08-31. The font stacks still name both families first, so a viewer who has them installed
locally gets them, and everyone else falls through to the platform's own UI and monospace faces.
Nothing is downloaded either way.

**MCP is not implemented.** The Settings screen has no MCP section and neither binary contains an
MCP client, so a configured remote MCP server is not an outbound path here — it is not a path at
all. The `mcpServerOverrides` column exists in the database only because the schema is shared with
the frozen Web UI. If MCP is ever added, a remote server would receive whatever the model sends it,
and this page will have to say so.

## No authentication

The server on `:8080` has **no authentication**. Access control is the bind address and your
firewall, nothing else.

- Default (`jenova`, or `jenova-core serve`) binds `127.0.0.1` — reachable only from this machine.
- `--lan` binds `0.0.0.0` — reachable by **anyone on your network**, with full access to your
  workspaces, files and inference.

Only enable LAN mode on a network you trust, and open only port 8080. Ports 8081 and 8082 always
stay on loopback; exposing them would publish unauthenticated inference endpoints.

## Where your data is

All paths are relative to `$JCA_HOME`, which defaults to `~/Jenova`.

| Path | Contents |
|---|---|
| `.system/jenova.db` | Conversations, messages, workspaces, projects, folders, notes, file assets |
| `Workspaces/` | Markdown mirror of notes and chats, plus uploaded file assets |
| `var/cache/` | Cache directory |
| `var/log/` | Daemon logs. May contain prompts, paths and error context |
| `.system/` | The database, pid files and the Neovim socket |
| `models/` | GGUF model weights |
| `etc/jenova.local.conf` | Your configuration overrides |

To inspect what the system has been doing, read `var/log/`. Removing `var/log/`, `var/cache/` and
any stale pid file under `.system/` wipes derived state without touching the database or
`Workspaces/`.

## Keeping data out of git

The repository `.gitignore` excludes model weights (`*.gguf`, `*.safetensors`), databases
(`*.sqlite`, `*.db`), `var/log/` and `var/cache/`, runtime state directories, `etc/jenova.local.conf`,
and secrets (`.env`, `*.key`, `*.pem`, `*.token`, `credentials.json`).

Two habits matter anyway:

- Put anything private in `etc/jenova.local.conf`, never in `etc/jenova.conf` — the latter is
  overwritten whenever a hardware profile is applied.
- Your data lives in `~/Jenova`, outside this repository, and is not affected by anything you do
  to the source tree.

## Auditing this yourself

Every claim above is checkable. The two DuckDuckGo hosts are the only ones the runtime itself ever
contacts — model downloads and package updates are commands you run, not things it does:

```sh
grep -rn 'https\?://' src/                        # both binaries
grep -rn 'https\?://' jca_web/src/                # Web UI
sockstat -4l | grep -E '8080|8081|8082'           # what is actually listening
```

The first command returns more than two hosts, and all the extras are inert:

| What you will also see | Where | What it is |
|---|---|---|
| `x.example`, `img.example`, `rfc.example` (about a dozen) | `src/jenova_core.nim` | Self-test fixtures for the markdown link renderer |
| `https://host/a_b_c` | `src/jenova/markdown.nim` | An example inside a comment |

`grep -rn 'https\?://' src/jenova/*.nim | grep -v '#'` narrows it to the two real ones. Neither
fixture is ever fetched: nothing in the runtime performs an outbound request except
`websearch.nim`.
