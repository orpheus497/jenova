# Privacy

Jenova is local-first: inference, retrieval and storage all happen on your machine, and there is
no telemetry of any kind. This page states precisely what that does and does not mean.

## What never leaves your machine

- **Every generated token.** Inference runs in `llama-server` on your own GPU or CPU. No prompt,
  completion or embedding is sent to a model provider — there is no provider, and no code path to
  configure one.
- **Your conversations, notes and files.** They live in SQLite at `~/Jenova/.system/jenova.db`.
  The server mirrors notes and uploaded files under `~/Jenova/Workspaces`, and the Web UI writes its
  own chats there as Markdown too; the desktop window writes a chat only when you export it.
- **Your retrieval index.** Embeddings are computed locally by the embedding server on `:8082` and
  stored in the same database.

No usage data, crash reports or analytics are collected. There is no analytics code in the Web UI.

## What does leave your machine

These are the paths that can reach the network. None of the runtime ones is on by itself.

| What | Where it goes | When |
|---|---|---|
| **Web search** | `html.duckduckgo.com`, then `api.duckduckgo.com` if that finds nothing, and wherever either redirects | Only when your last message begins with `Web Search:` (leading spaces ignored). Your query text is sent. No model can trigger it; the desktop window's Send menu can put the prefix in the draft, and the search runs only when you send it |
| **MCP servers** | whichever servers you configure | Web UI only, off by default, and only once you add one. See below |
| **MCP server icons** | `www.google.com/s2/favicons` | Web UI only: when a server you configured reports no icon of its own, its domain is looked up there, from your browser |
| **Images in replies** | wherever the image points | Web UI only: an `http(s)` image in a model's Markdown reply is fetched by your browser to display it. The desktop window shows such an image as a link instead |
| **The Web UI's "Server URL" setting** | the host you enter | Empty by default. When set, the Web UI sends its model-list, model load/unload and `/props` requests there; chat still goes to the server that served the page |
| **Links you click in the desktop window** | the link's address | A link in a message, model-written ones included, is clickable; Jenova connects no handler, so GTK's default opens it in your browser |
| **The bundled editor's LAN scan** | your local network | When Neovim runs the in-repo `jvim/` configuration *outside* the desktop window and no local Jenova server answers, or when you run `:JenovaLanScan`: it probes each local IPv4 network (clamped to /16, at most 1024 addresses per network) on port 8080, then asks port 8081 `/health` with `curl`. `JENOVA_LAN_SCAN=0` turns the automatic scan off. Inside the window the editor is pointed at the local server and does not scan |
| **Model downloads** | `huggingface.co` | Only when you fetch a model yourself |
| **Building and testing** | your OS's package mirrors, `github.com`, the npm registry, DuckDuckGo | `pkg install` or your distribution's package manager; `git clone` and `nimble` (which fetches owlkettle); `nimble web` (runs `npm install`); `nimble suites` (its `pipeline-selftest` sends one real `Web Search:` query). `nimble llama` turns off the llama.cpp build's download of its web UI from `huggingface.co` (`LLAMA_USE_PREBUILT_UI=OFF`), and the build embeds no UI |

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
- LAN mode binds `0.0.0.0` — reachable by **anyone on your network**, with full access to your
  workspaces, files and inference. `jenova-core serve --lan` turns it on; the desktop window has no
  `--lan` flag and binds `0.0.0.0` at start-up when its LAN toggle is on (the flag file
  `.system/lan_mode`); and either program binds it when `HOST` resolves to `0.0.0.0`, for example
  with `JENOVA_HOST=0.0.0.0`.

Only enable LAN mode on a network you trust, and open only port 8080. Ports 8081 and 8082 always
stay on loopback; exposing them would publish unauthenticated inference endpoints. Port 8080 relays
embedding requests (`/embed*`, `/v1/embeddings`) to 8082, so in LAN mode those are reachable too.

## Where your data is

All paths are relative to `$JCA_HOME`, which defaults to `~/Jenova`.

| Path | Contents |
|---|---|
| `.system/jenova.db` | Conversations, messages, workspaces, projects, folders, notes, file assets |
| `Workspaces/` | The server's Markdown mirror of notes, and uploaded file assets. The Web UI also writes its chats here as Markdown, and its Push writes a `jenova-snapshot.json` of the whole database; the desktop window writes a chat only when you export it, to a path you choose |
| `var/cache/` | Cache directory |
| `var/log/` | Daemon logs. May contain prompts, paths and error context |
| `.system/` | The database; the backends' pid files (`llama-server.pid`, `llama-embed.pid`) and their `.lock` files; the Neovim socket; the desktop settings (`settings.json`); the LAN flag (`lan_mode`); the editor colour scheme (`styles/`). The self-test commands also create scratch databases here |
| `models/` | GGUF model weights |
| `etc/jenova.local.conf` | Your configuration overrides — read from here only once a hardware profile has been applied (`etc/jenova.conf` exists here); until then both files are read from `etc/` in the source tree |

