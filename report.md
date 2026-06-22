# Codebase Comparison Report: origin/main vs HEAD

This report details the differences, feature losses, and problematic cases introduced in the current branch compared to `origin/main`, specifically focusing on the installation process.

## 1. Feature / Functional Losses
* **Removal of Update and Uninstall scripts:** `scripts/update.sh` and `scripts/uninstall.sh` have been completely removed. This breaks the ability to easily maintain the installation after the initial setup. `install-jenova.sh` also lost its `update` and `uninstall` commands.
* **Removal of Desktop build script:** `scripts/build-desktop.sh` is gone.
* **Removal of Cleanup script:** `scripts/cleanup.sh` is gone.
* **Loss of Web UI sub-components:** `external/llama.cpp/tools/server/webui/` seems completely removed from the branch, along with components in `external/llama.cpp`. This implies a massive reduction in the scope of `llama.cpp` bundled tools or a botched submodule update.
* **Loss of GPU tests:** `tests/test_gpu.sh` and `tests/test_gpu_single.sh` have been removed.

## 2. Problematic Cases in Installation Process
* **Makefile changes:** The `Makefile` no longer builds `llama-server` by default under the `all` or `install` targets. It relies on the user or the install script to build it if missing. `make llama` now calls `bin/build-llama` instead of `bin/build-llama-jenova`, but `bin/build-llama` has changed its backend default to `hybrid` instead of `vulkan`.
* **Bin directory restructuring:** The script `bin/build-llama-jenova` was renamed to `bin/build-llama`. A bunch of pre-compiled binaries like `bin/llama-server` and `bin/llama-speculative` were added directly to the git tree, which is generally bad practice and bloats the repository.
* **`install-jenova.sh` changes:**
    * The script no longer builds the web component by default if `MINIMAL` is not set, as the underlying `make install` target was changed to not include `llama`.
    * It passes fewer components to `install.sh` by removing `llama` and conditionally `web` from the `COMPONENTS` loop, meaning `install.sh` handles more of the logic or it's skipped.
* **`scripts/install.sh` regressions:**
    * It expects `llama-server` to be built and present in `bin/llama-server` or `external/llama.cpp/build/bin/llama-server`.
    * If `llama-server` is missing, it now prompts interactively: `Initialize submodule and build from source? [y/N]`. This breaks non-interactive installations unless `llama-server` is pre-built.
    * The script copies the `llama-server` from `JENOVA_ROOT/bin/llama-server` instead of strictly building it, relying on the pre-compiled binaries in the repo.
    * It removes the `share/jvim/mason` directory creation and copying, potentially breaking language server setups.
    * It removed the copying of `scripts/` into `JENOVA_HOME`, meaning the deployed version will not have any management scripts.
* **`scripts/jenova-manager.sh` changes:**
    * The manager script was heavily modified to remove update and uninstall functionality from the UI, corresponding to the deleted scripts.

## Conclusion
The current branch introduces significant regressions by removing lifecycle scripts (update, uninstall, cleanup), pushing pre-compiled binaries into the repository, and altering the build/install process to be more fragile and less comprehensive. The interactive prompt added to `install.sh` breaks automated setups, and the removal of the Web UI tools from the `llama.cpp` submodule indicates a potentially broken or heavily truncated dependency.
