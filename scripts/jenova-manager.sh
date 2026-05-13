#!/bin/sh
# jenova-manager.sh: TUI manager for this monorepo
# Pure POSIX shell implementation for maximum compatibility (FreeBSD/Linux/macOS).

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
export JENOVA_ROOT

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

if command -v gmake >/dev/null 2>&1; then
    MAKE="gmake"
else
    MAKE="make"
fi

# --- Colors (Kanagawa & Royal Purple) ---
ESC=$(printf '\033')
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
    resolved_path="${LLAMA_SERVER:-}"
    resolved_build_dir="${JENOVA_BUILD_DIR:-}"

    for config_file in \
        "$JENOVA_ROOT/etc/jenova.local.conf" \
        "$JENOVA_ROOT/llama.cpp/build/jenova.local.conf"
    do
        if [ -f "$config_file" ]; then
            if [ -z "$resolved_path" ]; then
                resolved_path="$(
                    JENOVA_ROOT="$JENOVA_ROOT" sh -c '
                        . "$1" >/dev/null 2>&1 || exit 0
                        printf "%s" "${LLAMA_SERVER:-}"
                    ' sh "$config_file"
                )"
            fi

            if [ -z "$resolved_build_dir" ]; then
                resolved_build_dir="$(
                    JENOVA_ROOT="$JENOVA_ROOT" sh -c '
                        . "$1" >/dev/null 2>&1 || exit 0
                        printf "%s" "${JENOVA_BUILD_DIR:-}"
                    ' sh "$config_file"
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
    llama_server="$(resolve_llama_server_path)"
    [ -f "$llama_server" ]
}

check_jenova_core() {
    installed_path="$(command -v jenova-ca 2>/dev/null)" || return 1
    [ -n "$installed_path" ] || return 1
    [ -x "$JENOVA_ROOT/bin/jenova-ca" ] || return 1
    # Very basic path comparison for POSIX shell compatibility
    [ "$(basename "$installed_path")" = "jenova-ca" ]
}

# --- Pure POSIX UI Helpers ---
enter_alt_screen() { printf "%s[?1049h" "$ESC"; }
exit_alt_screen() { printf "%s[?1049l" "$ESC"; }
hide_cursor() { printf "%s[?25l" "$ESC"; }
show_cursor() { printf "%s[?25h" "$ESC"; }

cleanup() {
    show_cursor
    exit_alt_screen
    printf "%s" "$RESET"
    # Restore terminal
    stty sane 2>/dev/null || true
}
trap cleanup EXIT INT TERM

get_width() {
    w=$(tput cols 2>/dev/null || echo 80)
    w=$((w - 4))
    if [ "$w" -gt 70 ]; then w=70; fi
    if [ "$w" -lt 40 ]; then w=40; fi
    echo "$w"
}

draw_box() {
    title="$1"
    width="$2"
    printf "%s╭" "$PURPLE"
    i=0; while [ $i -lt $((width-2)) ]; do printf "─"; i=$((i+1)); done
    printf "╮%s\n" "$FG"
    printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$BOLD$YELLOW" "$((width-4))" "$title" "$RESET$BG" "$PURPLE" "$FG"
    printf "%s├" "$PURPLE"
    i=0; while [ $i -lt $((width-2)) ]; do printf "─"; i=$((i+1)); done
    printf "┤%s\n" "$FG"
}

draw_box_bottom() {
    width="$1"
    printf "%s╰" "$PURPLE"
    i=0; while [ $i -lt $((width-2)) ]; do printf "─"; i=$((i+1)); done
    printf "╯%s\n" "$RESET"
}

_RAW_MODE=0
_OLD_TTY=""

setup_tty() {
    _OLD_TTY=$(stty -g)
    stty -icanon -echo min 1 time 0
    _RAW_MODE=1
}

restore_tty() {
    if [ "$_RAW_MODE" = "1" ]; then
        stty "$_OLD_TTY"
        _RAW_MODE=0
    fi
}