To inspect what the system has been doing, read `var/log/`. Removing `var/log/`, `var/cache/` and
any stale pid file under `.system/` wipes derived state without touching the database or
`Workspaces/`.

## Keeping data out of git

The repository `.gitignore` excludes model weights (`*.gguf`, `*.safetensors`), databases
(`*.sqlite`, `*.db`), `var/log/` and `var/cache/`, runtime state directories, `etc/jenova.local.conf`,
and secrets (`.env`, `*.key`, `*.pem`, `*.token`, `credentials.json`).

Two habits matter anyway:

- Put anything private in a `jenova.local.conf`, never in a `jenova.conf`. Applying a hardware
  profile overwrites `$JCA_HOME/etc/jenova.conf` — not the source tree's — and from then on
  configuration is read from `$JCA_HOME/etc/`, so private overrides belong in
  `$JCA_HOME/etc/jenova.local.conf`. Until a profile is applied, the source tree's
  `etc/jenova.local.conf` (which git ignores) is the one read. Neither `jenova.local.conf` is ever
  overwritten.
- Your data lives in `~/Jenova`, outside this repository, and is not affected by anything you do
  to the source tree.

## Auditing this yourself

Every claim above is checkable. The two DuckDuckGo hosts are the only **non-loopback URL targets**
in the runtime — the only hosts *off this machine* it ever constructs a request for. It builds one
other URL, and the qualifier is there because of it: `rag.embed` posts to
`http://127.0.0.1:<LLAMA_EMBED_PORT>/v1/embeddings` (8082 by default) — your own embedding server,
for every chunk it indexes and every retrieval query — which is the third row of the table below and
is loopback by construction. Its other requests go over raw sockets, all to `127.0.0.1`: the relay to
`:8081` and `:8082`, the desktop window's requests to its own server, and the backend health and
port probes. Model downloads and package updates are commands you run, not things it does.

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

The last two are one question asked twice, because Jenova runs on both FreeBSD and Linux. Run
whichever your machine has; on a host with neither, `netstat -an` is everywhere. What you should see
is three listeners — 8080 on `127.0.0.1` unless LAN mode is on (`serve --lan`, the window's LAN
toggle, or `HOST` resolving to `0.0.0.0`), and 8081 and 8082 on `127.0.0.1` either way.

The first command returns 28 lines. **Read them; do not filter them.** An earlier version
of this page offered
`grep -rn 'https\?://' src/jenova/*.nim | grep -v '#'` as a way to "narrow it to the two real ones".
It does neither: the glob excludes `src/jenova_core.nim`, which is the one file the fixtures are in,
and `grep -v '#'` drops any line containing a `#` — which would hide a real URL carrying a fragment
just as readily as a comment. The honest version is the full list, accounted for line by line:

| What you will see | Where | What it is |
|---|---|---|
| `html.duckduckgo.com`, `api.duckduckgo.com` | `src/jenova/websearch.nim` | **The two real ones.** The only hosts off this machine the runtime builds a request for |
| `x.example`, `img.example`, `rfc.example`, `i.example` (14 lines), `e.example` (6 lines), and one comment line | `src/jenova_core.nim` | Self-test fixtures for the markdown link renderer and, for `e.example`, its handling of maths. Never fetched — they are compared as strings |
| `http://{host}:{port}/v1/embeddings` | `src/jenova/rag.nim` | The embedding server on **loopback**, `127.0.0.1`, port `LLAMA_EMBED_PORT` (8082 by default). Local by construction |
| `http://127.0.0.1:<port>` | `src/jenova/gui.nim` | What the "Open Web UI" button hands to `xdg-open` — your own server |
| `https://github.com/orpheus497/jenova`, `…/issues` | `src/jenova/version.nim` | The About window's Website and Report an Issue links. Opened **in your browser, when you click them**, never fetched by Jenova |
| `"http://"`, `"https://"` | `src/jenova/markdown.nim` | The scheme allowlist for rendering a link, not a destination |

So **the native runtime** — `bin/jenova` and `bin/jenova-core`, the two binaries this table covers
— sends a request that leaves this machine from exactly one module, `websearch.nim`. The other
modules that make requests — `rag.nim` (embeddings), `upstream.nim` (the relay to the backends),
`gui.nim` (the window's chat stream and `/props` to its own server) and `lifecycle.nim` (health and
port probes) — all address `127.0.0.1` and cannot reach further. Beside them, your browser can be
handed an address on a click: the About window's two `github.com` links, and any link in a message
the desktop transcript renders. "Open Web UI" hands `xdg-open` your own server's loopback address.

**That sentence is about the Nim binaries and does not extend to the Web UI.** The browser client
carries its own MCP implementation in `jca_web/src/lib/services/mcp.service.ts`, and once you
configure a server there it sends requests from your browser — a path neither `grep` above reaches,
because it is not in `src/`. It is off until you add a server yourself, and the section *MCP: not
in either binary, but present in the Web UI* above states it in full. Counting modules in `src/`
answers what Jenova's own process does; it does not answer what a page it serves can be configured
to do.
