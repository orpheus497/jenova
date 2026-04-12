#!/bin/bash
# jenova-manager.sh: TUI Manager for Jenova ecosystem

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")"
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

check_jvim() { command -v jvim >/dev/null 2>&1; }
check_jenova_cli() { command -v jenova-cli >/dev/null 2>&1; }
check_llama() { [ -f "$JENOVA_ROOT/llama.cpp/build/bin/llama-server" ]; }
check_jenova_core() { [ -x "$JENOVA_ROOT/bin/jenova-ca" ]; }

# Temporary file to store dialog selections
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT INT TERM

show_main_menu() {
    $DIALOG --clear --title "Jenova Manager" \
        --menu "Select an action:" 15 50 4 \
        1 "Install components" \
        2 "Update components" \
        3 "Uninstall components" \
        4 "Exit" 2> $TEMP_FILE

    if [ $? -ne 0 ]; then
        exit 0
    fi

    CHOICE=$(cat $TEMP_FILE)
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

    $DIALOG --clear --title "Install Jenova Components" \
        --checklist "Select components to install (already installed items are unchecked):" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (requires sudo)" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> $TEMP_FILE

    if [ $? -ne 0 ]; then
        show_main_menu
        return
    fi

    local selected=$(cat $TEMP_FILE | tr -d '"')
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --yesno "Are you sure you want to install $item?" 8 50; then
            echo "Installing $item..."
            # Placeholder for actual install commands
            case "$item" in
                "Jenova_Core") install_jenova_core ;;
                "jvim") install_jvim ;;
                "jenova-cli") install_jenova_cli ;;
                "llama.cpp") install_llama ;;
            esac
            echo "Finished installing $item. Press any key to continue."
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

    $DIALOG --clear --title "Update Jenova Components" \
        --checklist "Select components to update:" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> $TEMP_FILE

    if [ $? -ne 0 ]; then
        show_main_menu
        return
    fi

    local selected=$(cat $TEMP_FILE | tr -d '"')
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --yesno "Are you sure you want to update $item?" 8 50; then
            echo "Updating $item..."
            # Placeholder for actual update commands
            case "$item" in
                "Jenova_Core") update_jenova_core ;;
                "jvim") update_jvim ;;
                "jenova-cli") update_jenova_cli ;;
                "llama.cpp") update_llama ;;
            esac
            echo "Finished updating $item. Press any key to continue."
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

    $DIALOG --clear --title "Uninstall Jenova Components" \
        --checklist "Select components to uninstall:" 15 60 4 \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE" "$status_jvim" \
        "jenova-cli" "Terminal agent" "$status_cli" \
        "llama.cpp" "Inference engine" "$status_llama" 2> $TEMP_FILE

    if [ $? -ne 0 ]; then
        show_main_menu
        return
    fi

    local selected=$(cat $TEMP_FILE | tr -d '"')
    if [ -z "$selected" ]; then
        $DIALOG --msgbox "No components selected." 8 40
        show_main_menu
        return
    fi

    clear
    for item in $selected; do
        if $DIALOG --defaultno --yesno "Are you absolutely sure you want to uninstall $item? This may remove configuration and binaries." 10 60; then
            echo "Uninstalling $item..."
            # Placeholder for actual uninstall commands
            case "$item" in
                "Jenova_Core") uninstall_jenova_core ;;
                "jvim") uninstall_jvim ;;
                "jenova-cli") uninstall_jenova_cli ;;
                "llama.cpp") uninstall_llama ;;
            esac
            echo "Finished uninstalling $item. Press any key to continue."
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
    cd "$JENOVA_ROOT/.."
    git clone https://github.com/orpheus497/jvim.git || true
    cd jvim && make CMAKE_BUILD_TYPE=Release && sudo make install
}
install_jenova_cli() {
    echo "Installing jenova-cli..."
    cd "$JENOVA_ROOT/.."
    git clone https://github.com/orpheus497/cloda-codey-lua.git || true
    cd cloda-codey-lua && cargo build --release && sudo cp target/release/jenova-cli /usr/local/bin/
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
    cd "$JENOVA_ROOT/../jvim" || { echo "jvim directory not found"; return; }
    git pull --ff-only origin main || true
    if $DIALOG --yesno "Do you want to rebuild jvim?" 8 50; then
        make CMAKE_BUILD_TYPE=Release && sudo make install
    fi
}
update_jenova_cli() {
    echo "Updating jenova-cli..."
    cd "$JENOVA_ROOT/../cloda-codey-lua" || { echo "jenova-cli directory not found"; return; }
    git pull --ff-only origin main || true
    if $DIALOG --yesno "Do you want to rebuild jenova-cli?" 8 50; then
        cargo build --release && sudo cp target/release/jenova-cli /usr/local/bin/
    fi
}
update_llama() {
    echo "Updating llama.cpp..."
    cd "$JENOVA_ROOT/llama.cpp" || { echo "llama.cpp directory not found"; return; }
    git pull --ff-only origin master || true
    if $DIALOG --yesno "Do you want to rebuild llama.cpp?" 8 50; then
        "$JENOVA_ROOT/bin/build-llama-jenova"
    fi
}

uninstall_jenova_core() {
    echo "Uninstalling Jenova Core..."
    "$JENOVA_ROOT/uninstall.sh" --yes
}
uninstall_jvim() {
    echo "Uninstalling jvim..."
    cd "$JENOVA_ROOT/../jvim" || { echo "jvim directory not found"; return; }
    sudo make uninstall
}
uninstall_jenova_cli() {
    echo "Uninstalling jenova-cli..."
    sudo rm -f /usr/local/bin/jenova-cli
    echo "jenova-cli removed."
}
uninstall_llama() {
    echo "Uninstalling llama.cpp..."
    rm -rf "$JENOVA_ROOT/llama.cpp/build"
    echo "llama.cpp build removed."
}

# Start TUI loop
show_main_menu
