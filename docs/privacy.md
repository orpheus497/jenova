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

Four things can reach the network, all deliberate and none of them on by itself.

| What | Where it goes | When |
|---|---|---|
| **Web search** | `api.duckduckgo.com`, `html.duckduckgo.com`, and wherever either redirects | Only when a client message begins with `Web Search:`. Your query text is sent. No model and no button can trigger it |
| **MCP servers** | whichever servers you configure | Web UI only, off by default, and only once you add one. See below |
| **Model downloads** | `huggingface.co` | Only when you fetch a model yourself |
| **Package and source updates** | FreeBSD `pkg` mirrors, `github.com`, the `nimble` registry | Only during `pkg install`, `git clone` and `nimble` builds |

**The Web UI fetches no webfonts.** `jca_web/src/app.css` imported Inter and JetBrains Mono from
`fonts.googleapis.com`, so a browser with network access contacted Google on every page load —
exposing your IP address and the fact that you are running Jenova. That import was removed on
2026-08-31. The font stacks still name both families first, so a viewer who has them installed
locally gets them, and everyone else falls through to the platform's own UI and monospace faces.
Nothing is downloaded either way.

**MCP: not in either binary, but present in the Web UI.** Neither `bin/jenova` nor
`bin/jenova-core` contains an MCP client — there is none under `src/`, the desktop Settings screen
has no MCP section, and `settings.OmittedFields` records the whole section as deliberately
deferred. The `mcpServerOverrides` column exists in the database for the Web UI's sake.

**The Web UI does have one**, in `jca_web/src/lib/services/mcp.service.ts` with its stores and
types, and it is compiled into the `public/bundle.js` this server serves. So if you configure an
MCP server in the browser client, **that server is a real outbound path**: it receives whatever the
model sends it, and the request goes from your browser rather than from Jenova's own process, which
is why it does not appear in the `src/` grep below. It is **off by default and configures nothing
on its own** — the outbound path exists only once you add a server yourself. Nothing in the desktop
window can reach it.

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

Every claim above is checkable. The two DuckDuckGo hosts are the only **non-loopback URL targets**
in the runtime — the only hosts *off this machine* it ever constructs a request for. It builds and
sends one other request, and the qualifier is there because of it: `rag.embed` posts every chunk it
indexes to `http://127.0.0.1:8082/v1/embeddings`, your own embedding server, which is the third row
of the table below and is loopback by construction. Model downloads and package updates are commands
you run, not things it does.

**Redirects are followed, so a request can end at a third host.** `websearch.fetchUrl` runs
`curl -sL` (`-L` follows redirects) or base `fetch(1)`, which follows them too. DuckDuckGo can
therefore hand either client a `Location:` pointing somewhere else and the client will go there,
carrying your query in the URL. Neither is given a host allowlist. In practice the two endpoints
answer directly, but the guarantee this page can honestly make is about the hosts Jenova asks for,
not the hosts a redirect can send it to:

```sh
grep -rn 'https\?://' src/                        # both binaries
grep -rn 'https\?://' jca_web/src/                # Web UI
sockstat -4l | grep -E '8080|8081|8082'           # what is listening — FreeBSD
ss -ltn     | grep -E '8080|8081|8082'           # the same, on Linux
```

The last two are one question asked twice, because Jenova is tuned for FreeBSD but builds and
runs wherever Nim, GTK4 and libadwaita do. Run whichever your machine has; on a host with neither,
`netstat -an` is everywhere. What you should see is three listeners — 8080 on `127.0.0.1` unless
you passed `--lan`, and 8081 and 8082 on `127.0.0.1` whether you did or not.

The first command returns about twenty lines. **Read them; do not filter them.** An earlier version
of this page offered
`grep -rn 'https\?://' src/jenova/*.nim | grep -v '#'` as a way to "narrow it to the two real ones".
It does neither: the glob excludes `src/jenova_core.nim`, which is the one file the fixtures are in,
and `grep -v '#'` drops any line containing a `#` — which would hide a real URL carrying a fragment
just as readily as a comment. The honest version is the full list, accounted for line by line:

| What you will see | Where | What it is |
|---|---|---|
| `html.duckduckgo.com`, `api.duckduckgo.com` | `src/jenova/websearch.nim` | **The two real ones.** The only hosts off this machine the runtime builds a request for |
| `x.example`, `img.example`, `rfc.example`, `i.example` (about a dozen) | `src/jenova_core.nim` | Self-test fixtures for the markdown link renderer. Never fetched — they are compared as strings |
| `http://{host}:{port}/v1/embeddings` | `src/jenova/rag.nim` | The embedding server on **loopback**, `127.0.0.1:8082`. Local by construction |
| `http://127.0.0.1:<port>` | `src/jenova/gui.nim` | What the "Open Web UI" button hands to `xdg-open` — your own server |
| `https://github.com/orpheus497/jenova`, `…/issues` | `src/jenova/version.nim` | The About window's Website and Report an Issue links. Opened **in your browser, when you click them**, never fetched by Jenova |
| `"http://"`, `"https://"` | `src/jenova/markdown.nim` | The scheme allowlist for rendering a link, not a destination |

So **the native runtime** — `bin/jenova` and `bin/jenova-core`, the two binaries this table covers
— sends a request that leaves this machine from exactly one module, `websearch.nim`. The other
module that makes a request at all, `rag.nim`, addresses `127.0.0.1` and cannot reach further. One
non-runtime path exists beside them: two `github.com` links the About window can hand to your
browser on a click.

**That sentence is about the Nim binaries and does not extend to the Web UI.** The browser client
carries its own MCP implementation in `jca_web/src/lib/services/mcp.service.ts`, and once you
configure a server there it sends requests from your browser — a path neither `grep` above reaches,
because it is not in `src/`. It is off until you add a server yourself, and the section *MCP: not
in either binary, but present in the Web UI* above states it in full. Counting modules in `src/`
answers what Jenova's own process does; it does not answer what a page it serves can be configured
to do.
