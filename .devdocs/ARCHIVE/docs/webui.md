# Web UI Architecture

The Jenova Workspace is a browser-based interface for persistent workspaces and
general chat, built as a SvelteKit static SPA served by the intelligence proxy.

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Framework | SvelteKit 2 + Svelte 5 | Reactive UI with runes (`$state`, `$derived`, `$effect`) |
| UI Components | shadcn-svelte + bits-ui | Accessible, composable component library |
| Styling | TailwindCSS 4 | Utility-first CSS with design tokens |
| Database | IndexedDB (Dexie) | Persistent client-side storage for conversations and workspaces |
| Rendering | remark → rehype pipeline | GFM markdown, KaTeX math, syntax highlighting (highlight.js) |
| PDF | pdfjs-dist | In-browser PDF viewing for workspace file assets |
| Protocol | MCP SDK | Model Context Protocol integration |
| Testing | Playwright + Vitest + Storybook | E2E, unit/UI, and visual component testing |
| Build | Vite 6 + adapter-static | Static SPA output to `public/` |

## Architecture

```
Browser ──HTTP──▶ Intelligence Proxy (port 8080) ──▶ llama-server (port 8081)
                  │                                   Embedding server (port 8082)
                  │
                  └── Serves static files from public/
                      (index.html, bundle.js, assets)
```

The WebUI is a **fully static SPA** — no server-side rendering. At build time,
SvelteKit compiles to vanilla HTML/JS/CSS via `@sveltejs/adapter-static`. The
intelligence proxy (`lib/proxy.lua`) serves these files and provides the
OpenAI-compatible API at the same origin, avoiding CORS issues.

## Key Features

- **Workspaces** — create, organise, and manage notes, PDFs, images, audio, and
  source code files. Workspace artifacts are injected into the AI context.
- **Branching History** — fork conversations at any point to explore alternate
  reasoning paths without losing the original thread.
- **Streaming Chat** — real-time token streaming with performance metrics
  (tokens/sec, time to first token).
- **Deep Reasoning** — integrated `<think>` block support for models with
  chain-of-thought reasoning.
- **Cache AG** — client-side response caching for instant retrieval of previous
  exchanges.
- **PWA** — WakeLock API prevents sleep during long generations; fully
  responsive layout for mobile and desktop.
- **Theme** — dark/light mode via `mode-watcher`.

## Data Storage

All user data stays in the browser via IndexedDB (Dexie):

| Store | Contents |
|-------|----------|
| Conversations | Chat messages, branches, metadata |
| Workspaces | Notes, file references, settings |
| Cache | Cached AI responses (Cache AG) |

No server-side database is involved. Clearing browser data removes all
conversations and workspace state.

## Development

```sh
cd jca_web

# Install dependencies
npm install

# Development server (hot-reload)
npm run dev          # → http://localhost:5173

# Production build (outputs to ../public/)
npm run build

# Type checking
npm run check

# Tests
npm run test         # All tests
npm run test:e2e     # Playwright E2E
npm run test:ui      # Vitest browser UI tests
npm run test:unit    # Vitest unit tests

# Storybook (component explorer)
npm run storybook    # → http://localhost:6006
```

The production build is also available via `make web` from the repo root.

## LAN Access

When the backend is started with `jenova-ca --daemon --lan`, the proxy binds to
`0.0.0.0` and the WebUI becomes accessible from other devices on the LAN at
`http://<host-ip>:8080`. This enables mobile phone or secondary PC access
to the full workspace interface.
