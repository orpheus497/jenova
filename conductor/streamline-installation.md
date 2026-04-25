# Plan: Streamline Installation and Fix Hardware Profile Integration

This plan addresses the installation failures on FreeBSD by unifying the installation logic, fixing hardware profile priority, and resolving permission/tooling conflicts.

## Objective
- Streamline `make install` to correctly handle FreeBSD-specific requirements (`gmake`).
- Ensure hardware profiles are applied *before* model checks so the correct models (e.g., 3B vs 7B) are identified.
- Clean up legacy installer scripts that conflict with the unified system.
- Resolve permission issues caused by accidental `sudo` usage.

## Key Files & Context
- `scripts/install.sh`: The primary installer script.
- `Makefile`: Root build system entry point.
- `hardware-profiles/`: Contains hardware-specific configurations.
- `jvim/build/`: Destination for the bundled editor build.

## Proposed Solution

### 1. Hardware-First Installation Flow
Modify `scripts/install.sh` to move hardware detection to the very beginning. This ensures that the variables defined in the hardware profile's `jenova.conf` (like the specific model choice) are active before the user is prompted to download anything.

### 2. FreeBSD Tooling Alignment
Update the root `Makefile` to detect the host OS. If running on FreeBSD, it will prioritize `gmake` for the `jvim` target, ensuring compatibility with the in-tree Neovim fork's build system.

### 3. Cleanup of Legacy Installers
Remove the `install.sh` scripts from within `hardware-profiles/` subdirectories. These are outdated and cause confusion/permission issues when run with `sudo`.

### 4. Permission & Safety Guards
Add logic to `scripts/install.sh` to detect if the `jvim/build` directory is owned by root and provide a clear remediation step.

## Implementation Steps

### Phase 1: Root Makefile Updates
- [ ] Update `Makefile` to detect FreeBSD and set `MAKE` command for sub-calls accordingly.
- [ ] Ensure `make jvim` correctly passes `gmake` on FreeBSD.

### Phase 2: Installer Script Refactoring (`scripts/install.sh`)
- [ ] **Step 1**: Move Hardware Profile Detection (currently Section 9) to Section 1 (after OS check).
- [ ] **Step 2**: Add a permission check for `jvim/build` to warn about root-owned artifacts.
- [ ] **Step 3**: Fix the editor version probing logic to correctly identify `jvim` and avoid false "upstream Neovim" warnings.
- [ ] **Step 4**: Update model download logic to respect the profile-loaded `MODEL_PATH`.

### Phase 3: Cleanup
- [ ] Remove `hardware-profiles/Intel/dgpu_igpu/i5-1135g7-3b/install.sh`.
- [ ] (Optional/Recommended) Remove other legacy `install.sh` files found in hardware profiles to prevent recurrence.

## Verification & Testing

### Manual Verification
1. `make clean` (to clear out any existing root-owned artifacts).
2. `make install` as a regular user.
3. Verify that the installer detects the Intel profile *before* the model section.
4. Verify that the installer correctly identifies the 3B model as the target for the Intel profile.
5. Verify that `jvim` builds successfully using `gmake` automatically.

### Post-Installation Check
1. Run `jvim --check` to verify environment resolution.
2. Run `:checkhealth jenova` inside the editor.
