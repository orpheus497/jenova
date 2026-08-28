# Jenova Web UI

The browser interface for the Jenova Cognitive Architecture — a SvelteKit static SPA served by
the intelligence proxy on port 8080.

This is a component of the [Jenova monorepo](../README.md). It is not built or deployed on its
own in normal use; `make web` from the repository root builds it, and `make install` deploys it.

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
folders, notes and file assets all live in `~/JCA/var/jenova.db`, owned by the proxy. The UI
reaches it through `DatabaseService`, which is a thin `fetch` wrapper over `/api/db/*`
(`src/lib/services/database.service.ts`).

Clearing browser data does not lose your work. Back up `jenova.db`.

> Some comments in `src/lib/services/index.ts` still describe a Dexie/IndexedDB persistence
> layer. That is stale — Dexie is not a dependency of this package and has been replaced by the
> SQLite-backed API.

## Development

Requires Node 20+ and npm 10+, and a running Jenova backend (`jenova-ca --daemon`) for anything
that touches the API.

```sh
npm install

npm run dev          # dev server on http://localhost:5173
npm run build        # production build → ../public/
npm run check        # type checking

npm run test         # everything
npm run test:e2e     # Playwright
npm run test:ui      # Vitest browser
npm run test:unit    # Vitest unit

npm run storybook    # component explorer on http://localhost:6006
```

The production build writes to `../public/`, which the proxy serves. It does not write to
`build/`.

## Diagrams

Mermaid sources under `docs/`, one fenced block per file, no prose:

| File | Covers |
|---|---|
| [`docs/architecture/high-level-architecture.md`](docs/architecture/high-level-architecture.md) | Routes → components → stores → services → storage → APIs |
| [`docs/architecture/high-level-architecture-simplified.md`](docs/architecture/high-level-architecture-simplified.md) | Condensed version of the above |
| [`docs/flows/chat-flow.md`](docs/flows/chat-flow.md) | Message lifecycle: streaming, tool calls, regeneration |
| [`docs/flows/conversations-flow.md`](docs/flows/conversations-flow.md) | Conversation CRUD, branching, import/export |
| [`docs/flows/database-flow.md`](docs/flows/database-flow.md) | Every `DatabaseService` operation through the proxy to SQLite |
| [`docs/flows/mcp-flow.md`](docs/flows/mcp-flow.md) | MCP registration, connection lifecycle, tool discovery |
| [`docs/flows/server-flow.md`](docs/flows/server-flow.md) | `/props` fetching and MODEL/ROUTER role detection |
| [`docs/flows/settings-flow.md`](docs/flows/settings-flow.md) | Settings load/save, theme, parameter diff and reset |
| [`docs/flows/data-flow-simplified-model-mode.md`](docs/flows/data-flow-simplified-model-mode.md) | Single-model server mode |

> Two further diagrams — `docs/flows/data-flow-simplified-router-mode.md` and
> `docs/flows/models-flow.md` — depict llama.cpp ROUTER-mode `/models/load` and `/models/unload`.
> Jenova launches `llama-server` in single-model mode, and model switching goes through
> `bin/jenova-model-switch` plus a restart. Those two diagrams describe a path that does not
> currently work.

## Privacy note

The stylesheet at `src/app.css:3` imports Inter and JetBrains Mono from Google Fonts, so a
browser with network access contacts `fonts.googleapis.com` on every page load. This is
inconsistent with the project's local-first intent and is logged as a defect to fix by
self-hosting both families. See [`../docs/privacy.md`](../docs/privacy.md).

## License

AGPL-3.0, as part of the Jenova Cognitive Architecture. See [`../LICENSE`](../LICENSE).
