#!/usr/bin/env bash
# jenova-manager.sh: TUI manager for this monorepo
#
# All components — Jenova Core (backend + scripts), the bundled jvim
# editor, and llama.cpp — live inside this repository. This manager
# dispatches install / update / uninstall actions to the in-tree
# Makefile targets and helper scripts. Nothing is cloned from external repos.

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
export JENOVA_ROOT

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

# Prefer GNU make (gmake) on FreeBSD; falls back to system make.
if command -v gmake >/dev/null 2>&1; then
    MAKE="gmake"
else
    MAKE="make"
fi

# --- Component detection ---

check_jvim() {
    # In-tree build is the canonical install; PATH binary is a secondary check.
    [ -x "$JENOVA_ROOT/jvim/build/bin/nvim" ] || \
        ( command -v jvim >/dev/null 2>&1 && jvim --version 2>/dev/null | grep -q 'JVIM' )
}

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

show_action_menu() {
    local action="$1"
    local title="$2"
    local checklist_msg="$3"
    local default_on="$4"
    local confirm_msg="$5"

    local status_core="$default_on"
    local status_jvim="$default_on"
    local status_llama="$default_on"

    if [ "$action" = "install" ]; then
        check_jenova_core && status_core="off"
        check_jvim && status_jvim="off"
        check_llama && status_llama="off"
    fi

    if ! $DIALOG --clear --title "$title" \
        --checklist "$checklist_msg" 15 65 3 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (bundled)" "$status_jvim" \
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
        local msg="${confirm_msg:-Are you sure you want to $action $item?}"
        local dialog_args=""
        [ "$action" = "uninstall" ] && dialog_args="--defaultno"

        if $DIALOG $dialog_args --yesno "$msg" 10 60; then
            echo "${action^}ing $item..."
            if case "$action" in
                "install")   case "$item" in "Jenova_Core") install_jenova_core ;; "jvim") install_jvim ;; "llama.cpp") install_llama ;; *) false ;; esac ;;
                "update")    case "$item" in "Jenova_Core") update_jenova_core  ;; "jvim") update_jvim  ;; "llama.cpp") update_llama  ;; *) false ;; esac ;;
                "uninstall") case "$item" in "Jenova_Core") uninstall_jenova_core ;; "jvim") uninstall_jvim ;; "llama.cpp") uninstall_llama ;; *) false ;; esac ;;
            esac; then
                echo "Finished ${action}ing $item. Press any key to continue."
            else
                echo "Failed to $action $item. Press any key to continue."
            fi
            read -n 1 -s -r
        else
            echo "Skipping $item $action..."
        fi
    done
    show_main_menu
}

show_install_menu() {
    show_action_menu "install" "Install Jenova Components" "Select components to install (already installed items are unchecked):" "on"
}

show_update_menu() {
    show_action_menu "update" "Update Jenova Components" "Select components to update:" "on"
}

show_uninstall_menu() {
    show_action_menu "uninstall" "Uninstall Jenova Components" "Select components to uninstall:" "off" "Are you absolutely sure you want to uninstall %s? This may remove configuration and binaries."
}

# --- Action Implementations ---
install_jenova_core() {
    echo "Installing Jenova Core..."
    "$JENOVA_ROOT/scripts/install.sh"
}
install_jvim() {
    echo "Building in-tree jvim..."
    "$MAKE" -C "$JENOVA_ROOT" jvim
}
install_llama() {
    echo "Installing llama.cpp..."
    "$JENOVA_ROOT/bin/build-llama-jenova"
}

update_jenova_core() {
    echo "Updating Jenova Core..."
    "$JENOVA_ROOT/scripts/update.sh"
}
update_jvim() {
    echo "Updating jvim (in-tree)..."
    git -C "$JENOVA_ROOT" pull --ff-only || true
    if $DIALOG --yesno "Rebuild jvim now?" 8 50; then
        "$MAKE" -C "$JENOVA_ROOT" jvim
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
    "$JENOVA_ROOT/scripts/uninstall.sh"
}
uninstall_jvim() {
    echo "Removing in-tree jvim build artifacts..."
    rm -rf "$JENOVA_ROOT/jvim/build" "$JENOVA_ROOT/jvim/install"
    echo "jvim build artifacts removed."
}
uninstall_llama() {
    echo "Uninstalling llama.cpp..."
    rm -rf "$JENOVA_ROOT/llama.cpp/build"
    echo "llama.cpp build removed."
}

# Start TUI loop
show_main_menu
