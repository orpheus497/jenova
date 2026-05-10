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
| `bin/jenova-tui` | ✅ Manager UI: Status, LAN toggle, App Launching. |
| **Persistence** | ✅ `~/Workspaces` device-level sync (Web UI ↔ Editor). |
| `mcsh` shell | ✅ Built in-tree from `mcsh/`, installed as `bin/mcsh`. |
| Hardware profiles | ✅ Auto-detected (AMD, Intel, Vulkan, Optane). |

---

## Completed Phases

### Phase 1 — Launch & Management (Done)
- [x] Create `jenova` top-level launcher.
- [x] Create `jenova-tui` (Manager) with LAN/Local toggle.
- [x] Multi-terminal desktop integration (`.desktop` files).
- [x] Ensure `jvim` works in editor-only mode.

### Phase 2 — Unified Agent (Done)
- [x] Embed agent core in `jvim`.
- [x] Implement 13 native jvim tools.
- [x] Long-term memory (`Remember` + auto-extractors).

### Phase 3 — Ecosystem & Persistence (Done)
- [x] Lore-cleansing: removed "trinity" and "4-part" branding.
- [x] Filesystem storage API: `~/Workspaces` sync.
- [x] Web UI ↔ jvim data interoperability via Markdown.

### Phase 4 — Shell & Documentation (Done)
- [x] Pull `mcsh` (tcsh + etcsh fusion) in-tree under `mcsh/`.
- [x] Wire `make mcsh` into the unified build.
- [x] Modular `/docs/` structure.

---

## Future Focus

### 1. Installation & UX Refinement
- [ ] Improved progress indicators during builds.
- [ ] Explicit hardware-profile match summary.
- [ ] `mcsh` prompt module that surfaces backend health.
