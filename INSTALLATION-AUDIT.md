# Installation Process - Comprehensive Audit & Improvement Plan

**Date**: May 11, 2026  
**Focus**: Streamline for FreeBSD (primary), Linux (secondary), macOS (tertiary), Windows via WSL  
**Status**: IN PROGRESS

---

## Current State Analysis

### Package Manager Detection ✅ GOOD
- detect-env.sh properly identifies:
  - **FreeBSD**: pkg ✅
  - **Linux**: Detects pacman, apt-get, dnf, zypper, xbps, nix ✅
  - **macOS**: brew, macports ✅
  - **Windows**: WSL detected as Linux, inherits Linux package managers ✅

### Package Definitions ✅ COMPREHENSIVE
- All managers have package mappings (pkg, pacman, apt, dnf, brew)
- Missing: zypper (openSUSE) and xbps (Void) package lists
- Missing: Proper handling of Windows WSL detection

### Issues Identified ⚠️

#### 1. **Incomplete Package Mappings**
- `zypper` (openSUSE) not defined in install-dependencies.sh
- `xbps` (Void) not defined in install-dependencies.sh
- These managers detected but no packages listed

#### 2. **WSL Detection**
- Running under WSL detected as "Linux" (correct)
- But could be improved with explicit WSL detection
- No special handling for WSL-specific issues

#### 3. **Package Manager Command Syntax**
- FreeBSD: `pkg install` ✅
- Arch: `pacman -S` or `yay -S` ✅
- Debian: `apt-get install` ✅ (should also support `apt`)
- Fedora: `dnf install` ✅
- macOS: `brew install` ✅
- openSUSE: `zypper install` ⚠️ MISSING
- Void: `xbps-install` ⚠️ MISSING

#### 4. **Privilege Escalation**
- FreeBSD: Uses `sudo pkg` (correct)
- macOS brew: Doesn't use sudo (correct)
- Others: Use `sudo` appropriately ✅
- But no detection if sudo works without password

#### 5. **Interactive Flow Issues**
- install-dependencies.sh uses non-interactive by default (good)
- But no clear progress feedback
- Error messages not always actionable
- No option to review what will be installed before proceeding

#### 6. **Error Recovery**
- If one package fails, entire script may fail
- No graceful degradation for optional packages
- No way to skip failed packages and continue

#### 7. **FreeBSD Specific Issues**
- Expects `sudo pkg` but FreeBSD root might be needed
- No detection of `pkg-ng` vs old `pkg_*` commands
- Should use `pkg` without sudo when run as root

#### 8. **macOS Specific Issues**
- brew might need Xcode Command Line Tools first
- brew might need M1/M2 special handling (rosetta vs native)
- No pre-check for brew existence before using it

---

## Required Improvements by Priority

### PRIORITY 1: Critical for all platforms

1. **Fix missing package managers** (zypper, xbps)
2. **Proper privilege handling** (don't use sudo unnecessarily)
3. **Better error reporting** (which packages failed, why)
4. **Graceful fallback** (skip optional, retry optional, continue)

### PRIORITY 2: Linux-specific

1. **apt vs apt-get** (support modern apt command)
2. **WSL-specific detection** (for Windows users)
3. **Flatpak detection** (for sandboxed environments)

### PRIORITY 3: FreeBSD-specific

1. **Root detection** (don't use sudo when running as root)
2. **pkg-ng verification** (ensure modern pkg)
3. **Port tree handling** (for ports tree if used)

### PRIORITY 4: macOS-specific

1. **Xcode Command Line Tools check** (required by brew)
2. **Apple Silicon support** (M1/M2/M3)
3. **HomeBrew location** (Intel vs Apple Silicon paths)

### PRIORITY 5: Interactive improvements

1. **Review plan before installation** (optional, --interactive flag)
2. **Progress indication** (which package being installed)
3. **Success/failure per package** (clear feedback)
4. **Retry mechanism** (for transient failures)

---

## Recommended Implementation

### Step 1: Fix Package Definitions
Add zypper and xbps package mappings to install-dependencies.sh

### Step 2: Improve Package Manager Abstraction
Create generic install function that handles:
- Which sudo is needed (FreeBSD root check)
- Which package manager command syntax
- Error handling per manager

### Step 3: Add WSL Detection
- Check for /proc/version containing "Microsoft" or "WSL"
- Inform user if running in WSL
- Suggest native OS installation if available

### Step 4: Improve Error Handling
- Track which packages failed
- Distinguish between required and optional
- Exit with proper codes (0=all, 1=critical failed, 2=some optional failed)

### Step 5: Add Interactive Mode
- `--interactive` flag to review before installing
- `--retry-failed` to retry optional packages
- `--verbose` to see installation progress

---

## File Changes Needed

1. **lib/detect-env.sh**
   - Add WSL detection
   - Document all supported managers

2. **scripts/install-dependencies.sh**
   - Add zypper package list
   - Add xbps package list
   - Fix privilege handling
   - Add retry mechanism
   - Improve error reporting

3. **install-jenova.sh**
   - Add --interactive flag
   - Show package summary before installing
   - Better feedback during installation

---

## Testing Plan

### Test each platform:
- [x] FreeBSD 15+ with pkg
- [ ] Arch Linux with pacman/yay
- [ ] Ubuntu/Debian with apt-get
- [ ] Fedora/RHEL with dnf
- [ ] openSUSE with zypper
- [ ] Void with xbps
- [ ] macOS 13+ with brew (Intel + Apple Silicon)
- [ ] Windows 11 with WSL2 + Debian
- [ ] Flatpak sandboxed environment

---

## Next Steps

1. Implement missing package managers (zypper, xbps)
2. Add proper privilege detection
3. Improve error handling
4. Add interactive mode
5. Test on all supported platforms
