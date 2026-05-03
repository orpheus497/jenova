# Jenova Master Plan

## Vision

Jenova is a local-first AI coding environment. The interactive experience is
`jvim` — the purpose-built Neovim hard-fork. The agent lives *inside* the
editor, not alongside it in a terminal pane. A modernised C-shell (`mcsh`)
and a hardware-aware daemon supervisor (`jenova-ca`) round out the stack.

```
jenova          → starts backend daemons + jvim (full environment)
jvim            → starts ONLY the editor (no backend management)
bin/jenova-ca   → starts ONLY the backend daemons (headless / server / LAN)
bin/jenova      → top-level launcher (also supports --check / --daemon-only)
bin/mcsh        → Modern C Shell (tcsh+etcsh fusion, drop-in replacement)
```

---

## Current State

| Component | Status |
|-----------|--------|
| `jvim` — editor | ✅ Built in-tree, native UI suite. |
| `jvim-config/` runtime | ✅ chat, monitor, health, LAN discovery, llama.vim FIM. |
| **Unified Agent** | ✅ Embedded in jvim (engine + 13 native tools). |
| `lib/` — backend | ✅ proxy (8080), llama-server (8081), embedding (8082). |
| `bin/jenova` launcher | ✅ starts backend + editor; `--check`, `--no-backend`. |
| `mcsh` shell | ✅ Built in-tree from `mcsh/`, installed as `bin/mcsh`. |
| Hardware profiles | ✅ Auto-detected (AMD, Intel, Vulkan, Optane). |
| Documentation | ✅ Lore-cleansed, factual, and modularised under `/docs`. |

---

## Completed Phases

### Phase 1 — Launch Semantics (Done)
- [x] Create `jenova` top-level launcher.
- [x] Refactor `bin/jenova` to start backend + editor.
- [x] Ensure `jvim` works in editor-only mode.

### Phase 2 — Unified Agent (Done)
- [x] Embed agent core in `jvim`.
- [x] Implement 13 native jvim tools (BufferRead/Edit/Write, LSP, Shell, etc.).
- [x] Long-term memory (`Remember` + auto-extractors).
- [x] Aggressive token compression for tool schemas.

### Phase 3 — Documentation Overhaul (Done)
- [x] Lore-cleansing: removed "trinity" and "4-part" branding.
- [x] Modular `/docs/` structure (architecture / installation / hardware / usage).
- [x] Corrected all references to reflect the "Unified Agent" state.

### Phase 4 — Shell Consolidation (Done)
- [x] Pull `mcsh` (tcsh + etcsh fusion) in-tree under `mcsh/`.
- [x] Wire `make mcsh` into the unified build.

---

## Future Focus

### 1. Installation UI Refinement
- [ ] Improved progress indicators during builds.
- [ ] Elapsed-time spinner for long-running tasks.
- [ ] Explicit hardware-profile match summary.

### 2. Database & Indexing Strategy
- [ ] Move from `vectors.json` to a more robust store (e.g. SQLite + VSS).
- [ ] "Passive RAG" — editor pushes context based on cursor activity.
- [ ] Incremental re-index on file save.

### 3. Enhanced Agent UI
- [ ] `jenova/agent/ui/inline.lua` — inline diff preview before applying edits.
- [ ] Better multi-agent coordination within the editor.

### 4. Native Tooling Optimisation
- [ ] Even tighter tool-schema compression for 3B models.
- [ ] Buffer-aware `Grep` that prefers open buffers over disk.
- [ ] LSP tool: code actions + rename.

### 5. macOS & Platform Support
- [ ] Accurate macOS Metal backend detection and reporting in build/daemon scripts.
- [ ] Ensure manager script compatibility with Bash 3.2 (macOS default) by replacing Bash 4.0+ parameter transformations with portable alternatives.
- [ ] Optional `mcsh` prompt module that surfaces backend health.
- [ ] Shell completion for `jenova-ca` verbs / flags.
