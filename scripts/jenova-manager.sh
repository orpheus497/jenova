#!/usr/bin/env bash
# jenova-manager.sh: TUI manager for this monorepo
#
# Pure-bash implementation using Kanagawa True Color aesthetic.
# All components — Jenova Core (backend + scripts), the bundled jvim
# editor, and llama.cpp — live inside this repository. This manager
# dispatches install / update / uninstall actions to the in-tree
# Makefile targets and helper scripts. Nothing is cloned from external repos.

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
export JENOVA_ROOT

# Prefer GNU make (gmake) on FreeBSD; falls back to system make.
if command -v gmake >/dev/null 2>&1; then
    MAKE="gmake"
else
    MAKE="make"
fi

# --- Colors (Kanagawa & Royal Purple) ---
ESC=$'\e'
BG="${ESC}[48;2;31;31;40m"
FG="${ESC}[38;2;220;215;186m"
SEL_BG="${ESC}[48;2;45;79;103m"
GREEN="${ESC}[38;2;118;148;106m"
RED="${ESC}[38;2;195;64;67m"
BLUE="${ESC}[38;2;126;156;216m"
YELLOW="${ESC}[38;2;192;163;110m"
PURPLE="${ESC}[38;2;120;81;169m"
BOLD="${ESC}[1m"
RESET="${ESC}[0m"
CLEAR="${ESC}[H${ESC}[2J${BG}${FG}"

# --- Component detection ---

