#!/usr/bin/env bash
# jenova-manager.sh: TUI Manager for Jenova ecosystem

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")"
export JENOVA_ROOT

# User-writable workspace for cloned components (jvim, jenova-cli).
# Falls back to $HOME/src if the parent of JENOVA_ROOT is not writable.
JENOVA_WORKSPACE="${JENOVA_WORKSPACE:-}"
if [ -z "$JENOVA_WORKSPACE" ]; then
    _parent="$(dirname "$JENOVA_ROOT")"
    if [ -w "$_parent" ]; then
        JENOVA_WORKSPACE="$_parent"
    else
        JENOVA_WORKSPACE="$HOME/src"
    fi
fi

# Detect dialog or whiptail
if command -v dialog >/dev/null 2>&1; then
    DIALOG="dialog"
elif command -v whiptail >/dev/null 2>&1; then
    DIALOG="whiptail"
else
    echo "Error: Neither 'dialog' nor 'whiptail' is installed."
    echo "Please install one of them to use this TUI."
    exit 1
fi

# --- Component detection ---

check_jvim() {
    command -v jvim >/dev/null 2>&1 && jvim --version 2>/dev/null | grep -q 'JVIM'
}

check_jenova_cli() { command -v jenova-cli >/dev/null 2>&1; }

resolve_llama_server_path() {
    local config_file
    local resolved_path="${LLAMA_SERVER:-}"
    local resolved_build_dir="${JENOVA_BUILD_DIR:-}"

    for config_file in \
        "$JENOVA_ROOT/etc/jenova.local.conf" \
        "$JENOVA_ROOT/llama.cpp/build/jenova.local.conf"
    do
        if [ -f "$config_file" ]; then
            if [ -z "$resolved_path" ]; then
                resolved_path="$(
                    JENOVA_ROOT="$JENOVA_ROOT" bash -c '
                        . "$1" >/dev/null 2>&1 || exit 0
                        printf "%s" "${LLAMA_SERVER:-}"
                    ' bash "$config_file"
                )"
            fi

            if [ -z "$resolved_build_dir" ]; then
                resolved_build_dir="$(
                    JENOVA_ROOT="$JENOVA_ROOT" bash -c '
                        . "$1" >/dev/null 2>&1 || exit 0
                        printf "%s" "${JENOVA_BUILD_DIR:-}"
                    ' bash "$config_file"
                )"
            fi
        fi
    done

    if [ -n "$resolved_path" ]; then
        printf '%s\n' "$resolved_path"
    elif [ -n "$resolved_build_dir" ]; then
        printf '%s\n' "$resolved_build_dir/bin/llama-server"
    else
        printf '%s\n' "$JENOVA_ROOT/llama.cpp/build/bin/llama-server"
    fi
}

check_llama() {
    local llama_server
    llama_server="$(resolve_llama_server_path)"
    [ -f "$llama_server" ]
}

check_jenova_core() {
    local installed_path
    local expected_path

    installed_path="$(command -v jenova-ca 2>/dev/null)" || return 1
    [ -n "$installed_path" ] || return 1
    [ -x "$JENOVA_ROOT/bin/jenova-ca" ] || return 1

    expected_path="$(realpath "$JENOVA_ROOT/bin/jenova-ca")"
    [ "$(realpath "$installed_path")" = "$expected_path" ]
}

# Resolve a writable bin directory on PATH, matching install.sh logic.
resolve_bin_dir() {
    local _d
    for _d in "$HOME/.local/bin" "$HOME/bin"; do
        if echo ":$PATH:" | grep -q ":$_d:"; then
            printf '%s\n' "$_d"
            return 0
        fi
    done
    return 1
}

# Temporary file to store dialog selections
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT INT TERM

show_main_menu() {
    if ! $DIALOG --clear --title "Jenova Manager" \
        --menu "Select an action:" 15 50 4 \
        1 "Install components" \
        2 "Update components" \
        3 "Uninstall components" \
        4 "Exit" 2> "$TEMP_FILE"; then
        exit 0
    fi

    CHOICE=$(cat "$TEMP_FILE")
    case "$CHOICE" in
        1) show_install_menu ;;
        2) show_update_menu ;;
        3) show_uninstall_menu ;;
        4) exit 0 ;;
    esac
}

