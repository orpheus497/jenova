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
        "$JENOVA_ROOT/external/llama.cpp/build/jenova.local.conf"
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
        printf '%s\n' "$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server"
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
    printf "%s%sInstalling external/llama.cpp...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
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



# --- Component detection (extended) ---
check_webui() { [ -f "$JENOVA_ROOT/public/bundle.js" ]; }
check_jenova_ui() { [ -x "$JENOVA_ROOT/bin/jenova-ui" ] || [ -x "$JENOVA_ROOT/jenova-ui/jenova-ui" ]; }

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

    if [ "$action" = "install" ]; then
        check_jenova_core && status_core="off"
        check_jvim && status_jvim="off"
        check_llama && status_llama="off"
        check_webui && status_webui="off"
        check_jenova_ui && status_jenova_ui="off"
    fi

    interactive_checklist "$title" "$checklist_msg" \
        "Jenova_Core" "Jenova CA and backend scripts" "$status_core" \
        "jvim" "Editor / IDE (bundled)" "$status_jvim" \
        "external/llama.cpp" "Inference engine" "$status_llama" \
        "WebUI" "Browser-based Workspaces UI" "$status_webui" \
        "jenova_ui" "Desktop Manager (tray + TUI)" "$status_jenova_ui"
        
    eval "first_choice=\"\$CHECKLIST_CHOICES_0\""
    if [ "$first_choice" = "CANCEL" ] || [ "$CHECKLIST_COUNT" -eq 0 ]; then
        return
    fi

    printf "%s" "$RESET$CLEAR"
    
    # Global setting for this session
    PULL_MODE="nopull"

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

        if confirm_prompt "$msg" "$defaultno"; then
            exit_alt_screen
            printf "%s\n" "$RESET$CLEAR"
            echo "Processing $action ($mode, strategy=$PULL_MODE) on $item..."

            suffix="unknown"
            case "$item" in
                "Jenova_Core") suffix="jenova_core" ;;
                "jvim")        suffix="jvim" ;;
                "external/llama.cpp")   suffix="llama" ;;
                "WebUI")       suffix="webui" ;;
                "jenova_ui")   suffix="jenova_ui" ;;
            esac

            if [ "$suffix" != "unknown" ]; then
                _extra_flags=""
                [ "$PULL_MODE" = "nopull" ] && _extra_flags="--no-pull"

                if [ "$mode" = "deploy" ]; then
                    # Quick install mode: just run install.sh with appropriate skip flags
                    # but ensure the component we want is NOT skipped.
                    case "$suffix" in
                        "jenova_core") "$JENOVA_ROOT/scripts/install.sh" --skip-jvim --skip-llama ;;
                        "jvim")        "$JENOVA_ROOT/scripts/install.sh" --skip-config --skip-llama ;;
                        "llama")       "$JENOVA_ROOT/scripts/install.sh" --skip-config --skip-jvim ;;
                        *)             "${action}_${suffix}" ;; # Fallback
                    esac
                    _ret=$?
                else
                    # Call the action function with potential extra flags
                    "${action}_${suffix}"
                    _ret=$?
                    if [ "$_ret" = "0" ] && [ "$action" = "install" ]; then
                        printf "\nDeploying %s after successful build...\n" "$item"
                        case "$suffix" in
                            "jvim")        "$JENOVA_ROOT/scripts/install.sh" --skip-llama ;;
                            "llama")       "$JENOVA_ROOT/scripts/install.sh" --skip-jvim ;;
                            "webui")       "$JENOVA_ROOT/scripts/install.sh" --skip-jvim --skip-llama ;;
                            "jenova_ui")   "$JENOVA_ROOT/scripts/install.sh" --skip-jvim --skip-llama ;;
                        esac
                        _ret=$?
                    fi
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

run_dependencies() {
    exit_alt_screen
    printf "%s%sInstalling OS Dependencies...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    
    if "$JENOVA_ROOT/scripts/install-dependencies.sh"; then
        echo "Dependencies installed."
    else
        echo "Dependency installation had warnings/errors."
    fi
    printf "\nPress any key to continue..."
    get_key >/dev/null
    enter_alt_screen
}

