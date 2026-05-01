# Jenova Master Plan

## Vision

Jenova is a local-first AI coding environment. The **canonical interactive
experience** is `jvim` — the purpose-built Neovim hard-fork. The agent lives
*inside* the editor, not alongside it in a terminal pane. A modernised C-shell
(`mcsh`) and a hardware-aware daemon supervisor (`jenova-ca`) round out the
stack.

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
| `jvim` — editor | ✅ Built in-tree, native UI (statusline, tree, finder, notify, dashboard…) |
| `jvim-config/lua/jenova/` runtime | ✅ chat, monitor, health, LAN discovery, llama.vim FIM |
| **Unified Agent** | ✅ Embedded in jvim (engine + 13 native tools + memory + compactor) |
| `lib/` — backend daemons | ✅ proxy (port 8080), llama-server (8081), embedding (8082), supervisor |
| `bin/jenova` launcher | ✅ starts backend + editor; `--check`, `--no-backend`, `--daemon-only` |
| `mcsh` shell | ✅ Built in-tree from `mcsh/`, installed as `bin/mcsh` |
| Hardware profiles | ✅ AMD APU, Intel dGPU+iGPU, Vulkan dGPU, Optane variants — auto-detected |
| Documentation | ✅ Modularised under `/docs`, reflects shipped features |

---

## Completed Phases

### Phase 1 — Launch Semantics (Done)
- [x] Create `jenova` top-level launcher.
- [x] Refactor `bin/jenova` to start backend + editor.
- [x] Ensure `jvim` works in editor-only mode.

### Phase 2 — Unified Agent (Done)
- [x] Embed agent core in `jvim`.
- [x] Implement native jvim tools (BufferRead/Edit/Write/MultiEdit/Glob/Grep/Ls/List, LSP, Shell, VimCmd, Remember, AskUser).
- [x] Long-term memory (`Remember` + auto-extractors) wired into the system prompt.
- [x] Aggressive token compression for tool schemas and history.

### Phase 3 — Documentation Overhaul (Done)
- [x] De-bloat `README.md`.
- [x] Modular `/docs/` structure (architecture / installation / hardware / usage).
- [x] Port `LINUX.md` to `docs/installation/linux.md`.
- [x] Update all references to reflect the "Unified Agent" state.
- [x] Document `mcsh` and the `jenova-ca` daemon lifecycle.

### Phase 4 — Shell Consolidation (Done)
- [x] Pull `mcsh` (tcsh + etcsh fusion) in-tree under `mcsh/`.
- [x] Wire `make mcsh` into the unified build.
- [x] Build path produces `bin/mcsh` for distribution.

---

## Future Goals

### 1. Installation UI Overhaul
- [ ] Phase banners: `┌─[ 3/7 llama.cpp ]─────────────────────────┐`
- [ ] Per-tool progress lines during LSP install (currently silent bulk)
- [ ] Elapsed-time spinner during cmake builds
- [ ] Explicit hardware-profile match / fallback message with tuning guidance
- [ ] Final summary table: all phases with green / warn / fail per phase
- [ ] Reorder phases: deps → llama → jvim → mcsh → plugins check → models → config
- [ ] Inline `bin/build-llama-jenova` into `install.sh` (no manual pre-step)
- [ ] Inline `scripts/llama_dl.sh` into the first-run install path

### 2. Database & Indexing Strategy
- [ ] Move from `vectors.json` to a more robust store (e.g. `jenova.db` / sqlite + sqlite-vss).
- [ ] "Passive RAG" — editor pushes context based on cursor activity, not just chat turns.
- [ ] Incremental re-index on file save instead of full rescan.

### 3. Enhanced Agent UI
- [ ] `jenova/agent/ui/inline.lua` — inline diff preview before applying edits.
- [ ] Better multi-agent coordination within the editor.
- [ ] First-class "plan mode" UI banner (currently mode toggle only).

### 4. Native Tooling Optimisation
- [ ] Even tighter tool-schema compression for 3B models.
- [ ] Buffer-aware `Grep` that prefers open buffers over disk re-reads.
- [ ] LSP tool: code actions + rename, not just hover / definition / references.

### 5. mcsh Integration
- [ ] Optional `mcsh` prompt module that surfaces backend health (proxy up / down).
- [ ] Shell completion for `jenova-ca` verbs / flags.
