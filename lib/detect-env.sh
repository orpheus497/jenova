#!/bin/sh
# lib/detect-env.sh: Shared OS/hardware environment detection for Jenova scripts.
#
# Source this file (. "$JENOVA_ROOT/lib/detect-env.sh") to populate JENOVA_*
# environment variables. Safe to source multiple times (idempotent). Never
# installs anything or modifies system state.
#
# Exports:
#   JENOVA_OS            freebsd | linux | macos | unknown
#   JENOVA_ARCH          x86_64 | aarch64 | unknown
#   JENOVA_DISTRO        arch | debian | ubuntu | fedora | opensuse | void | nixos
#                        freebsd | macos | unknown
#   JENOVA_PKG_MGR       pkg | pacman | apt | dnf | zypper | xbps | nix | brew | none
#   JENOVA_CPU_MODEL     Human-readable CPU model string
#   JENOVA_CPU_THREADS   Logical thread count (including HT)
#   JENOVA_PHYSICAL_THREADS  Physical core count
#   JENOVA_RAM_GIB       Total RAM in GiB (integer)
#   JENOVA_SWAP_GIB      Total swap in GiB (integer)
#   JENOVA_VULKAN_OK     1 if libvulkan.so found and usable, 0 otherwise
#   JENOVA_GLSLC_OK      1 if glslc is on PATH, 0 otherwise
#   JENOVA_GH_ARCH_LLS   GitHub release arch suffix for lua-language-server
#   JENOVA_GH_ARCH_ZLS   GitHub release arch suffix for zls
#   JENOVA_WSL           1 if Windows Subsystem for Linux, 0 otherwise

[ "${_JENOVA_ENV_LOADED:-0}" = "1" ] && return 0
_JENOVA_ENV_LOADED=1

# ── OS ────────────────────────────────────────────────────────────────────────

_jenova_raw_os="$(uname -s 2>/dev/null)"
_jenova_raw_arch="$(uname -m 2>/dev/null)"

case "$_jenova_raw_os" in
    FreeBSD) JENOVA_OS="freebsd" ;;
    Linux)   JENOVA_OS="linux" ;;
    Darwin)  JENOVA_OS="macos" ;;
    *)       JENOVA_OS="unknown" ;;
esac

case "$_jenova_raw_arch" in
    x86_64|amd64)  JENOVA_ARCH="x86_64" ;;
    aarch64|arm64) JENOVA_ARCH="aarch64" ;;
    *)             JENOVA_ARCH="unknown" ;;
esac

JENOVA_WSL=0
if [ "$JENOVA_OS" = "linux" ] && grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    JENOVA_WSL=1
fi

# ── Distro + package manager ──────────────────────────────────────────────────

JENOVA_DISTRO="unknown"
JENOVA_PKG_MGR="none"

if [ "$JENOVA_OS" = "linux" ]; then
    _jenova_id=""
    _jenova_id_like=""
    if [ -f /etc/os-release ]; then
        _jenova_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
        _jenova_id_like="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")"
    fi

    case "${_jenova_id:-}" in
        org.freedesktop.platform)
            # Flatpak runtime - try to detect host distro
            JENOVA_DISTRO="flatpak"
            # Check for host package managers that might be available
            ;;
        arch|manjaro|endeavouros|garuda|cachyos) JENOVA_DISTRO="arch" ;;
        debian|raspbian)                         JENOVA_DISTRO="debian" ;;
        ubuntu|linuxmint|pop)                    JENOVA_DISTRO="ubuntu" ;;
        fedora|rhel|centos|rocky|alma|nobara)    JENOVA_DISTRO="fedora" ;;
        opensuse*|sles)                          JENOVA_DISTRO="opensuse" ;;
        void)                                    JENOVA_DISTRO="void" ;;
        nixos)                                   JENOVA_DISTRO="nixos" ;;
        *)
            case "${_jenova_id_like:-}" in
                *arch*)          JENOVA_DISTRO="arch" ;;
                *ubuntu*)        JENOVA_DISTRO="ubuntu" ;;
                *debian*)        JENOVA_DISTRO="debian" ;;
                *fedora*|*rhel*) JENOVA_DISTRO="fedora" ;;
                *suse*)          JENOVA_DISTRO="opensuse" ;;
            esac
            ;;
    esac

    # Confirm package manager by command presence — don't assume from distro alone.
    if   command -v pacman      >/dev/null 2>&1; then JENOVA_PKG_MGR="pacman"
    elif command -v apt-get     >/dev/null 2>&1; then JENOVA_PKG_MGR="apt"
    elif command -v dnf         >/dev/null 2>&1; then JENOVA_PKG_MGR="dnf"
    elif command -v zypper      >/dev/null 2>&1; then JENOVA_PKG_MGR="zypper"
    elif command -v xbps-install >/dev/null 2>&1; then JENOVA_PKG_MGR="xbps"
    elif command -v nix-env     >/dev/null 2>&1; then JENOVA_PKG_MGR="nix"
    fi

