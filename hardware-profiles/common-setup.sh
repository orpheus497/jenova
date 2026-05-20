#!/bin/sh
# hardware-profiles/common-setup.sh: Shared setup functions for Jenova hardware profiles

# Helper: add to sysctl.conf if not already present, avoiding duplicates
sysctl_persist() {
    _line="$1"
    _key=$(echo "$_line" | cut -d= -f1)
    _esc_key=$(printf '%s' "$_key" | sed 's/[][.\\*^$|()+?{}]/\\&/g')
    _tmp=$(mktemp)
    # Remove all existing instances of this key and append the new value
    if [ -f /etc/sysctl.conf ]; then
        grep -vE "^${_esc_key}[[:space:]]*=" /etc/sysctl.conf > "$_tmp" || true
    fi
    echo "$_line" >> "$_tmp"
    [ -f /etc/sysctl.conf ] && cp -p /etc/sysctl.conf /etc/sysctl.conf.bak
    
    if [ -f /etc/sysctl.conf ]; then
        cp "$_tmp" /etc/sysctl.conf
    else
        install -m 644 "$_tmp" /etc/sysctl.conf
    fi
    rm -f "$_tmp"
}