show_install_menu() {
    local status_core="on"
    local status_jvim="on"
    local status_cli="on"
    local status_llama="on"

    check_jenova_core && status_core="off"
    check_jvim && status_jvim="off"
    check_jenova_cli && status_cli="off"
    check_llama && status_llama="off"

    if ! $DIALOG --clear --title "Install Jenova Components" \
        --checklist "Select components to install (already installed items are unchecked):" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (requires sudo)" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> "$TEMP_FILE"; then
        show_main_menu
        return
    fi

    local selected
    selected=$(tr -d '"' < "$TEMP_FILE")
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --yesno "Are you sure you want to install $item?" 8 50; then
            echo "Installing $item..."
            if case "$item" in
                "Jenova_Core") install_jenova_core ;;
                "jvim") install_jvim ;;
                "jenova-cli") install_jenova_cli ;;
                "llama.cpp") install_llama ;;
                *) false ;;
            esac
            then
                echo "Finished installing $item. Press any key to continue."
            else
                echo "Failed to install $item. Press any key to continue."
            fi
            read -n 1 -s -r
        else
            echo "Skipping $item..."
        fi
    done
    show_main_menu
}

show_update_menu() {
    local status_core="off"
    local status_jvim="off"
    local status_cli="off"
    local status_llama="off"

    check_jenova_core && status_core="on"
    check_jvim && status_jvim="on"
    check_jenova_cli && status_cli="on"
    check_llama && status_llama="on"

    if ! $DIALOG --clear --title "Update Jenova Components" \
        --checklist "Select components to update:" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> "$TEMP_FILE"; then
        show_main_menu
        return
    fi

    local selected
    selected=$(tr -d '"' < "$TEMP_FILE")
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --yesno "Are you sure you want to update $item?" 8 50; then
            echo "Updating $item..."
            if case "$item" in
                "Jenova_Core") update_jenova_core ;;
                "jvim") update_jvim ;;
                "jenova-cli") update_jenova_cli ;;
                "llama.cpp") update_llama ;;
                *) false ;;
            esac
            then
                echo "Finished updating $item. Press any key to continue."
            else
                echo "Failed to update $item. Press any key to continue."
            fi
            read -n 1 -s -r
        else
            echo "Skipping $item update..."
        fi
    done
    show_main_menu
}

show_uninstall_menu() {
    local status_core="off"
    local status_jvim="off"
    local status_cli="off"
    local status_llama="off"

    check_jenova_core && status_core="on"
    check_jvim && status_jvim="on"
    check_jenova_cli && status_cli="on"
    check_llama && status_llama="on"

    if ! $DIALOG --clear --title "Uninstall Jenova Components" \
        --checklist "Select components to uninstall:" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> "$TEMP_FILE"; then
        show_main_menu
        return
    fi

    local selected
    selected=$(tr -d '"' < "$TEMP_FILE")
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --defaultno --yesno "Are you absolutely sure you want to uninstall $item? This may remove configuration and binaries." 10 60; then
            echo "Uninstalling $item..."
            if case "$item" in
                "Jenova_Core") uninstall_jenova_core ;;
                "jvim") uninstall_jvim ;;
                "jenova-cli") uninstall_jenova_cli ;;
                "llama.cpp") uninstall_llama ;;
                *) false ;;
            esac
            then
                echo "Finished uninstalling $item. Press any key to continue."
            else
                echo "Failed to uninstall $item. Press any key to continue."
            fi
            read -n 1 -s -r
        else
            echo "Skipping $item uninstall..."
        fi
    done
    show_main_menu
}

# --- Action Implementations ---
install_jenova_core() {
    echo "Installing Jenova Core..."
    "$JENOVA_ROOT/install.sh"
}
install_jvim() {
    echo "Installing jvim..."
    mkdir -p "$JENOVA_WORKSPACE"
    cd "$JENOVA_WORKSPACE"
    if [ ! -d "jvim" ]; then
        git clone https://github.com/orpheus497/jvim.git
    fi
    cd jvim && make CMAKE_BUILD_TYPE=Release && sudo make install
}
install_jenova_cli() {
    echo "Installing jenova-cli..."
    mkdir -p "$JENOVA_WORKSPACE"
    cd "$JENOVA_WORKSPACE"
    if [ ! -d "jenova-cli" ]; then
        if [ -d "cloda-codey-lua" ]; then
            mv cloda-codey-lua jenova-cli
        else
            git clone https://github.com/orpheus497/jenova-cli.git
        fi
    fi
    cd jenova-cli

    local bin_dir
    if bin_dir="$(resolve_bin_dir)"; then
        mkdir -p "$bin_dir"
        make install PREFIX="$(dirname "$bin_dir")"
    else
        echo "No writable bin dir found on PATH; installing to /usr/local (requires sudo)."
        sudo make install PREFIX=/usr/local
    fi
}
install_llama() {
    echo "Installing llama.cpp..."
    "$JENOVA_ROOT/bin/build-llama-jenova"
}