check_jvim() {
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

# --- Pure Bash UI Helpers ---

enter_alt_screen() { printf "%s[?1049h" "$ESC"; }
exit_alt_screen() { printf "%s[?1049l" "$ESC"; }
hide_cursor() { printf "%s[?25l" "$ESC"; }
show_cursor() { printf "%s[?25h" "$ESC"; }

cleanup() {
    show_cursor
    exit_alt_screen
    printf "%s" "$RESET"
}
trap cleanup EXIT INT TERM

get_width() {
    local w
    w=$(tput cols 2>/dev/null || echo 80)
    w=$((w - 4))
    if [ "$w" -gt 70 ]; then w=70; fi
    if [ "$w" -lt 40 ]; then w=40; fi
    echo "$w"
}

draw_box() {
    local title="$1"
    local width="$2"
    printf "%s╭" "$PURPLE"
    for ((i=0; i<width-2; i++)); do printf "─"; done
    printf "╮%s\n" "$FG"
    printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$BOLD$YELLOW" "$((width-4))" "$title" "$RESET$BG" "$PURPLE" "$FG"
    printf "%s├" "$PURPLE"
    for ((i=0; i<width-2; i++)); do printf "─"; done
    printf "┤%s\n" "$FG"
}

draw_box_bottom() {
    local width="$1"
    printf "%s╰" "$PURPLE"
    for ((i=0; i<width-2; i++)); do printf "─"; done
    printf "╯%s\n" "$RESET"
}

# Returns 0-based index of selected item in global $MENU_CHOICE
interactive_menu() {
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local count=${#options[@]}
    
    hide_cursor
    while true; do
        local WIDTH=$(get_width)
        printf "%s" "$CLEAR"
        echo ""
        draw_box "$title" "$WIDTH"
        
        for ((i=0; i<count; i++)); do
            if [ $i -eq $selected ]; then
                printf "%s│%s  > %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$FG" "$((WIDTH-7))" "${options[$i]}" "$RESET$BG" "$PURPLE" "$FG"
            else
                printf "%s│%s    %-*s %s%s│%s\n" "$PURPLE" "$BG$FG" "$((WIDTH-7))" "${options[$i]}" "$RESET$BG" "$PURPLE" "$FG"
            fi
        done
        draw_box_bottom "$WIDTH"
        
        read -rsn1 key
        if [[ $key == "" ]]; then
            break # Enter
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A')
                    selected=$((selected - 1))
                    if [ $selected -lt 0 ]; then selected=$((count-1)); fi
                    ;;
                '[B')
                    selected=$((selected + 1))
                    if [ $selected -ge $count ]; then selected=0; fi
                    ;;
            esac
        fi
    done
    MENU_CHOICE=$selected
}

# Returns choices array in global $CHECKLIST_CHOICES
interactive_checklist() {
    local title="$1"
    local desc="$2"
    shift 2
    
    local options=()
    local states=()
    local ids=()
    
    while [ $# -gt 0 ]; do
        ids+=("$1")
        options+=("$2")
        states+=("$3")
        shift 3
    done
    
    local selected=0
    local count=${#options[@]}
    
    hide_cursor
    while true; do
        local WIDTH=$(get_width)
        printf "%s" "$CLEAR"
        echo ""
        draw_box "$title" "$WIDTH"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "$desc" "$RESET$BG" "$PURPLE" "$FG"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "" "$RESET$BG" "$PURPLE" "$FG"
        
        for ((i=0; i<count; i++)); do
            local mark=" "
            [ "${states[$i]}" = "on" ] && mark="X"
            
            if [ $i -eq $selected ]; then
                printf "%s│%s  > [%s] %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$FG" "$mark" "$((WIDTH-11))" "${options[$i]}" "$RESET$BG" "$PURPLE" "$FG"
            else
                printf "%s│%s    [%s] %-*s %s%s│%s\n" "$PURPLE" "$BG$FG" "$mark" "$((WIDTH-11))" "${options[$i]}" "$RESET$BG" "$PURPLE" "$FG"
            fi
        done
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "" "$RESET$BG" "$PURPLE" "$FG"
        
        if [ $selected -eq $count ]; then
            printf "%s│%s  > [ Confirm ] %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$GREEN" "$((WIDTH-19))" "" "$RESET$BG" "$PURPLE" "$FG"
        else
            printf "%s│%s    [ Confirm ] %-*s %s%s│%s\n" "$PURPLE" "$BG$GREEN" "$((WIDTH-19))" "" "$RESET$BG" "$PURPLE" "$FG"
        fi
        if [ $selected -eq $((count+1)) ]; then
            printf "%s│%s  > [ Cancel ]  %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$RED" "$((WIDTH-19))" "" "$RESET$BG" "$PURPLE" "$FG"
        else
            printf "%s│%s    [ Cancel ]  %-*s %s%s│%s\n" "$PURPLE" "$BG$RED" "$((WIDTH-19))" "" "$RESET$BG" "$PURPLE" "$FG"
        fi
        
        draw_box_bottom "$WIDTH"
        
        read -rsn1 key
        if [[ $key == " " ]]; then
            if [ $selected -lt $count ]; then
                if [ "${states[$selected]}" = "on" ]; then
                    states[$selected]="off"
                else
                    states[$selected]="on"
                fi
            fi
        elif [[ $key == "" ]]; then
            if [ $selected -lt $count ]; then
                if [ "${states[$selected]}" = "on" ]; then
                    states[$selected]="off"
                else
                    states[$selected]="on"
                fi
            elif [ $selected -eq $count ]; then
                # Confirm
                CHECKLIST_CHOICES=()
                for ((i=0; i<count; i++)); do
                    if [ "${states[$i]}" = "on" ]; then
                        CHECKLIST_CHOICES+=("${ids[$i]}")
                    fi
                done
                break
            elif [ $selected -eq $((count+1)) ]; then
                # Cancel
                CHECKLIST_CHOICES=("CANCEL")
                break
            fi
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A')
                    selected=$((selected - 1))
                    if [ $selected -lt 0 ]; then selected=$((count+1)); fi
                    ;;
                '[B')
                    selected=$((selected + 1))
                    if [ $selected -gt $((count+1)) ]; then selected=0; fi
                    ;;
            esac
        fi
    done
}

confirm_prompt() {
    local msg="$1"
    local defaultno="$2"
    
    local sel=0
    [ "$defaultno" = "1" ] && sel=1
    
    hide_cursor
    while true; do
        local WIDTH=$(get_width)
        printf "%s\n" "$CLEAR"
        echo ""
        draw_box "Confirmation" "$WIDTH"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "$msg" "$RESET$BG" "$PURPLE" "$FG"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "" "$RESET$BG" "$PURPLE" "$FG"
        
        local yes_str="   [ Yes ]   "
        local no_str="   [ No ]    "
        if [ $sel -eq 0 ]; then
            yes_str="$SEL_BG$GREEN > [ Yes ] < $RESET$BG"
            no_str="$BG$RED   [ No ]    $RESET$BG"
        else
            yes_str="$BG$GREEN   [ Yes ]   $RESET$BG"
            no_str="$SEL_BG$RED > [ No ] <  $RESET$BG"
        fi
        
        printf "%s│%s %s%s%-*s %s%s│%s\n" "$PURPLE" "$BG" "$yes_str" "$no_str" "$((WIDTH-30))" "" "$RESET$BG" "$PURPLE" "$FG"
        draw_box_bottom "$WIDTH"
        
        read -rsn1 key
        if [[ $key == "" ]]; then
            break
        elif [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[C'|'[D')
                    sel=$((1 - sel))
                    ;;
            esac
        fi
    done
    return $sel
}

# --- Action Implementations ---
install_jenova_core() {
    printf "%s%sInstalling Jenova Core...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/install.sh"
}
install_jvim() {
    printf "%s%sBuilding in-tree jvim...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$MAKE" -C "$JENOVA_ROOT" jvim
}
install_llama() {
    printf "%s%sInstalling llama.cpp...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/bin/build-llama-jenova"
}

update_jenova_core() {
    printf "%s%sUpdating Jenova Core...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh"
}
update_jvim() {
    printf "%s%sUpdating jvim (in-tree)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    git -C "$JENOVA_ROOT" pull --ff-only || true
    if confirm_prompt "Rebuild jvim now?" "0"; then
        exit_alt_screen
        "$MAKE" -C "$JENOVA_ROOT" jvim
        enter_alt_screen
    fi
}
update_llama() {
    printf "%s%sUpdating llama.cpp...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    cd "$JENOVA_ROOT/llama.cpp" || { echo "Cannot access llama.cpp directory at $JENOVA_ROOT/llama.cpp"; return 1; }
    git pull --ff-only origin master
    if confirm_prompt "Do you want to rebuild llama.cpp?" "0"; then
        exit_alt_screen
        "$JENOVA_ROOT/bin/build-llama-jenova"
        enter_alt_screen
    fi
}

uninstall_jenova_core() {
    printf "%s%sUninstalling Jenova Core...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/uninstall.sh"
}
uninstall_jvim() {
    printf "%s%sRemoving in-tree jvim build artifacts...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    rm -rf "$JENOVA_ROOT/jvim/build" "$JENOVA_ROOT/jvim/install"
    echo "jvim build artifacts removed."
}
uninstall_llama() {
    printf "%s%sUninstalling llama.cpp...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    rm -rf "$JENOVA_ROOT/llama.cpp/build"
    echo "llama.cpp build removed."
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

    interactive_checklist "$title" "$checklist_msg" \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (bundled)" "$status_jvim" \
        "llama.cpp" "Inference engine" "$status_llama"
        
    if [ "${CHECKLIST_CHOICES[0]}" = "CANCEL" ] || [ ${#CHECKLIST_CHOICES[@]} -eq 0 ]; then
        return
    fi

    printf "%s" "$RESET$CLEAR"
    for item in "${CHECKLIST_CHOICES[@]}"; do
        local msg
        if [ -n "$confirm_msg" ]; then
            msg=$(printf "$confirm_msg" "$item")
        else
            msg="Are you sure you want to $action $item?"
        fi
        
        local defaultno="0"
        [ "$action" = "uninstall" ] && defaultno="1"

        if confirm_prompt "$msg" "$defaultno"; then
            exit_alt_screen
            printf "%s\n" "$RESET$CLEAR"
            _cap_action=$(echo "$action" | awk '{print toupper(substr($0,1,1))tolower(substr($0,2))}')
            echo "${_cap_action}ing $item..."

            local suffix
            case "$item" in
                "Jenova_Core") suffix="jenova_core" ;;
                "jvim")        suffix="jvim" ;;
                "llama.cpp")   suffix="llama" ;;
                *)             suffix="unknown" ;;
            esac

            if [ "$suffix" != "unknown" ] && "${action}_${suffix}"; then
                printf "\n%sFinished %sing %s. Press any key to continue.%s" "$GREEN" "$action" "$item" "$RESET"
            else
                printf "\n%sFailed to %s %s. Press any key to continue.%s" "$RED" "$action" "$item" "$RESET"
            fi
            read -n 1 -s -r
            enter_alt_screen
        else
            exit_alt_screen
            printf "%sSkipping %s %s...%s\n" "$YELLOW" "$item" "$action" "$RESET"
            sleep 1
            enter_alt_screen
        fi
    done
}

show_install_menu() {
    show_action_menu "install" "Install Jenova Components" "Select components to install (already installed are unchecked):" "on" ""
}

show_update_menu() {
    show_action_menu "update" "Update Jenova Components" "Select components to update:" "on" ""
}

show_uninstall_menu() {
    show_action_menu "uninstall" "Uninstall Jenova Components" "Select components to uninstall:" "off" "Are you absolutely sure you want to uninstall %s? This may remove configuration and binaries."
}

show_main_menu() {
    enter_alt_screen
    while true; do
        interactive_menu "Jenova Manager" \
            "Install components" \
            "Update components" \
            "Uninstall components" \
            "Exit"
            
        case "$MENU_CHOICE" in
            0) show_install_menu ;;
            1) show_update_menu ;;
            2) show_uninstall_menu ;;
            3) cleanup; exit 0 ;;
        esac
    done
}

# Start TUI loop
show_main_menu
