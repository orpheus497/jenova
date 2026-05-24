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
JENOVA_ROOT="$(dirname "$SCRIPT_DIR")"

# Shared OS/hardware detection.
. "$JENOVA_ROOT/lib/detect-env.sh"

# Colours
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _C=$(printf '\033[0;36m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _C=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y}WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R}FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B}INFO${_N}  %s\n" "$1"; }

validate_arg() {
    _flag="$1"
    _val="$2"
    if [ -z "$_val" ]; then
        fail "Option $_flag requires an argument."
        exit 1
    fi
    if [ "$_val" = "." ] || [ "$_val" = ".." ]; then
        fail "Invalid argument for $_flag: $_val"
        exit 1
    fi
}

# =========================================================================
# Hardware Detection
# =========================================================================

detect_os() {
    # Populated from shared detection in lib/detect-env.sh.
    OS_NAME="$(uname -s)"
    OS_RELEASE="$(uname -r)"
    OS_FULL="${OS_NAME} ${OS_RELEASE}"

    if [ "$JENOVA_OS" = "freebsd" ]; then
        OS_PRETTY="FreeBSD ${OS_RELEASE}"
    elif [ -f /etc/os-release ]; then
        OS_PRETTY="$(. /etc/os-release 2>/dev/null && printf '%s\n' "$PRETTY_NAME")"
        [ -z "$OS_PRETTY" ] && OS_PRETTY="$OS_FULL"
    else
        OS_PRETTY="$OS_FULL"
    fi
}

detect_cpu() {
    # Populated from shared detection in lib/detect-env.sh.
    CPU_MODEL="$JENOVA_CPU_MODEL"
    CPU_THREADS="$JENOVA_CPU_THREADS"
    CPU_CORES="$JENOVA_PHYSICAL_THREADS"
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
        GPU_COUNT=$(printf '%s\n' "$GPU_DEVICES" | grep "." | wc -l)
    else
        GPU_DEVICES="No GPU detected"
        GPU_COUNT=0
    fi
}

detect_memory() {
    # Populated from shared detection in lib/detect-env.sh.
    MEM_TOTAL_GIB="$JENOVA_RAM_GIB"
    SWAP_TOTAL_GIB="$JENOVA_SWAP_GIB"
    MEM_TOTAL_MB=$((MEM_TOTAL_GIB * 1024))
    SWAP_TOTAL_MB=$((SWAP_TOTAL_GIB * 1024))
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

detect_swap_hardware() {
    SYSTEM_SWAP_INFO="None"
    if [ "$JENOVA_OS" = "freebsd" ]; then
        _sdevs=$(swapinfo 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
        _ndevs=$(nvmecontrol devlist 2>/dev/null | tr '\n' ' ')
        [ -z "$_ndevs" ] && _ndevs=$(dmesg | grep -i "optane" | head -n 1)
        [ -n "$_sdevs" ] && SYSTEM_SWAP_INFO="${_sdevs} ${_ndevs}"
    elif [ "$JENOVA_OS" = "linux" ]; then
        _sdevs=$(cat /proc/swaps 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
        _ndevs=$(lsblk -d -o NAME,MODEL 2>/dev/null | grep -iE "nvme|optane" | tr '\n' ' ' || true)
        [ -n "$_sdevs" ] && SYSTEM_SWAP_INFO="${_sdevs} ${_ndevs}"
    fi
}

# =========================================================================
# Profile Matching
# =========================================================================

# load_jenova_profile is provided by lib/detect-env.sh

match_profile() {
    _profile_dir="$1"
    _profile_conf="$_profile_dir/profile.conf"

    [ -f "$_profile_conf" ] || return 1

    # Robustly load profile variables by sourcing after path validation
    # (Provided by lib/detect-env.sh)
    MATCH_CPU="" MATCH_GPU_0="" MATCH_GPU_1="" MATCH_OS="" MATCH_SWAP=""
    load_jenova_profile "$_profile_conf" || return 1

    _score=0

    # OS match (highest priority — worth 20 points, required for OS-specific profiles)
    if [ -n "$MATCH_OS" ]; then
        if printf '%s\n' "$OS_NAME" | grep -qFi "$MATCH_OS" 2>/dev/null; then
            _score=$((_score + 20))
        else
            # OS mismatch disqualifies OS-specific profiles
            return 1
        fi
    fi

    # CPU match (worth 10 points)
    # Uses -Fi (fixed string, case-insensitive) to avoid regex injection from profile values
    if [ -n "$MATCH_CPU" ]; then
        if printf '%s\n' "$CPU_MODEL" | grep -qFi "$MATCH_CPU" 2>/dev/null; then
            _score=$((_score + 10))
        else
            return 1  # CPU mismatch is disqualifying
        fi
    fi

    # GPU match (worth 5 points per matching device)
    # Uses -iE (extended regex) because GPU patterns use alternation (e.g., "Lucienne|Renoir")
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

    # NVMe Swap match (worth 10 points)
    if [ -n "$MATCH_SWAP" ]; then
        if printf '%s\n' "$SYSTEM_SWAP_INFO" | grep -qiE "$MATCH_SWAP" 2>/dev/null; then
            _score=$((_score + 10))
        else
            return 1  # NVMe Swap mismatch is disqualifying
        fi
    fi

    # Generic profiles (no OS match) get lower priority
    [ -z "$MATCH_OS" ] && _score=$((_score - 5))

    printf '%d\n' "$_score"
    return 0
}

find_best_profile() {
    _best_score=0
    _best_profile=""
    _best_name=""

    # Create temporary files for tracking the best profile across subshells
    _SCORE_FILE=$(mktemp)
    _NAME_FILE=$(mktemp)
    _PROFILE_FILE=$(mktemp)
    trap "rm -f '$_SCORE_FILE' '$_NAME_FILE' '$_PROFILE_FILE'" EXIT INT TERM
    echo "0" > "$_SCORE_FILE"

    # Use find to locate all profile.conf files at any depth
    find "$SCRIPT_DIR" -name "profile.conf" | (
        _local_best=0
        while IFS= read -r _pconf; do
            _pdir=$(dirname "$_pconf")
            _pname="${_pdir#"$SCRIPT_DIR"/}"
            _pscore=$(match_profile "$_pdir" 2>/dev/null || echo "0")

            if [ "${_pscore:-0}" -gt "$_local_best" ]; then
                _local_best=$_pscore
                echo "$_pscore" > "$_SCORE_FILE"
                echo "$_pname" > "$_NAME_FILE"
                echo "$_pdir" > "$_PROFILE_FILE"
            fi
        done
    )

    _best_score=$(cat "$_SCORE_FILE")
    _best_name=$(cat "$_NAME_FILE")
    _best_profile=$(cat "$_PROFILE_FILE")
    rm -f "$_SCORE_FILE" "$_NAME_FILE" "$_PROFILE_FILE"

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
    printf "${_C}  Swap Hw:${_N}  %s\n" "$SYSTEM_SWAP_INFO"
    echo ""

    echo "  Available profiles:"
    find "$SCRIPT_DIR" -name "profile.conf" | sort | while IFS= read -r _pconf; do
        _pdir=$(dirname "$_pconf")
        _pname="${_pdir#"$SCRIPT_DIR"/}"

        PROFILE_DESC=""
        load_jenova_profile "$_pconf" || continue
        _pdesc="$PROFILE_DESC"

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
    _jenova_home="${JENOVA_HOME:-$HOME/Jenova}"
    _profile_conf="$MATCHED_PROFILE_DIR/jenova.conf"

    if [ -f "$_profile_conf" ]; then
        # Backup existing config in JENOVA_HOME/etc
        if [ -f "$_jenova_home/etc/jenova.conf" ]; then
            _ts=$(date +%Y%m%d_%H%M%S)
            cp "$_jenova_home/etc/jenova.conf" "$_jenova_home/etc/jenova.conf.bak.${_ts}"
            ok "Backed up existing config to $_jenova_home/etc/jenova.conf.bak.${_ts}"
        fi

        mkdir -p "$_jenova_home/etc"
        cp "$_profile_conf" "$_jenova_home/etc/jenova.conf"
        ok "Deployed $MATCHED_PROFILE configuration to $_jenova_home/etc/jenova.conf"
        
        # Also deploy to repo etc/ for compatibility if writable
        if [ -w "$_jenova_root/etc" ]; then
            cp "$_profile_conf" "$_jenova_root/etc/jenova.conf"
            ok "Mirrored to $_jenova_root/etc/jenova.conf"
        fi
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
detect_swap_hardware

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
            echo "  Create a new profile in hardware-profiles/<Category>/<gpu_type>/<name>/"
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
    --apply-profile)
        shift
        _requested="${1:-}"
        validate_arg "--apply-profile" "$_requested"
        if [ -d "$SCRIPT_DIR/$_requested" ] && [ -f "$SCRIPT_DIR/$_requested/profile.conf" ]; then
            MATCHED_PROFILE_DIR="$SCRIPT_DIR/$_requested"
            MATCHED_PROFILE="$_requested"
            apply_profile
        else
            fail "Profile not found: $_requested"
            exit 1
        fi
        ;;
    --list)
        find "$SCRIPT_DIR" -name "profile.conf" | sort | while IFS= read -r _pconf; do
            _pdir=$(dirname "$_pconf")
            if [ "$_pdir" != "$SCRIPT_DIR" ]; then
                printf '%s\n' "${_pdir#"$SCRIPT_DIR"/}"
            fi
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
        echo "Usage: $0 [--info|--install|--apply|--apply-profile <name>|--list]" >&2
        echo "" >&2
        echo "  (no args)   Print matched profile name (for scripting)" >&2
        echo "  --info      Print full hardware detection report" >&2
        echo "  --install   Detect hardware and run matched profile installer" >&2
        echo "  --apply     Detect hardware and deploy matched profile config" >&2
        echo "  --apply-profile <name>  Deploy specific profile config" >&2
        echo "  --list      List available profile names" >&2
        exit 1
        ;;
esac
