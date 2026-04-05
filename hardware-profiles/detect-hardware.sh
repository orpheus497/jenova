#!/bin/sh
# detect-hardware.sh: Auto-detect system hardware and select the optimal Jenova profile.
#
# Scans CPU model, GPU devices, OS, and RAM to match against known hardware
# profiles in hardware-profiles/*/profile.conf. Prints the matched profile
# directory name, or exits non-zero if no match found.
#
# Usage:
#   ./hardware-profiles/detect-hardware.sh          # Print matched profile name
#   ./hardware-profiles/detect-hardware.sh --info    # Print full hardware report
#   ./hardware-profiles/detect-hardware.sh --install  # Detect and run profile installer
#   ./hardware-profiles/detect-hardware.sh --apply   # Detect and deploy profile config

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Colours
if [ -t 1 ]; then
    _G="\033[0;32m"; _Y="\033[0;33m"; _R="\033[0;31m"; _B="\033[1;34m"; _C="\033[0;36m"; _N="\033[0m"
else
    _G=""; _Y=""; _R=""; _B=""; _C=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y}WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R}FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B}INFO${_N}  %s\n" "$1"; }

# =========================================================================
# Hardware Detection
# =========================================================================

detect_os() {
    OS_NAME=$(uname -s)
    OS_RELEASE=$(uname -r)
    OS_FULL="${OS_NAME} ${OS_RELEASE}"

    # Try to get pretty name
    if [ "$OS_NAME" = "FreeBSD" ]; then
        OS_PRETTY="FreeBSD ${OS_RELEASE}"
    elif [ -f /etc/os-release ]; then
        OS_PRETTY=$(. /etc/os-release 2>/dev/null && printf '%s\n' "$PRETTY_NAME")
        [ -z "$OS_PRETTY" ] && OS_PRETTY="$OS_FULL"
    else
        OS_PRETTY="$OS_FULL"
    fi
}

detect_cpu() {
    CPU_MODEL=""
    CPU_CORES=""
    CPU_THREADS=""

    if [ "$(uname -s)" = "FreeBSD" ]; then
        CPU_MODEL=$(sysctl -n hw.model 2>/dev/null || echo "Unknown")
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
        CPU_THREADS="$CPU_CORES"
    elif [ -f /proc/cpuinfo ]; then
        CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //')
        [ -z "$CPU_MODEL" ] && CPU_MODEL="Unknown"
        CPU_THREADS=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")
        CPU_CORES=$(grep "cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //')
        [ -z "$CPU_CORES" ] && CPU_CORES="$CPU_THREADS"
    else
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
        CPU_THREADS="$CPU_CORES"
    fi
}

detect_gpu() {
    GPU_DEVICES=""
    GPU_COUNT=0

    # Method 1: Vulkan (most reliable for inference)
    if command -v vulkaninfo >/dev/null 2>&1; then
        GPU_DEVICES=$(vulkaninfo --summary 2>/dev/null | grep "deviceName" | sed 's/.*= //' || true)
    fi

    # Method 2: pciconf (FreeBSD)
    if [ -z "$GPU_DEVICES" ] && command -v pciconf >/dev/null 2>&1; then
        GPU_DEVICES=$(pciconf -lv 2>/dev/null | grep -A2 "class.*display" | grep "device" | sed 's/.*device.*= //' || true)
    fi

    # Method 3: lspci (Linux)
    if [ -z "$GPU_DEVICES" ] && command -v lspci >/dev/null 2>&1; then
        GPU_DEVICES=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | sed 's/.*: //' || true)
    fi

    if [ -n "$GPU_DEVICES" ]; then
        GPU_COUNT=$(printf '%s\n' "$GPU_DEVICES" | grep -c "." || true)
    else
        GPU_DEVICES="No GPU detected"
        GPU_COUNT=0
    fi
}

detect_memory() {
    MEM_TOTAL_MB=0
    SWAP_TOTAL_MB=0

    if [ "$(uname -s)" = "FreeBSD" ]; then
        _physmem=$(sysctl -n hw.physmem 2>/dev/null) || _physmem=0
        MEM_TOTAL_MB=$((_physmem / 1024 / 1024))
        _swapk=$(swapinfo -k 2>/dev/null | tail -1 | awk '{print $2}') || _swapk=0
        SWAP_TOTAL_MB=$((_swapk / 1024))
    elif [ -f /proc/meminfo ]; then
        _memk=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null) || _memk=0
        MEM_TOTAL_MB=$((_memk / 1024))
        _swapk=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null) || _swapk=0
        SWAP_TOTAL_MB=$((_swapk / 1024))
    fi

    MEM_TOTAL_GIB=$((MEM_TOTAL_MB / 1024))
    SWAP_TOTAL_GIB=$((SWAP_TOTAL_MB / 1024))
}