get_key() {
    if [ "$_RAW_MODE" = "1" ]; then
        c1=$(dd bs=1 count=1 2>/dev/null)
        case "$c1" in
            "$(printf '\033')")
                stty min 0 time 1
                c2=$(dd bs=1 count=1 2>/dev/null)
                if [ "$c2" = "[" ] || [ "$c2" = "O" ]; then
                    c3=$(dd bs=1 count=1 2>/dev/null)
                    printf "ESC%s%s\n" "$c2" "$c3"
                else
                    printf "ESC\n"
                fi
                stty min 1 time 0
                ;;
            *)
                printf "%s\n" "$c1"
                ;;
        esac
    else
        old_tty=$(stty -g)
        stty -icanon -echo min 1 time 0
        c1=$(dd bs=1 count=1 2>/dev/null)
        case "$c1" in
            "$(printf '\033')")
                stty min 0 time 1
                c2=$(dd bs=1 count=1 2>/dev/null)
                if [ "$c2" = "[" ] || [ "$c2" = "O" ]; then
                    c3=$(dd bs=1 count=1 2>/dev/null)
                    printf "ESC%s%s\n" "$c2" "$c3"
                else
                    printf "ESC\n"
                fi
                ;;
            *)
                printf "%s\n" "$c1"
                ;;
        esac
        stty "$old_tty"
    fi
}

interactive_menu() {
    title="$1"
    shift
    
    count=0
    for opt in "$@"; do
        eval "menu_opt_$count='$(printf '%s' "$opt" | sed "s/'/'\\\\''/g")'"
        count=$((count + 1))
    done
    
    selected=0
    
    hide_cursor
    setup_tty
    while true; do
        WIDTH=$(get_width)
        printf "%s\n" "$CLEAR"
        echo ""
        draw_box "$title" "$WIDTH"
        
        i=0
        while [ $i -lt $count ]; do
            eval "opt=\"\$menu_opt_$i\""
            if [ $i -eq $selected ]; then
                printf "%s│%s  > %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$FG" "$((WIDTH-7))" "$opt" "$RESET$BG" "$PURPLE" "$FG"
            else
                printf "%s│%s    %-*s %s%s│%s\n" "$PURPLE" "$BG$FG" "$((WIDTH-7))" "$opt" "$RESET$BG" "$PURPLE" "$FG"
            fi
            i=$((i + 1))
        done
        draw_box_bottom "$WIDTH"
        
        key=$(get_key)
        if [ "$key" = "" ] || [ "$key" = "$(printf '\r')" ] || [ "$key" = "$(printf '\n')" ]; then
            break
        elif [ "$key" = "ESC[A" ]; then
            selected=$((selected - 1))
            if [ $selected -lt 0 ]; then selected=$((count-1)); fi
        elif [ "$key" = "ESC[B" ]; then
            selected=$((selected + 1))
            if [ $selected -ge $count ]; then selected=0; fi
        fi
    done
    restore_tty
    MENU_CHOICE=$selected
}