update_jenova_core() {
    echo "Updating Jenova Core..."
    "$JENOVA_ROOT/update.sh"
}
update_jvim() {
    echo "Updating jvim..."
    cd "$JENOVA_WORKSPACE/jvim" || { echo "Cannot access jvim directory at $JENOVA_WORKSPACE/jvim"; return 1; }
    git pull --ff-only origin main
    if $DIALOG --yesno "Do you want to rebuild jvim?" 8 50; then
        make CMAKE_BUILD_TYPE=Release && sudo make install
    fi
}
update_jenova_cli() {
    echo "Updating jenova-cli..."
    if [ ! -d "$JENOVA_WORKSPACE/jenova-cli" ] && [ -d "$JENOVA_WORKSPACE/cloda-codey-lua" ]; then
        mv "$JENOVA_WORKSPACE/cloda-codey-lua" "$JENOVA_WORKSPACE/jenova-cli"
    fi
    cd "$JENOVA_WORKSPACE/jenova-cli" || { echo "Cannot access jenova-cli directory at $JENOVA_WORKSPACE/jenova-cli"; return 1; }
    git pull --ff-only origin main
    if $DIALOG --yesno "Do you want to rebuild jenova-cli?" 8 50; then
        local bin_dir
        if bin_dir="$(resolve_bin_dir)"; then
            mkdir -p "$bin_dir"
            make install PREFIX="$(dirname "$bin_dir")"
        else
            echo "No writable bin dir found on PATH; installing to /usr/local (requires sudo)."
            sudo make install PREFIX=/usr/local
        fi
    fi
}
update_llama() {
    echo "Updating llama.cpp..."
    cd "$JENOVA_ROOT/llama.cpp" || { echo "Cannot access llama.cpp directory at $JENOVA_ROOT/llama.cpp"; return 1; }
    git pull --ff-only origin master
    if $DIALOG --yesno "Do you want to rebuild llama.cpp?" 8 50; then
        "$JENOVA_ROOT/bin/build-llama-jenova"
    fi
}

uninstall_jenova_core() {
    echo "Uninstalling Jenova Core..."
    "$JENOVA_ROOT/uninstall.sh"
}
uninstall_jvim() {
    echo "Uninstalling jvim..."
    cd "$JENOVA_WORKSPACE/jvim" || { echo "Cannot access jvim directory at $JENOVA_WORKSPACE/jvim"; return 1; }
    sudo make uninstall
}
uninstall_jenova_cli() {
    echo "Uninstalling jenova-cli..."

    local cli_path expected_path
    cli_path="$(command -v jenova-cli 2>/dev/null || true)"

    if [ -z "$cli_path" ]; then
        echo "jenova-cli is not installed on PATH; nothing to remove."
        return
    fi

    if command -v realpath >/dev/null 2>&1; then
        cli_path="$(realpath "$cli_path")"
    fi

    # Only remove if it resolves to a known install location
    for expected_path in "/usr/local/bin/jenova-cli" "$HOME/.local/bin/jenova-cli" "$HOME/bin/jenova-cli"; do
        if [ "$cli_path" = "$expected_path" ]; then
            if [ -w "$(dirname "$cli_path")" ]; then
                rm -f "$cli_path"
            else
                sudo rm -f "$cli_path"
            fi
            echo "jenova-cli removed from $cli_path."
            return
        fi
    done

    echo "Skipping removal: jenova-cli resolves to '$cli_path', not a known install location."
}
uninstall_llama() {
    echo "Uninstalling llama.cpp..."
    rm -rf "$JENOVA_ROOT/llama.cpp/build"
    echo "llama.cpp build removed."
}

# Start TUI loop
show_main_menu