detect_storage() {
    STORAGE_TYPE="unknown"
    if [ "$(uname -s)" = "FreeBSD" ]; then
        if zpool list >/dev/null 2>&1; then STORAGE_TYPE="ZFS"
        else STORAGE_TYPE="UFS"; fi
    elif [ -f /proc/mounts ]; then
        if grep -q " zfs " /proc/mounts 2>/dev/null; then STORAGE_TYPE="ZFS"
        elif grep -q " btrfs " /proc/mounts 2>/dev/null; then STORAGE_TYPE="btrfs"
        else STORAGE_TYPE="ext4/xfs"; fi
    fi
}

# =========================================================================
# Profile Matching
# =========================================================================

match_profile() {
    _profile_dir="$1"
    _profile_conf="$_profile_dir/profile.conf"

    [ -f "$_profile_conf" ] || return 1

    # Source profile.conf to extract all match variables robustly.
    # Reset all known profile.conf variables to prevent cross-iteration leakage.
    MATCH_CPU="" MATCH_GPU_0="" MATCH_GPU_1="" MATCH_OS=""
    PROFILE_NAME="" PROFILE_DESC="" STRATEGY="" STRATEGY_DESC=""
    HW_CPU="" HW_GPU_0="" HW_GPU_1="" HW_RAM="" HW_SWAP="" HW_STORAGE=""
    HW_GPU_TOTAL_VRAM=""
    PROFILE_DEVICES="" PROFILE_TENSOR_SPLIT="" PROFILE_FIT_TARGET=""
    PROFILE_CTX_SIZE="" PROFILE_NUM_SLOTS="" PROFILE_THREADS=""
    PROFILE_THREADS_BATCH="" PROFILE_NGL="" PROFILE_KV_TYPE=""
    # SECURITY NOTE: Sourcing executes the file as shell code. This is safe because
    # profile.conf files are part of this repository and contain only variable
    # assignments. Never source profile configs from untrusted/external sources.
    . "$_profile_conf"

    _score=0

    # CPU match (most important — worth 10 points)
    if [ -n "$MATCH_CPU" ]; then
        if printf '%s\n' "$CPU_MODEL" | grep -qi "$MATCH_CPU" 2>/dev/null; then
            _score=$((_score + 10))
        else
            return 1  # CPU mismatch is disqualifying
        fi
    fi

    # GPU match (worth 5 points per matching device)
    [ -n "$MATCH_GPU_0" ] && printf '%s\n' "$GPU_DEVICES" | grep -qiE "$MATCH_GPU_0" 2>/dev/null && _score=$((_score + 5))

    # MATCH_GPU_1: if defined, require it for multi-GPU profiles
    if [ -n "$MATCH_GPU_1" ]; then
        if printf '%s\n' "$GPU_DEVICES" | grep -qiE "$MATCH_GPU_1" 2>/dev/null; then
            _score=$((_score + 5))
        else
            # Multi-GPU profile requires second GPU — penalize heavily
            _score=$((_score - 8))
        fi
    fi

    # OS match (worth 3 points)
    [ -n "$MATCH_OS" ] && printf '%s\n' "$OS_NAME" | grep -qi "$MATCH_OS" 2>/dev/null && _score=$((_score + 3))

    printf '%d\n' "$_score"
    return 0
}

find_best_profile() {
    _best_score=0
    _best_profile=""
    _best_name=""

    for _pdir in "$SCRIPT_DIR"/*/; do
        [ -d "$_pdir" ] || continue
        [ -f "$_pdir/profile.conf" ] || continue

        _pscore=$(match_profile "$_pdir" 2>/dev/null || echo "0")
        _pname=$(basename "$_pdir")

        if [ "${_pscore:-0}" -gt "$_best_score" ]; then
            _best_score=$_pscore
            _best_profile="$_pdir"
            _best_name="$_pname"
        fi
    done

    if [ "$_best_score" -gt 0 ]; then
        MATCHED_PROFILE="$_best_name"
        MATCHED_PROFILE_DIR="$_best_profile"
        MATCHED_SCORE="$_best_score"
        return 0
    else
        MATCHED_PROFILE=""
        MATCHED_PROFILE_DIR=""
        MATCHED_SCORE=0
        return 1
    fi
}

# =========================================================================
# Actions
# =========================================================================

print_info() {
    echo ""
    printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
    printf "${_B}║       Jenova CA — Hardware Detection Report          ║${_N}\n"
    printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
    echo ""

    printf "${_C}  OS:${_N}       %s\n" "$OS_PRETTY"
    printf "${_C}  CPU:${_N}      %s (%s cores / %s threads)\n" "$CPU_MODEL" "$CPU_CORES" "$CPU_THREADS"
    printf "${_C}  GPU:${_N}\n"
    echo "$GPU_DEVICES" | while IFS= read -r line; do
        [ -n "$line" ] && printf "            %s\n" "$line"
    done
    printf "${_C}  GPU Count:${_N} %s\n" "$GPU_COUNT"
    printf "${_C}  RAM:${_N}      %s GiB\n" "$MEM_TOTAL_GIB"
    printf "${_C}  Swap:${_N}     %s GiB\n" "$SWAP_TOTAL_GIB"
    printf "${_C}  Storage:${_N}  %s\n" "$STORAGE_TYPE"
    echo ""

    echo "  Available profiles:"
    for _pdir in "$SCRIPT_DIR"/*/; do
        [ -d "$_pdir" ] || continue
        [ -f "$_pdir/profile.conf" ] || continue
        _pname=$(basename "$_pdir")
        _pdesc=$( ( . "$_pdir/profile.conf" && printf '%s\n' "$PROFILE_DESC" ) 2>/dev/null )
        _pscore=$(match_profile "$_pdir" 2>/dev/null || echo "0")
        if [ "$_pscore" -gt 0 ]; then
            printf "    ${_G}[match: %2d]${_N}  %-40s %s\n" "$_pscore" "$_pname" "$_pdesc"
        else
            printf "    ${_R}[no match]${_N}  %-40s %s\n" "$_pname" "$_pdesc"
        fi
    done
    echo ""
}