run_toolchain() {
    exit_alt_screen
    printf "%s%sInstalling Toolchain (LSPs, Formatters)...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    
    if "$JENOVA_ROOT/scripts/install-toolchain.sh"; then
        echo "Toolchain installed."
    else
        echo "Toolchain installation had warnings/errors."
    fi
    printf "\nPress any key to continue..."
    get_key >/dev/null
    enter_alt_screen
}

run_preflight() {
    exit_alt_screen
    printf "%s%sRunning Pre-flight Checks...%s\n" "$RESET" "$BOLD$GREEN" "$RESET"
    "$JENOVA_ROOT/scripts/preflight-check.sh"
    printf "\nPress any key to continue..."
    get_key >/dev/null
    enter_alt_screen
}

run_hardware_profile() {
    exit_alt_screen
    
    _profiles_str=$("$JENOVA_ROOT/hardware-profiles/detect-hardware.sh" --list || true)
    
    _count=0
    for _p in $_profiles_str; do
        eval "_prof_$_count='$_p'"
        _count=$((_count + 1))
    done
    
    enter_alt_screen
    while true; do
        set -- "Hardware Profile Selection" "Auto-detect and Apply Hardware Profile" "View Detection Report"
        i=0
        while [ $i -lt $_count ]; do
            eval "_p=\"\$_prof_$i\""
            set -- "$@" "Apply: $_p"
            i=$((i + 1))
        done
        set -- "$@" "Back"
        
        interactive_menu "$@"
        
        if [ "$MENU_CHOICE" = "0" ]; then
            exit_alt_screen
            "$JENOVA_ROOT/hardware-profiles/detect-hardware.sh" --apply
            printf "\nPress any key to continue..."
            get_key >/dev/null
            enter_alt_screen
        elif [ "$MENU_CHOICE" = "1" ]; then
            exit_alt_screen
            "$JENOVA_ROOT/hardware-profiles/detect-hardware.sh" --info
            printf "\nPress any key to continue..."
            get_key >/dev/null
            enter_alt_screen
        else
            if [ "$MENU_CHOICE" -eq $((_count + 2)) ]; then
                break
            else
                _prof_idx=$((MENU_CHOICE - 2))
                eval "_selected_prof=\"\$_prof_$_prof_idx\""
                exit_alt_screen
                printf "%s%sDeploying %s...%s\n" "$RESET" "$BOLD$GREEN" "$_selected_prof" "$RESET"
                "$JENOVA_ROOT/hardware-profiles/detect-hardware.sh" --apply-profile "$_selected_prof"
                
                # Check for tuning script and execute if present
                _tuning_script="$JENOVA_ROOT/hardware-profiles/$_selected_prof/jenova-setup"
                if [ -f "$_tuning_script" ]; then
                    printf "\nPress any key to continue to tuning prompt..."
                    get_key >/dev/null
                    enter_alt_screen
                    if confirm_prompt "This profile contains a system tuning script. Run it with sudo?" "0"; then
                        exit_alt_screen
                        sudo sh "$_tuning_script"
                    else
                        exit_alt_screen
                    fi
                fi
                
                printf "\nPress any key to continue..."
                get_key >/dev/null
                enter_alt_screen
            fi
        fi
    done
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


show_main_menu() {
    enter_alt_screen
    while true; do
        interactive_menu "Jenova Manager" \
            "Hardware Profile Selection" \
            "Install Dependencies (OS Packages)" \
            "Install Toolchain (LSPs, Formatters)" \
            "Pre-flight Checks" \
            "Build/Deploy Components" \
            "Download AI Models" \
            "Exit"
            
        case "$MENU_CHOICE" in
            0) run_hardware_profile ;;
            1) run_dependencies ;;
            2) run_toolchain ;;
            3) run_preflight ;;
            4) show_install_menu ;;
            5) run_model_downloader ;;
            6) cleanup; exit 0 ;;
        esac
    done
}

# Start TUI loop
show_main_menu
