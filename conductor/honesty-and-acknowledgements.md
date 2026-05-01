# Plan: Project Identity, UI, and Installer Overhaul

This plan addresses project identity (honesty and acknowledgements), UI improvements for AI interaction, and a structural overhaul of the build/install system to de-bloat the root directory and organize `mcsh` integration.

## Objective
- Update documentation to credit origins (Neovim, llama.cpp, tcsh, etc.) and state the "enhancement" philosophy.
- Decouple `JVIM` version (v0.1.0) from the `Neovim` baseline (v0.13.0) without breaking plugin compatibility.
- Fix UI text wrapping and window sizing for AI clarifying questions and notifications.
- De-bloat the project root by moving `mcsh` build artifacts into a dedicated folder.
- Update the Jenova installer and root `Makefile` to handle `mcsh` as an organized component.

## Key Files & Context
- `README.md`: Root project documentation.
- `jvim/`: Editor source (CMake, C, Lua).
- `mcsh/`: Separate shell repository (Autotools).
- `Makefile`: Root Jenova build system.
- `scripts/install.sh`: Jenova installation script.
- `lib/prompts.lua`: AI system prompts.

## Implementation Steps

### 1. Project Identity & Philosophy
- **Root `README.md`**:
    - Add **Philosophy** section (Enhancement vs. Competition).
    - Add **Acknowledgements** (Neovim, llama.cpp, tcsh, etc.).
- **`jvim/PLUGINS.md`**:
    - Add a "Gratitude" section naming the plugins that inspired the native Lua UI modules.

### 2. Honest Versioning (Plugin-Safe)
- **`jvim/CMakeLists.txt`**:
    - Define `JVIM_VERSION` as 0.1.0.
    - Keep `NVIM_VERSION` at 0.13.0 for baseline checks.
- **`jvim/src/nvim/version.c`**:
    - Update `NVIM_VERSION_MEDIUM` and the startup banner to report: `"JVIM v0.1.0 (based on Neovim v0.13.0)"`.
    - Implement `has_jvim_version()` to allow baseline-agnostic version checks.
- **`jvim/src/nvim/eval/funcs.c`**:
    - Update `has()` to support `jvim-` prefix version checks.

### 3. UI Improvements
- **`jvim/runtime/lua/jvim/ui.lua`**:
    - Update `vim.ui.input` to handle multi-line prompts by wrapping them inside the window body instead of the title bar.
    - Dynamically adjust window height based on prompt length.
- **`jvim/runtime/lua/jvim/notify.lua`**:
    - Enable text wrapping for all notifications to ensure long AI responses are readable.

### 4. Build System & Installer Overhaul (De-bloating)
- **Root Makefile Update**:
    - Add a `mcsh` target to the top-level `Makefile`.
    - Configure `mcsh` to build in a dedicated directory (e.g., `mcsh/build/`) to keep the root clean.
    - Copy the final binary to `bin/mcsh`.
- **Root Cleanup**:
    - Remove all `mcsh`-related build artifacts currently bloating the root (`*.o`, `config.*`, `atconfig`, `atlocal`, etc.).
- **`scripts/install.sh` Update**:
    - Add logic to install `mcsh` and its compatibility symlinks (`tcsh`, `csh`) to the user's bin directory.
    - Ensure all Jenova components are deployed to organized paths.

## Verification & Testing
- **Identity**: Verify `jvim --version` and `:version` output. Check `README.md` updates.
- **Compatibility**: Verify `has('nvim-0.13')` and `has('jvim-0.1')` both return true.
- **UI**: Trigger long AI questions and verify they wrap and resize the input window correctly.
- **Build/Install**: 
    - Run `make clean` and verify root is clean.
    - Run `make all` and verify `mcsh` builds in its subdirectory.
    - Run `make install` and verify `mcsh` symlinks are created.