elif [ "$JENOVA_OS" = "freebsd" ]; then
    JENOVA_DISTRO="freebsd"
    command -v pkg >/dev/null 2>&1 && JENOVA_PKG_MGR="pkg"

elif [ "$JENOVA_OS" = "macos" ]; then
    JENOVA_DISTRO="macos"
    if   command -v brew >/dev/null 2>&1; then JENOVA_PKG_MGR="brew"
    elif command -v port >/dev/null 2>&1; then JENOVA_PKG_MGR="macports"
    fi
fi

# ── CPU ───────────────────────────────────────────────────────────────────────

JENOVA_CPU_MODEL="Unknown"
JENOVA_CPU_THREADS=4
JENOVA_PHYSICAL_THREADS=4

if [ "$JENOVA_OS" = "freebsd" ] && command -v sysctl >/dev/null 2>&1; then
    JENOVA_CPU_MODEL="$(sysctl -n hw.model 2>/dev/null || echo "Unknown")"
    JENOVA_CPU_THREADS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    JENOVA_PHYSICAL_THREADS="$JENOVA_CPU_THREADS"
elif [ -f /proc/cpuinfo ]; then
    JENOVA_CPU_MODEL="$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //')"
    [ -z "$JENOVA_CPU_MODEL" ] && JENOVA_CPU_MODEL="Unknown"
    JENOVA_CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4)"
    if command -v lscpu >/dev/null 2>&1; then
        _lscpu="$(lscpu 2>/dev/null)"
        _cores="$(printf '%s\n' "$_lscpu" | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2); print $2; exit}')"
        _sockets="$(printf '%s\n' "$_lscpu" | awk -F: '/Socket\(s\)/{gsub(/ /,"",$2); print $2; exit}')"
        if [ -n "${_cores:-}" ] && [ -n "${_sockets:-}" ] && [ "${_cores:-0}" -gt 0 ] 2>/dev/null; then
            JENOVA_PHYSICAL_THREADS=$((_cores * _sockets))
        else
            JENOVA_PHYSICAL_THREADS="$JENOVA_CPU_THREADS"
        fi
    else
        JENOVA_PHYSICAL_THREADS="$JENOVA_CPU_THREADS"
    fi
elif [ "$JENOVA_OS" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
    # Apple Silicon doesn't have machdep.cpu.brand_string; fall back to hw.model.
    JENOVA_CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
                        || sysctl -n hw.model 2>/dev/null \
                        || echo "Unknown")"
    JENOVA_CPU_THREADS="$(sysctl -n hw.logicalcpu 2>/dev/null \
                          || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    JENOVA_PHYSICAL_THREADS="$(sysctl -n hw.physicalcpu 2>/dev/null \
                                || echo "$JENOVA_CPU_THREADS")"
fi

[ "${JENOVA_CPU_THREADS:-0}" -lt 1 ]  2>/dev/null && JENOVA_CPU_THREADS=1
[ "${JENOVA_PHYSICAL_THREADS:-0}" -lt 1 ] 2>/dev/null && JENOVA_PHYSICAL_THREADS=1

# ── Memory ────────────────────────────────────────────────────────────────────

JENOVA_RAM_GIB=0
JENOVA_SWAP_GIB=0

if [ "$JENOVA_OS" = "freebsd" ] && command -v sysctl >/dev/null 2>&1; then
    _physmem="$(sysctl -n hw.physmem 2>/dev/null || echo 0)"
    JENOVA_RAM_GIB=$(( ${_physmem:-0} / 1024 / 1024 / 1024 ))
    _swapk="$(swapinfo -k 2>/dev/null | awk 'NR>1{s+=$2} END{printf "%d", s/1024}' 2>/dev/null || echo 0)"
    JENOVA_SWAP_GIB=$(( ${_swapk:-0} / 1024 ))
