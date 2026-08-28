# ARCHIVE

Nothing here is deleted. These files were removed from the product tree during the
FreeBSD-only migration and consolidation, and are kept as the reference source until that
work is proven complete.

**Restore any file with:**

```sh
git mv .devdocs/ARCHIVE/<path> <original-path>
```

Git history is preserved across the move, so `git log --follow` works on the restored file.

---

## Contents

### `scripts/`

| File | Why it moved | What does its job now |
|---|---|---|
| `build-desktop.sh` | Checked for GTK/appindicator/ncurses/luajit and **built nothing**, despite the name. Pure duplication. | `scripts/install-dependencies.sh` |
| `preflight-check.sh` | "Check dependencies before building" collapses into "install dependencies" once dependencies are mandatory. Its checks duplicated `install.sh` and `install-dependencies.sh`. | `scripts/install-dependencies.sh`, run automatically by `gmake deps` |
| `jenova-manager.sh` | 738-line TUI menu wrapping build/install/update operations, duplicating both the Makefile and the ncurses TUI in `jenova-ui`. | `gmake` for build tasks, `jenova-tui` for operations |

### `root/`

| File | Why it moved | What does its job now |
|---|---|---|
| `install-jenova.sh` | Orchestrator that duplicated the Makefile and called it back circularly — `Makefile` had an `install-jenova` target that ran this script, which then ran `gmake`. | `gmake`, `gmake install` |

### `docs/`

| File | Why it moved | What does its job now |
|---|---|---|
| `STREAMLINED.md` | Install guide duplicating `docs/installation/freebsd.md`; marked ⚠️ stale in the doc index, and documented flags the installer never parsed. | `docs/installation/freebsd.md` |
| `checklist.md` | Checkbox walkthrough of the same install; marked ⚠️ stale; referenced hardware-profile paths and config paths that do not exist. | `docs/installation/freebsd.md` |
| `CHANGELOG-install.md` | Not a changelog — no versions, dates or chronology. A one-time pull-request summary with three wrong file sizes, marked ⚠️ stale, and documenting four installer flags that were never implemented. | nothing; it described a past PR |

---

## Moved, not archived

`bin/build-llama-jenova` → `scripts/build-llama.sh`. It is a build script and `bin/` holds
runtime binaries; `install.sh` never deployed it. Still in the product tree, just in the right
place.

---

## Not in this archive

Files removed *before* the archive rule was set are in git history at the commit prior to the
migration, not here:

- `lib/linux-tune.sh`, `tests/test_linux_tune_regex.sh`
- `docs/installation/linux.md`, `docs/installation/macos.md`
- `hardware-profiles/macOS/` (2 profiles, 6 files)
- `hardware-profiles/Linux/AMD/apu/ryzen7-5700u-3b` (3 files)
- `hardware-profiles/Linux/Vulkan/dgpu/gtx-1650ti` (3 files)
