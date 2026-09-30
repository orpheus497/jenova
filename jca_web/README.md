# Jenova Web UI

The browser interface for the Jenova Cognitive Architecture — a SvelteKit static SPA served by
the Jenova server on port 8080.

This is a component of the [Jenova monorepo](../README.md). It is not built or deployed on its
own in normal use; `nimble web` from the repository root builds it into `../public/`, which the
Jenova server serves at the same origin as the API.

## Features

**Chat** — streaming responses with tokens/sec and time-to-first-token metrics, branching
conversation history (fork at any message to explore an alternative), `<think>` reasoning-block
support, GFM markdown, KaTeX math, and syntax highlighting.

**Workspaces** — notes, PDFs, images, audio and source files organised into workspaces, projects
and folders. Workspace artifacts in scope are injected into the model's context automatically;
see [`../docs/context-and-retrieval.md`](../docs/context-and-retrieval.md) for exactly what gets
included and when.

**MCP** — Model Context Protocol client for registering external tool servers.

**PWA** — responsive layout for phone and desktop, with the WakeLock API preventing sleep during
long generations.

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | SvelteKit 2 + Svelte 5 runes (`$state`, `$derived`, `$effect`) |
| Components | shadcn-svelte + bits-ui |
| Styling | TailwindCSS 4 |
| Rendering | remark → rehype, KaTeX, highlight.js |
| PDF | pdfjs-dist |
| Protocol | `@modelcontextprotocol/sdk` |
| Testing | Playwright (E2E), Vitest (unit and browser), Storybook |
| Build | Vite + `@sveltejs/adapter-static` |

## Storage

**Persistence is server-side, in SQLite.** Conversations, messages, workspaces, projects,
folders, notes and file assets all live in `~/Jenova/.system/jenova.db`, owned by the server. That
path is `$JCA_HOME/.system/jenova.db` as resolved by `src/jenova/paths.nim`; `JCA_HOME` defaults to
`~/Jenova`. The UI reaches the database through `DatabaseService`, a thin `fetch` wrapper over
`/api/db/*` (`src/lib/services/database.service.ts`).

Clearing browser data does not lose your work. Back up `jenova.db`.

> Some comments in `src/lib/services/index.ts` still describe a Dexie/IndexedDB persistence
> layer. That is stale — Dexie is not a dependency of this package and has been replaced by the
> SQLite-backed API.

## Development

Requires Node and npm, and a running Jenova server (`./bin/jenova` or `./bin/jenova-core serve`)
for anything that touches the API.

```sh
npm install

npm run dev          # dev server on port 5173
npm run build        # production build → ../public/
npm run check        # type checking

npm run test         # everything
npm run test:e2e     # Playwright
npm run test:ui      # Vitest browser
npm run test:unit    # Vitest unit

npm run storybook    # component explorer on http://localhost:6006
```

The production build writes to `../public/`, which the server serves. It does not write to
`build/`.

What to know before relying on the development commands:

- `npm run dev` runs `scripts/dev.sh`, which needs `bash`, and binds `0.0.0.0:5173` — reachable from
  the network, not only `localhost`.
- Its proxy forwards `/v1`, `/api/storage`, `/api/workspaces`, `/api/db`, `/props`, `/models` and
  `/cors-proxy` to `:8080` (`vite.config.ts`). It does not forward `/api/fs`, `/health`, `/embed*`,
  `/infill`, `/completion` or `/slots`, so what uses those fails under the dev server; Jenova's
  server does not answer `/cors-proxy` at all.
- The `ui` test project names `./.storybook/vitest.setup.ts`, and there is no `.storybook/`
  directory, so `npm run test:ui` — and `npm run test`, which starts with it — cannot run as the
  tree stands. In watch mode that project also starts `pnpm run storybook`.

## Diagrams

Mermaid sources under `docs/`, one fenced block per file, no prose:

| File | Covers |
|---|---|
| [`docs/architecture/high-level-architecture.md`](docs/architecture/high-level-architecture.md) | Routes → components → stores → services → storage → APIs |
| [`docs/architecture/high-level-architecture-simplified.md`](docs/architecture/high-level-architecture-simplified.md) | Condensed version of the above |
| [`docs/flows/chat-flow.md`](docs/flows/chat-flow.md) | Message lifecycle: streaming, tool calls, regeneration |
| [`docs/flows/conversations-flow.md`](docs/flows/conversations-flow.md) | Conversation CRUD, branching, import/export |
| [`docs/flows/database-flow.md`](docs/flows/database-flow.md) | Every `DatabaseService` operation through the server to SQLite |
| [`docs/flows/mcp-flow.md`](docs/flows/mcp-flow.md) | MCP registration, connection lifecycle, tool discovery |
| [`docs/flows/server-flow.md`](docs/flows/server-flow.md) | `/props` fetching and MODEL/ROUTER role detection |
| [`docs/flows/settings-flow.md`](docs/flows/settings-flow.md) | Settings load/save, theme, parameter diff and reset |
| [`docs/flows/data-flow-simplified-model-mode.md`](docs/flows/data-flow-simplified-model-mode.md) | Single-model server mode |

> Two further diagrams — `docs/flows/data-flow-simplified-router-mode.md` and
> `docs/flows/models-flow.md` — depict llama.cpp ROUTER-mode `/models/load` and `/models/unload`.
> Jenova launches `llama-server` in single-model mode, and model switching goes through
> `src/jenova/models.nim` plus a backend restart. Those two diagrams describe a path that does not
> currently work.

## Privacy note

**The Web UI downloads no webfont and, until you add an MCP server, contacts no third party.** Once
an MCP server is configured, the UI shows its icon: the server's own when it offers one, otherwise
one from Google's favicon service (`www.google.com/s2/favicons`) for the server's domain
(`src/lib/utils/favicon.ts`, `src/lib/stores/mcp.svelte.ts`) — so the browser asks Google.

Inter and JetBrains Mono are named first in the `--font-*` tokens, so a viewer who has them
installed locally gets them, and everyone else falls through to the platform's own UI and monospace
faces.
If you want them guaranteed, self-host the `.woff2` files under `static/fonts/` and add the
matching `@font-face` rules — both are SIL OFL 1.1, so check that against the project's dependency
policy first. See [`../docs/privacy.md`](../docs/privacy.md).

## License

AGPL-3.0, as part of the Jenova Cognitive Architecture. See [`../LICENSE`](../LICENSE).
