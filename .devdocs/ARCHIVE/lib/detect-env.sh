#!/bin/sh
# Script function and purpose: Shared FreeBSD environment detection for Jenova
# scripts. Source this file (. "$JENOVA_ROOT/lib/detect-env.sh") to populate the
# JENOVA_* variables below. Safe to source multiple times (idempotent). Never
# installs anything or modifies system state.
#
# Exports:
#   JENOVA_OS            always "freebsd" (this file refuses to load elsewhere)
#   JENOVA_OS_RELEASE    kern.osrelease, e.g. "15.1-RELEASE"
#   JENOVA_ARCH          x86_64 | aarch64 | unknown
#   JENOVA_PKG_MGR       pkg | none
#   JENOVA_CPU_MODEL     Human-readable CPU model string
#   JENOVA_CPU_THREADS   Logical thread count
#   JENOVA_PHYSICAL_THREADS  Physical core count
#   JENOVA_RAM_GIB       Total RAM in GiB (integer)
#   JENOVA_SWAP_GIB      Total swap in GiB (integer)
#   JENOVA_VULKAN_OK     1 if the Vulkan loader is present, 0 otherwise
#   JENOVA_GLSLC_OK      1 if glslc is on PATH, 0 otherwise
#   JENOVA_GH_ARCH_LLS   GitHub release arch suffix for lua-language-server
#   JENOVA_GH_ARCH_ZLS   GitHub release arch suffix for zls

[ "${_JENOVA_ENV_LOADED:-0}" = "1" ] && return 0
_JENOVA_ENV_LOADED=1

# ── OS gate ───────────────────────────────────────────────────────────────────

# Action purpose: Identify the kernel via sysctl, NOT `uname -s`. Under the
# FreeBSD Linuxulator (the Linux ABI compatibility layer) `uname -s` reports
# "Linux" on a FreeBSD host, which previously made this file report
# JENOVA_OS=linux, JENOVA_DISTRO=fedora and JENOVA_PKG_MGR=none on a genuine
# FreeBSD 15.1 machine — selecting a Linux hardware profile and aborting the
# dependency installer. kern.ostype is answered by the kernel itself and stays
# truthful under the Linuxulator.
_jenova_ostype="$(sysctl -n kern.ostype 2>/dev/null || echo unknown)"

if [ "$_jenova_ostype" != "FreeBSD" ]; then
    printf 'Error: Jenova is built for FreeBSD only.\n' >&2
    printf '       kern.ostype reports: %s\n' "$_jenova_ostype" >&2
    printf '       (uname -s reports: %s)\n' "$(uname -s 2>/dev/null || echo unknown)" >&2
    return 1 2>/dev/null || exit 1
fi

JENOVA_OS="freebsd"
JENOVA_OS_RELEASE="$(sysctl -n kern.osrelease 2>/dev/null || echo unknown)"

case "$(sysctl -n hw.machine_arch 2>/dev/null || uname -m 2>/dev/null)" in
    x86_64|amd64)  JENOVA_ARCH="x86_64" ;;
    aarch64|arm64) JENOVA_ARCH="aarch64" ;;
    *)             JENOVA_ARCH="unknown" ;;
esac

# ── Package manager ───────────────────────────────────────────────────────────

# Retained as a seam for possible future ports(7) support alongside pkg(8).
JENOVA_PKG_MGR="none"
command -v pkg >/dev/null 2>&1 && JENOVA_PKG_MGR="pkg"

# ── CPU ───────────────────────────────────────────────────────────────────────

JENOVA_CPU_MODEL="$(sysctl -n hw.model 2>/dev/null)"
[ -z "$JENOVA_CPU_MODEL" ] && JENOVA_CPU_MODEL="Unknown"

JENOVA_CPU_THREADS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Action purpose: hw.ncpu counts logical CPUs. Physical cores come from the
# topology string kern.sched.topology_spec when present; fall back to the
# logical count rather than guessing a divisor, since SMT is not universal.
JENOVA_PHYSICAL_THREADS="$(
    sysctl -n kern.smp.cores 2>/dev/null \
    || echo "$JENOVA_CPU_THREADS"
)"

[ "${JENOVA_CPU_THREADS:-0}" -lt 1 ] 2>/dev/null && JENOVA_CPU_THREADS=1
[ "${JENOVA_PHYSICAL_THREADS:-0}" -lt 1 ] 2>/dev/null && JENOVA_PHYSICAL_THREADS="$JENOVA_CPU_THREADS"

# ── Memory ────────────────────────────────────────────────────────────────────

_jenova_physmem="$(sysctl -n hw.physmem 2>/dev/null || echo 0)"
JENOVA_RAM_GIB=$(( ${_jenova_physmem:-0} / 1024 / 1024 / 1024 ))

# swapinfo -k reports 1 KiB blocks in field 2; sum across all swap devices.
_jenova_swapk="$(swapinfo -k 2>/dev/null | awk 'NR>1 {s+=$2} END {printf "%d", s}' 2>/dev/null || echo 0)"
JENOVA_SWAP_GIB=$(( ${_jenova_swapk:-0} / 1024 / 1024 ))

# ── Vulkan ────────────────────────────────────────────────────────────────────

JENOVA_GLSLC_OK=0
command -v glslc >/dev/null 2>&1 && JENOVA_GLSLC_OK=1

JENOVA_VULKAN_OK=0
if [ -f /usr/local/lib/libvulkan.so ] || [ -f /usr/local/lib/libvulkan.so.1 ]; then
    JENOVA_VULKAN_OK=1
elif ldconfig -r 2>/dev/null | grep -q libvulkan; then
    JENOVA_VULKAN_OK=1
elif command -v vulkaninfo >/dev/null 2>&1 \
     && vulkaninfo --summary 2>/dev/null | grep -q deviceName; then
    JENOVA_VULKAN_OK=1
fi

# ── GitHub release arch suffixes (for LSP downloaders) ────────────────────────

case "$JENOVA_ARCH" in
    x86_64)  JENOVA_GH_ARCH_LLS="x64";   JENOVA_GH_ARCH_ZLS="x86_64" ;;
    aarch64) JENOVA_GH_ARCH_LLS="arm64"; JENOVA_GH_ARCH_ZLS="aarch64" ;;
    *)       JENOVA_GH_ARCH_LLS="";      JENOVA_GH_ARCH_ZLS="" ;;
esac

# ── Profile Loading ──────────────────────────────────────────────────────────

# Function purpose: Validate and source a Jenova hardware profile. The path must
# resolve inside JENOVA_ROOT/hardware-profiles; anything else is rejected so a
# crafted profile path cannot execute arbitrary shell.
load_jenova_profile() {
    _ljp_file="$1"
    [ -f "$_ljp_file" ] || return 1

    if command -v realpath >/dev/null 2>&1; then
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
    else
        # Basic validation if realpath is missing
        case "$_ljp_file" in
            ../*|*/../*)
                printf "Error: Profile path contains parent directory reference: %s\n" "$_ljp_file" >&2
                return 1
                ;;
        esac
        # shellcheck disable=SC1090
        . "$_ljp_file"
    fi
}

export JENOVA_OS JENOVA_OS_RELEASE JENOVA_ARCH JENOVA_PKG_MGR
export JENOVA_CPU_MODEL JENOVA_CPU_THREADS JENOVA_PHYSICAL_THREADS
export JENOVA_RAM_GIB JENOVA_SWAP_GIB
export JENOVA_VULKAN_OK JENOVA_GLSLC_OK
export JENOVA_GH_ARCH_LLS JENOVA_GH_ARCH_ZLS
