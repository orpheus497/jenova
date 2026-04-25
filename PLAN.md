# Jenova Master Plan

## Vision

Jenova is a local-first AI coding environment. The **canonical interactive experience** is
`jvim` — the purpose-built Neovim hard-fork. The agent lives *inside* the editor, not
alongside it in a terminal pane.

```
jenova          → starts backend daemons + jvim (full environment)
jvim            → starts ONLY the editor (no backend management)
bin/jenova-ca   → starts ONLY the backend daemons (headless / server use)
bin/jenova      → Scripted / one-shot agent interaction
```

---

## Current State

| Component | Status |
|---|---|
| `jvim` — editor | ✅ Built in-tree, native UI (statusline, tree, finder, notify…) |
| `jenova/` runtime plugins | ✅ chat, monitor, health, LAN discovery, llama.vim FIM |
| **Unified Agent** | ✅ Embedded in jvim |
| `lib/` — backend daemons | ✅ proxy, embedding server, daemon supervisor |
| `bin/jenova` launcher | ✅ starts backend + editor |
| **Documentation** | ✅ Modularized and Restructured in `/docs` |

---

## Completed Phases

### Phase 1 — Launch Semantics (Done)
- [x] Create `jenova` top-level launcher.
- [x] Refactor `bin/jenova` to start backend + editor.
- [x] Ensure `jvim` works in editor-only mode.

### Phase 2 — Unified Agent (Done)
- [x] Embed agent core in `jvim`.
- [x] Implemented native jvim tools (LSP, Buffers).

### Phase 3 — Documentation Overhaul (Done)
- [x] De-bloated `README.md`.
- [x] Created modular `/docs/` structure.
- [x] Ported `LINUX.md` to `docs/installation/linux.md`.
- [x] Updated all references to reflect the "Unified Agent" state.

---

## Future Goals

### 1. Installation UI Overhaul
- [ ] Phase banners: `┌─[ 3/7 llama.cpp ]─────────────────────────┐`
- [ ] Per-tool progress lines during LSP install (currently silent bulk)
- [ ] Elapsed-time spinner during cmake builds
- [ ] Explicit hardware profile match/fallback message with tuning guidance
- [ ] Final summary table: all 7 phases with green/warn/fail per phase
- [ ] Reorder install phases: deps → llama → jvim → plugins check → models → config
- [ ] Inline `build-llama-jenova` into `install.sh` (no manual pre-step required)
- [ ] Standardise `--skip-nvim` everywhere (remove `--skip-config` alias)
- [ ] Fix README: remove dead `make cli-agent` / `make sync-modules` references

### 2. Database & Indexing Strategy
- [ ] Research how to move from `vectors.json` to a more robust format (e.g., `jenova.db`).
- [ ] Investigate "Passive RAG" — editor pushes context based on cursor activity.

### 2. Enhanced Agent UI
- [ ] `jenova/agent/ui/inline.lua` — inline diff preview before applying edits.
- [ ] Better multi-agent coordination within the editor.

### 3. Native Tooling Optimization
- [ ] Aggressive token compression for tool schemas.
- [ ] More robust buffer-aware `Grep`.