interactive_checklist() {
    title="$1"
    desc="$2"
    shift 2
    
    count=0
    while [ $# -gt 0 ]; do
        eval "check_id_$count='$(printf '%s' "$1" | sed "s/'/'\\\\''/g")'"
        eval "check_lbl_$count='$(printf '%s' "$2" | sed "s/'/'\\\\''/g")'"
        eval "check_st_$count='$(printf '%s' "$3" | sed "s/'/'\\\\''/g")'"
        count=$((count + 1))
        shift 3
    done
    
    selected=0
    
    hide_cursor
    setup_tty
    while true; do
        WIDTH=$(get_width)
        printf "%s\n" "$CLEAR"
        echo ""
        draw_box "$title" "$WIDTH"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "$desc" "$RESET$BG" "$PURPLE" "$FG"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "" "$RESET$BG" "$PURPLE" "$FG"
        
        i=0
        while [ $i -lt $count ]; do
            eval "lbl=\"\$check_lbl_$i\""
            eval "st=\"\$check_st_$i\""
            
            mark=" "
            [ "$st" = "on" ] && mark="X"
            
            if [ $i -eq $selected ]; then
                printf "%s│%s  > [%s] %-*s %s%s│%s\n" "$PURPLE" "$SEL_BG$FG" "$mark" "$((WIDTH-11))" "$lbl" "$RESET$BG" "$PURPLE" "$FG"
            else
                printf "%s│%s    [%s] %-*s %s%s│%s\n" "$PURPLE" "$BG$FG" "$mark" "$((WIDTH-11))" "$lbl" "$RESET$BG" "$PURPLE" "$FG"
            fi
            i=$((i + 1))
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
        
        key=$(get_key)
        if [ "$key" = " " ]; then
            if [ $selected -lt $count ]; then
                eval "st=\"\$check_st_$selected\""
                if [ "$st" = "on" ]; then
                    eval "check_st_$selected=off"
                else
                    eval "check_st_$selected=on"
                fi
            fi
        elif [ "$key" = "" ] || [ "$key" = "$(printf '\r')" ] || [ "$key" = "$(printf '\n')" ]; then
            if [ $selected -lt $count ]; then
                eval "st=\"\$check_st_$selected\""
                if [ "$st" = "on" ]; then
                    eval "check_st_$selected=off"
                else
                    eval "check_st_$selected=on"
                fi
            elif [ $selected -eq $count ]; then
                CHECKLIST_COUNT=0
                i=0
                while [ $i -lt $count ]; do
                    eval "st=\"\$check_st_$i\""
                    if [ "$st" = "on" ]; then
                        eval "id=\"\$check_id_$i\""
                        eval "CHECKLIST_CHOICES_$CHECKLIST_COUNT='$(printf '%s' "$id" | sed "s/'/'\\\\''/g")'"
                        CHECKLIST_COUNT=$((CHECKLIST_COUNT + 1))
                    fi
                    i=$((i + 1))
                done
                break
            elif [ $selected -eq $((count+1)) ]; then
                eval "CHECKLIST_CHOICES_0=CANCEL"
                CHECKLIST_COUNT=1
                break
            fi
        elif [ "$key" = "ESC[A" ]; then
            selected=$((selected - 1))
            if [ $selected -lt 0 ]; then selected=$((count+1)); fi
        elif [ "$key" = "ESC[B" ]; then
            selected=$((selected + 1))
            if [ $selected -gt $((count+1)) ]; then selected=0; fi
        fi
    done
    restore_tty
}

confirm_prompt() {
    msg="$1"
    defaultno="$2"
    
    sel=0
    [ "$defaultno" = "1" ] && sel=1
    
    hide_cursor
    setup_tty
    while true; do
        WIDTH=$(get_width)
        printf "%s\n" "$CLEAR"
        echo ""
        draw_box "Confirmation" "$WIDTH"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "$msg" "$RESET$BG" "$PURPLE" "$FG"
        printf "%s│%s %-*s %s%s│%s\n" "$PURPLE" "$FG" "$((WIDTH-4))" "" "$RESET$BG" "$PURPLE" "$FG"
        
        yes_str="   [ Yes ]   "
        no_str="   [ No ]    "
        if [ $sel -eq 0 ]; then
            yes_str="$SEL_BG$GREEN > [ Yes ] < $RESET$BG"
            no_str="$BG$RED   [ No ]    $RESET$BG"
        else
            yes_str="$BG$GREEN   [ Yes ]   $RESET$BG"
            no_str="$SEL_BG$RED > [ No ] <  $RESET$BG"
        fi
        
        printf "%s│%s %s%s%-*s %s%s│%s\n" "$PURPLE" "$BG" "$yes_str" "$no_str" "$((WIDTH-30))" "" "$RESET$BG" "$PURPLE" "$FG"
        draw_box_bottom "$WIDTH"
        
        key=$(get_key)
        if [ "$key" = "" ] || [ "$key" = "$(printf '\r')" ] || [ "$key" = "$(printf '\n')" ]; then
            break
        elif [ "$key" = "ESC[C" ] || [ "$key" = "ESC[D" ]; then
            sel=$((1 - sel))
        fi
    done
    restore_tty
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
install_webui() {
    printf "%s%sBuilding Web UI...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$MAKE" -C "$JENOVA_ROOT" web
}
install_jenova_ui() {
    printf "%s%sBuilding jenova-ui (Desktop Manager)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$MAKE" -C "$JENOVA_ROOT" jenova-ui
}
install_mcsh() {
    printf "%s%sBuilding mcsh (Modern C Shell)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$MAKE" -C "$JENOVA_ROOT" mcsh
}

update_jenova_core() {
    printf "%s%sUpdating Jenova Core...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh"
}
update_jvim() {
    printf "%s%sUpdating jvim (in-tree)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh" --skip-rebuild --skip-nvim
}
update_llama() {
    printf "%s%sUpdating llama.cpp (dependency repo)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh" --skip-nvim --skip-jvim
}
update_webui() {
    printf "%s%sUpdating Web UI...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh" --web --skip-nvim --skip-rebuild --skip-jvim
}
update_jenova_ui() {
    printf "%s%sUpdating jenova-ui (Desktop Manager)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh" --ui --skip-nvim --skip-rebuild --skip-jvim
}
update_mcsh() {
    printf "%s%sUpdating mcsh (dependency repo)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/update.sh" --mcsh --skip-nvim --skip-rebuild --skip-jvim
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
uninstall_webui() {
    printf "%s%sRemoving Web UI build artifacts...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    rm -rf "$JENOVA_ROOT/public" "$JENOVA_ROOT/jca_web/node_modules"
    echo "Web UI build artifacts removed."
}
uninstall_jenova_ui() {
    printf "%s%sRemoving jenova-ui build artifacts...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    rm -f "$JENOVA_ROOT/jenova-ui/jenova-ui" "$JENOVA_ROOT/bin/jenova-ui"
    echo "jenova-ui build artifacts removed."
}
uninstall_mcsh() {
    printf "%s%sRemoving mcsh build artifacts...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    rm -rf "$JENOVA_ROOT/mcsh/build" "$JENOVA_ROOT/bin/mcsh"
    echo "mcsh build artifacts removed."
}

# --- Component detection (extended) ---
check_webui() { [ -f "$JENOVA_ROOT/public/bundle.js" ]; }
check_jenova_ui() { [ -x "$JENOVA_ROOT/bin/jenova-ui" ] || [ -x "$JENOVA_ROOT/jenova-ui/jenova-ui" ]; }
check_mcsh() { [ -x "$JENOVA_ROOT/bin/mcsh" ]; }

show_action_menu() {
    action="$1"
    title="$2"
    checklist_msg="$3"
    default_on="$4"
    confirm_msg="$5"

    status_core="$default_on"
    status_jvim="$default_on"
    status_llama="$default_on"
    status_webui="$default_on"
    status_jenova_ui="$default_on"
    status_mcsh="$default_on"

    if [ "$action" = "install" ]; then
        check_jenova_core && status_core="off"
        check_jvim && status_jvim="off"
        check_llama && status_llama="off"
        check_webui && status_webui="off"
        check_jenova_ui && status_jenova_ui="off"
        check_mcsh && status_mcsh="off"
    fi

    interactive_checklist "$title" "$checklist_msg" \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (bundled)" "$status_jvim" \
        "llama.cpp" "Inference engine" "$status_llama" \
        "WebUI" "Browser-based Workspaces UI" "$status_webui" \
        "jenova_ui" "Desktop Manager (tray + TUI)" "$status_jenova_ui" \
        "mcsh" "Modern C Shell" "$status_mcsh"
        
    eval "first_choice=\"\$CHECKLIST_CHOICES_0\""
    if [ "$first_choice" = "CANCEL" ] || [ "$CHECKLIST_COUNT" -eq 0 ]; then
        return
    fi

    printf "%s" "$RESET$CLEAR"
    
    i=0
    while [ $i -lt $CHECKLIST_COUNT ]; do
        eval "item=\"\$CHECKLIST_CHOICES_$i\""
        
        # Choice for Build vs Install if action is 'install'
        mode="build"
        if [ "$action" = "install" ]; then
            interactive_menu "Select Mode for $item" \
                "Build from source (Recommended for your hardware)" \
                "Quick Install (Deploy existing binaries if present)" \
                "Skip $item"
            case "$MENU_CHOICE" in
                0) mode="build" ;;
                1) mode="deploy" ;;
                *) i=$((i+1)); continue ;;
            esac
        fi

        msg="Are you sure you want to $action $item ($mode)?"
        [ -n "$confirm_msg" ] && msg="$(printf "$confirm_msg" "$item")"
        
        defaultno="0"
        [ "$action" = "uninstall" ] && defaultno="1"

        if confirm_prompt "$msg" "$defaultno"; then
            exit_alt_screen
            printf "%s\n" "$RESET$CLEAR"
            echo "Processing $action ($mode) on $item..."

            suffix="unknown"
            case "$item" in
                "Jenova_Core") suffix="jenova_core" ;;
                "jvim")        suffix="jvim" ;;
                "llama.cpp")   suffix="llama" ;;
                "WebUI")       suffix="webui" ;;
                "jenova_ui")   suffix="jenova_ui" ;;
                "mcsh")        suffix="mcsh" ;;
            esac

            if [ "$suffix" != "unknown" ]; then
                if [ "$mode" = "deploy" ]; then
                    # Quick install mode: just run install.sh with appropriate skip flags
                    # but ensure the component we want is NOT skipped.
                    case "$suffix" in
                        "jenova_core") "$JENOVA_ROOT/scripts/install.sh" --skip-jvim --skip-llama --skip-lsp ;;
                        "jvim")        "$JENOVA_ROOT/scripts/install.sh" --skip-config --skip-llama --skip-lsp ;;
                        "llama")       "$JENOVA_ROOT/scripts/install.sh" --skip-config --skip-jvim --skip-lsp ;;
                        *)             "${action}_${suffix}" ;; # Fallback for components without specific install.sh flags
                    esac
                    _ret=$?
                else
                    "${action}_${suffix}"
                    _ret=$?
                fi

                if [ "$_ret" = "0" ]; then
                    printf "\n%sFinished %s %s. Press any key to continue.%s" "$GREEN" "$action" "$item" "$RESET"
                else
                    printf "\n%sFailed to %s %s. Press any key to continue.%s" "$RED" "$action" "$item" "$RESET"
                fi
            fi
            get_key >/dev/null
            enter_alt_screen
        else
            exit_alt_screen
            printf "%sSkipping %s %s...%s\n" "$YELLOW" "$item" "$action" "$RESET"
            sleep 1
            enter_alt_screen
        fi
        
        i=$((i + 1))
    done
}

run_system_prep() {
    exit_alt_screen
    printf "%s%sRunning System Preparation...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    
    echo "1) Install Dependencies"
    if "$JENOVA_ROOT/scripts/install-dependencies.sh"; then
        echo "Dependencies installed."
    else
        echo "Dependency installation had warnings/errors."
    fi
    
    echo ""
    echo "2) Pre-flight Checks"
    "$JENOVA_ROOT/scripts/preflight-check.sh"
    
    printf "\nPress any key to continue..."
    get_key >/dev/null
    enter_alt_screen
}

run_model_downloader() {
    exit_alt_screen
    printf "%s%sRunning Model Downloader...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/model_dl.sh"
    printf "\nPress any key to continue..."
    get_key >/dev/null
    enter_alt_screen
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
            "System Preparation (Dependencies & Pre-flight)" \
            "Install Components" \
            "Update Components" \
            "Uninstall Components" \
            "Download AI Models" \
            "Exit"
            
        case "$MENU_CHOICE" in
            0) run_system_prep ;;
            1) show_install_menu ;;
            2) show_update_menu ;;
            3) show_uninstall_menu ;;
            4) run_model_downloader ;;
            5) cleanup; exit 0 ;;
        esac
    done
}

# Start TUI loop
show_main_menu