apply_profile() {
    if [ -z "$MATCHED_PROFILE_DIR" ]; then
        fail "No matching profile found for this hardware"
        return 1
    fi

    _jenova_root="$(dirname "$SCRIPT_DIR")"
    _profile_conf="$MATCHED_PROFILE_DIR/jenova.conf"

    if [ -f "$_profile_conf" ]; then
        # Backup existing config
        if [ -f "$_jenova_root/etc/jenova.conf" ]; then
            _ts=$(date +%Y%m%d_%H%M%S)
            cp "$_jenova_root/etc/jenova.conf" "$_jenova_root/etc/jenova.conf.bak.${_ts}"
            ok "Backed up existing config to etc/jenova.conf.bak.${_ts}"
        fi

        mkdir -p "$_jenova_root/etc"
        cp "$_profile_conf" "$_jenova_root/etc/jenova.conf"
        ok "Deployed $MATCHED_PROFILE configuration to etc/jenova.conf"
    else
        fail "Profile jenova.conf not found in $MATCHED_PROFILE_DIR"
        return 1
    fi
}

run_profile_installer() {
    if [ -z "$MATCHED_PROFILE_DIR" ]; then
        fail "No matching profile found for this hardware"
        return 1
    fi

    _installer="$MATCHED_PROFILE_DIR/install.sh"
    if [ -f "$_installer" ] && [ -x "$_installer" ]; then
        info "Running installer for profile: $MATCHED_PROFILE"
        exec "$_installer" "$@"
    else
        fail "No executable install.sh found in $MATCHED_PROFILE_DIR"
        return 1
    fi
}

# =========================================================================
# Main
# =========================================================================

# Always detect hardware
detect_os
detect_cpu
detect_gpu
detect_memory
detect_storage

ACTION="${1:-}"

case "$ACTION" in
    --info)
        find_best_profile || true
        print_info
        if [ -n "$MATCHED_PROFILE" ]; then
            printf "${_G}  Recommended profile: %s (score: %s)${_N}\n" "$MATCHED_PROFILE" "$MATCHED_SCORE"
        else
            printf "${_Y}  No matching profile found. You may need to create a new hardware profile.${_N}\n"
        fi
        echo ""
        ;;
    --install)
        shift
        if find_best_profile; then
            info "Detected hardware matches profile: $MATCHED_PROFILE (score: $MATCHED_SCORE)"
            run_profile_installer "$@"
        else
            print_info
            fail "No matching hardware profile found."
            echo ""
            echo "  Create a new profile in hardware-profiles/<your-profile-name>/"
            echo "  with profile.conf, jenova.conf, jenova-setup, and install.sh"
            exit 1
        fi
        ;;
    --apply)
        if find_best_profile; then
            info "Detected hardware matches profile: $MATCHED_PROFILE (score: $MATCHED_SCORE)"
            apply_profile
        else
            print_info
            fail "No matching hardware profile found."
            exit 1
        fi
        ;;
    --list)
        for _pdir in "$SCRIPT_DIR"/*/; do
            [ -d "$_pdir" ] || continue
            [ -f "$_pdir/profile.conf" ] || continue
            basename "$_pdir"
        done
        ;;
    "")
        # Default: print matched profile name (for scripting)
        if find_best_profile; then
            echo "$MATCHED_PROFILE"
        else
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [--info|--install|--apply|--list]" >&2
        echo "" >&2
        echo "  (no args)   Print matched profile name (for scripting)" >&2
        echo "  --info      Print full hardware detection report" >&2
        echo "  --install   Detect hardware and run matched profile installer" >&2
        echo "  --apply     Detect hardware and deploy matched profile config" >&2
        echo "  --list      List available profile names" >&2
        exit 1
        ;;
esac
