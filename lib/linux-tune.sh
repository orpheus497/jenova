#!/bin/sh
# lib/linux-tune.sh: Linux-specific kernel and hardware tuning for Jenova
#
# This script provides functions to optimize Linux for high-performance
# AI inference. It handles sysctls, hugepages, and GPU settings.
#
# Usage:
#   . "$JENOVA_ROOT/lib/linux-tune.sh"
#   tune_system_performance
#   tune_gpu_persistence

# Ensure we have access to common detection
if [ -z "$JENOVA_OS" ]; then
    _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    [ -f "$_SCRIPT_DIR/detect-env.sh" ] && . "$_SCRIPT_DIR/detect-env.sh"
fi

# Ensure we are running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script requires root privileges. Please run with sudo." >&2
    exit 1
fi

# Colours for output
if [ -t 1 ]; then
    _G=$(printf '\033[32m'); _Y=$(printf '\033[33m'); _B=$(printf '\033[34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _B=""; _N=""
fi

log_ok()   { printf "${_G}✓${_N}  %s\n" "$1"; }
log_warn() { printf "${_Y}⚠${_N}  %s\n" "$1"; }
log_info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

# apply_sysctl <key> <value> <description>
apply_sysctl() {
    _key="$1"; _val="$2"; _desc="$3"
    _current=$(sysctl -n "$_key" 2>/dev/null || echo "?")
    
    if [ "$_current" = "$_val" ]; then
        log_ok "$_key=$_val ($_desc)"
    else
        log_info "Setting $_key: $_current -> $_val ($_desc)"
        if sysctl -w "$_key=$_val" >/dev/null 2>&1; then
            # Persist via sysctl.d
            _conf="/etc/sysctl.d/99-jenova.conf"
            mkdir -p "$(dirname "$_conf")"
            # Remove old entry if exists
            _safe_key=$(echo "$_key" | sed 's/\./\\./g')
            [ -f "$_conf" ] && sed -i "/^${_safe_key}=/d" "$_conf"
            echo "$_key=$_val" >> "$_conf"
        else
            log_warn "Failed to set $_key (check permissions)"
        fi
    fi
}

# tune_system_performance: Kernal optimizations for inference
tune_system_performance() {
    log_info "Applying Linux kernel optimizations..."
    
    # Prioritize RAM for active processes, keep model in physical memory
    apply_sysctl "vm.swappiness" "10" "low swappiness to keep model in RAM"
    
    # Aggressively reclaim VFS cache (helps when loading large models)
    apply_sysctl "vm.vfs_cache_pressure" "200" "aggressive cache reclamation"
    
    # Allow more memory map areas (helpful for llama.cpp mmap)
    apply_sysctl "vm.max_map_count" "262144" "increased memory map limits"
    
    # Network tuning for CA (high throughput, low latency)
    apply_sysctl "net.core.rmem_max" "2500000" "increased receive buffer"
    apply_sysctl "net.core.wmem_max" "2500000" "increased send buffer"
}

# tune_hugepages: Optimize memory access for large models
tune_hugepages() {
    _thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
    if [ -f "$_thp_path" ]; then
        _current=$(cat "$_thp_path" | grep -o "\[.*\]" | tr -d '[]')
        if [ "$_current" != "madvise" ] && [ "$_current" != "always" ]; then
            log_info "Enabling Transparent Hugepages (madvise)..."
            echo "madvise" > "$_thp_path" 2>/dev/null || log_warn "Failed to set THP"
        else
            log_ok "THP already enabled ($_current)"
        fi
    fi
}

# tune_gpu_persistence: Prevent NVIDIA driver reload latency
tune_gpu_persistence() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        log_info "Checking NVIDIA GPU persistence..."
        if nvidia-smi -pm 1 >/dev/null 2>&1; then
            log_ok "NVIDIA Persistence Mode enabled"
        else
            log_warn "Failed to enable NVIDIA Persistence Mode"
        fi
    fi
}

# tune_debian_specific: Debian-specific OS adjustments
tune_debian_specific() {
    if [ "$JENOVA_DISTRO" = "debian" ]; then
        log_info "Applying Debian-specific OS adjustments..."
        # Example: Ensure limits.d is configured for high open files
        _limits="/etc/security/limits.d/jenova.conf"
        if [ ! -f "$_limits" ]; then
            echo "* soft nofile 65535" > "$_limits"
            echo "* hard nofile 65535" >> "$_limits"
            log_ok "Increased open file limits in $_limits"
        fi
    fi
}
