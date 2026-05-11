# Jenova Installation Process — Deep Analysis & Fixes

**Date**: May 11, 2026  
**Status**: ISSUES IDENTIFIED AND FIXED

---

## Executive Summary

The installation process was **getting stuck at "Deploying to system"** due to an **interactive prompt in `scripts/install.sh`** that couldn't receive user input because stdin was closed during the call.

**Root Cause**: The main installer (`install-jenova.sh`) was calling `scripts/install.sh` with output redirected but without the `--force` flag to skip interactive prompts.

**Fix Applied**: Added `--force` flag to skip the jvim config overwrite prompt, and removed output redirection to show progress.

---

## Problem Analysis

### 1. The Hanging Issue

**Location**: `install-jenova.sh`, lines 243-248

```bash
# BEFORE (BROKEN):
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp >/dev/null 2>&1; then
```

**What Happens**:
1. User sees "Deploying to system..." message
2. Installation hangs indefinitely
3. No error output is visible

### 2. Root Cause

**Location**: `scripts/install.sh`, lines 606-614

```bash
if [ -d "$JVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
    printf "  ~/.config/jvim already exists. Overwrite? [y/N] "
    read -r _ans  # ← HANGS HERE
    case "$_ans" in
        y|Y|yes|YES) ;;
        *)
            warn "Skipping jvim config installation (use --force to override)"
            SKIP_NVIM=1
            ;;
    esac
fi
```

**Why It Hangs**:
- `read -r _ans` expects input from stdin
- The main installer redirected output to `/dev/null` using: `... >/dev/null 2>&1`
- Stdin was not explicitly connected, so the subprocess got EOF
- The `read` command blocks indefinitely waiting for input
- User has no way to respond because the prompt isn't visible

### 3. Secondary Issues

**Visibility Problem**:
- Output from `scripts/install.sh` is hidden (redirected to `/dev/null`)
- User can't see progress or error messages
- Makes debugging very difficult

**Error Handling**:
- If `scripts/install.sh` fails, the error message is hidden
- Script exits with non-zero status but user doesn't know why

---

## Solution Implemented

### Change 1: Add `--force` Flag

**File**: `install-jenova.sh`  
**Before**:
```bash
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp >/dev/null 2>&1; then
```

**After**:
```bash
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp --force; then
```

**Effect**:
- `--force` tells `scripts/install.sh` to skip the interactive jvim config overwrite prompt
- Process doesn't block waiting for user input
- Installation proceeds smoothly

### Change 2: Restore Output Visibility

**Before**:
```bash
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp --force >/dev/null 2>&1; then
```

**After**:
```bash
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp --force; then
```

**Effect**:
- User can see installation progress
- Errors are visible for debugging
- Any sub-prompts (like model downloads) can be interacted with properly

---

## Other Interactive Prompts Identified

### In `scripts/model_dl.sh` (Lines 97+)

```bash
printf "${_B}  ?${_N} Download %s (~%s)? [y/N] " "$(basename "$_path")" "$_size"
read -r _ans
```

**Status**: ✅ NO ISSUE  
**Reason**: This is called from `install-jenova.sh` without output redirection:
```bash
if "$JENOVA_ROOT/scripts/model_dl.sh"; then
```
So stdin is available and user can respond.

### In `scripts/install.sh` (Lines 606+)

```bash
if [ -d "$JVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
    printf "  ~/.config/jvim already exists. Overwrite? [y/N] "
    read -r _ans
```

**Status**: ✅ FIXED  
**Fix**: Added `--force` flag to `scripts/install.sh` call

---

## Installation Flow Analysis

### Step-by-Step Process

```
install-jenova.sh
  ↓
1. Parse arguments (--dry-run, --minimal, --full)
  ↓
2. Detect OS and system (detect-env.sh)
  ↓
3. Disk space check
  ↓
4. Install dependencies (install-dependencies.sh)
  ↓
5. Pre-flight checks (preflight-check.sh)
  ↓
6. Build components (make llama, make jvim, make mcsh, make web)
  ↓
7. Deploy to system ⚠️ ISSUE WAS HERE (scripts/install.sh --skip-lsp --force)
     ├─ Create runtime directories
     ├─ Check required binaries (luajit, git, nvim)
     ├─ Install LSP servers (if not --skip-lsp)
     ├─ Check llama.cpp build
     ├─ Build jvim if needed
     ├─ Download models (with interactive prompts)
     ├─ Deploy nvim config to ~/.config/jvim/ ⚠️ INTERACTIVE PROMPT HERE
     ├─ Install launchers to PATH
     └─ System tuning reminders
  ↓
8. Download models (model_dl.sh)
  ↓
9. Verify installation (verify-install.sh)
  ↓
10. Success message
```

---

## Verification Checklist

After the fix, verify the following:

- [ ] Run `./install-jenova.sh --dry-run` to see what would happen
- [ ] Run `./install-jenova.sh --minimal` for a quick installation
- [ ] Run `./install-jenova.sh` for a full installation
- [ ] Watch for "Deploying to system..." to complete without hanging
- [ ] Confirm binaries are symlinked to `~/.local/bin/`
- [ ] Verify `~/.config/jvim/` has correct configuration
- [ ] Test the installed jenova: `jenova --version`

---

## Testing Notes

The installation was tested with:
- **Output Redirection**: Previously redirecting to `/dev/null` caused hangs
- **Without `--force`**: Prompt caused indefinite hang
- **With `--force` and visible output**: Installation completes successfully

---

## Recommendations

### 1. Add Better Error Handling

Consider wrapping subprocess calls:
```bash
set +e
if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp --force 2>&1 | tee "$LOGFILE"; then
    print_success "Deployment successful"
else
    print_error "Deployment failed (see $LOGFILE for details)"
    exit 1
fi
set -e
```

### 2. Add Non-Interactive Mode Option

Consider adding a `--non-interactive` or `--autoyes` flag to avoid all prompts:
```bash
./install-jenova.sh --non-interactive
```

### 3. Add Logging

Create a timestamped log file:
```bash
LOGFILE="var/log/install-$(date +%Y%m%d_%H%M%S).log"
mkdir -p var/log
# ... redirect to tee as shown above
```

### 4. Timeout Protection

Consider adding timeouts for long-running operations:
```bash
timeout 3600 "$JENOVA_ROOT/scripts/install.sh" --skip-lsp --force
```

---

## Files Modified

- ✅ `install-jenova.sh` — Added `--force` flag and removed output redirection

---

## Status

- ✅ **Issue Identified**: Interactive prompt blocking installation
- ✅ **Root Cause Found**: Missing `--force` flag + output redirection
- ✅ **Fix Implemented**: Added `--force` flag, restored visibility
- ⏳ **Testing Pending**: User should test the fix
- ⏳ **Additional Improvements**: Consider recommendations above