elif [ -f /proc/meminfo ]; then
    JENOVA_RAM_GIB="$(awk '/^MemTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    JENOVA_SWAP_GIB="$(awk '/^SwapTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
elif [ "$JENOVA_OS" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
    # hw.memsize returns bytes; vm.swapusage is human-readable so we parse with awk.
    _memsize="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    JENOVA_RAM_GIB=$(( ${_memsize:-0} / 1024 / 1024 / 1024 ))
    JENOVA_SWAP_GIB="$(sysctl -n vm.swapusage 2>/dev/null \
                       | awk '/total/{gsub(/M/,""); for(i=1;i<=NF;i++) if($i=="total") {printf "%d", $(i+2)/1024; exit}}' \
                       || echo 0)"
fi

# ── Vulkan ────────────────────────────────────────────────────────────────────

JENOVA_VULKAN_OK=0
JENOVA_GLSLC_OK=0

command -v glslc >/dev/null 2>&1 && JENOVA_GLSLC_OK=1

_jenova_vulkan_found=0
case "$JENOVA_OS" in
    freebsd)
        if [ -f /usr/local/lib/libvulkan.so ] || ldconfig -r 2>/dev/null | grep -q libvulkan; then
            _jenova_vulkan_found=1
        fi
        ;;
    linux)
        # ldconfig -p is the canonical check; fall back to known multilib paths.
        if ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so'; then
            _jenova_vulkan_found=1
        elif [ -f /usr/lib/libvulkan.so.1 ] \
          || [ -f /usr/lib/x86_64-linux-gnu/libvulkan.so.1 ] \
          || [ -f /usr/lib64/libvulkan.so.1 ] \
          || [ -f /usr/lib/aarch64-linux-gnu/libvulkan.so.1 ]; then
            _jenova_vulkan_found=1
        fi
        ;;
    macos)
        if [ -f /usr/local/lib/libvulkan.dylib ] || [ -f /opt/homebrew/lib/libvulkan.dylib ]; then
            _jenova_vulkan_found=1
        fi
        ;;
esac

# vulkaninfo is a secondary confirmation when the library path check fails.
if [ "$_jenova_vulkan_found" = "0" ] && command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary 2>/dev/null | grep -q deviceName && _jenova_vulkan_found=1
fi

JENOVA_VULKAN_OK="$_jenova_vulkan_found"

# ── GitHub release arch suffixes (for LSP downloaders) ───────────────────────

case "$JENOVA_ARCH" in
    x86_64)  JENOVA_GH_ARCH_LLS="x64";   JENOVA_GH_ARCH_ZLS="x86_64" ;;
    aarch64) JENOVA_GH_ARCH_LLS="arm64"; JENOVA_GH_ARCH_ZLS="aarch64" ;;
    *)       JENOVA_GH_ARCH_LLS="";      JENOVA_GH_ARCH_ZLS="" ;;
esac

# ── Profile Loading ──────────────────────────────────────────────────────────

# load_jenova_profile <profile_path>
# Securely validates and sources a Jenova hardware profile configuration.
# Path must be within the JENOVA_ROOT/hardware-profiles directory.
load_jenova_profile() {
    _ljp_file="$1"
    [ -f "$_ljp_file" ] || return 1

    _ljp_real="$(realpath "$_ljp_file" 2>/dev/null)" || return 1
    _ljp_root="$(realpath "$JENOVA_ROOT/hardware-profiles" 2>/dev/null)" || return 1

    case "$_ljp_real" in
        "$_ljp_root"/*)
            # shellcheck disable=SC1090
            . "$_ljp_real"
            ;;
        *)
            printf "Error: Profile path outside expected directory: %s\n" "$_ljp_real" >&2
            return 1
            ;;
    esac
}

export JENOVA_OS JENOVA_ARCH JENOVA_DISTRO JENOVA_PKG_MGR
export JENOVA_CPU_MODEL JENOVA_CPU_THREADS JENOVA_PHYSICAL_THREADS
export JENOVA_RAM_GIB JENOVA_SWAP_GIB
export JENOVA_VULKAN_OK JENOVA_GLSLC_OK JENOVA_WSL
export JENOVA_GH_ARCH_LLS JENOVA_GH_ARCH_ZLS
