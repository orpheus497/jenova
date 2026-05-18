#!/bin/sh
# install-jenova.sh: Streamlined Jenova Installation & Management for All Platforms
#
# Intelligent, end-to-end installation with OS detection, dependency management,
# graceful skipping, and user-friendly notifications.
#
# Usage: ./install-jenova.sh [command] [options]
#
# Commands:
#   install     (Default) Build and deploy Jenova to $JENOVA_HOME
#   uninstall   Remove Jenova binaries and config (preserves workspaces)
#   update      Update source code and rebuild all components
#   status      Check system compatibility and installation status
#   tui         Launch the interactive TUI manager
#   help        Show this help message
#
# Options:
#   --minimal   Install only essential components (no Web UI, no models)
#   --full      Install everything including models (default)
#   --interactive Prompt for confirmation before major steps
#   --force     Overwrite existing files/configs without prompting
#
# This script automatically:
#   ✓ Detects your OS and package manager
#   ✓ Installs all required system dependencies
#   ✓ Builds Jenova components (llama.cpp, jvim, mcsh)
#   ✓ Deploys to your system
#   ✓ Downloads AI models (unless --minimal)
#   ✓ Verifies everything works
#
# Supported platforms:
#   • FreeBSD (pkg)
#   • Linux: Arch (pacman/yay), Debian/Ubuntu (apt), Fedora/RHEL (dnf)
#   • macOS (Homebrew)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
JENOVA_ROOT="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
export JENOVA_ROOT

# Load environment detection
if [ -f "$JENOVA_ROOT/lib/detect-env.sh" ]; then
    . "$JENOVA_ROOT/lib/detect-env.sh"
else
    echo "Error: lib/detect-env.sh not found." >&2
    exit 1
fi

# Default JENOVA_HOME if not set
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"; export JENOVA_HOME

# Colors
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    GREEN=$(printf '\033[38;2;118;148;106m')
    YELLOW=$(printf '\033[38;2;192;163;110m')
    RED=$(printf '\033[38;2;195;64;67m')
    BLUE=$(printf '\033[38;2;126;156;216m')
    PURPLE=$(printf '\033[38;2;120;81;169m')
    NC=$(printf '\033[0m')
else
    BOLD="" GREEN="" YELLOW="" RED="" BLUE="" PURPLE="" NC=""
fi

# Helper functions
print_header() {
    echo ""
    echo "${BOLD}${PURPLE}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${PURPLE}║ %-56s ║${NC}\n" "$1"
    echo "${BOLD}${PURPLE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() { printf "${GREEN}▶${NC} %s\n" "$1"; }
print_success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
print_warning() { printf "${YELLOW}⚠${NC} %s\n" "$1"; }
print_error() { printf "${RED}✗${NC} %s\n" "$1"; }
print_info() { printf "${BLUE}ℹ${NC} %s\n" "$1"; }

show_help() {
    print_header "Jenova Management Utility"
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install     Build and deploy Jenova to $JENOVA_HOME"
    echo "  uninstall   Remove Jenova binaries and config (preserves workspaces)"
    echo "  update      Update source code and rebuild all components"
    echo "  status      Verify installation and system environment"
    echo "  tui         Launch the interactive TUI manager"
    echo "  help        Show this help message"
    echo ""
    echo "Options:"
    echo "  --minimal   Install only essential components (no Web UI, no models)"
    echo "  --full      Install everything including models (default)"
    echo "  --interactive Prompt for confirmation before major steps"
    echo "  --force     Overwrite existing files/configs without prompting"
}

ensure_external_repos() {
    print_step "Checking external components..."
    mkdir -p "$JENOVA_ROOT/external"
    
    # llama.cpp
    if [ ! -d "$JENOVA_ROOT/external/llama.cpp/.git" ]; then
        print_info "Cloning llama.cpp..."
        git clone https://github.com/orpheus497/llama.cpp-jca.git "$JENOVA_ROOT/external/llama.cpp"
    else
        print_success "llama.cpp found"
    fi

    # mcsh
    if [ ! -d "$JENOVA_ROOT/external/mcsh/.git" ]; then
        print_info "Cloning mcsh..."
        git clone https://github.com/orpheus497/mcsh.git "$JENOVA_ROOT/external/mcsh"
    else
        print_success "mcsh found"
    fi

    # SPIRV-Headers (FreeBSD)
    if [ "$JENOVA_OS" = "freebsd" ]; then
        if [ ! -d "$JENOVA_ROOT/external/SPIRV-Headers/.git" ]; then
            print_info "Cloning SPIRV-Headers..."
            git clone https://github.com/orpheus497/SPIRV-Headers.git "$JENOVA_ROOT/external/SPIRV-Headers"
        else
            print_success "SPIRV-Headers found"
        fi
    fi
}

cmd_install() {
    MINIMAL=0
    INTERACTIVE=0
    FORCE=""
    
    for arg in "$@"; do
        case "$arg" in
            --minimal) MINIMAL=1 ;;
            --full)    MINIMAL=0 ;;
            --interactive) INTERACTIVE=1 ;;
            --force)   FORCE="--force" ;;
        esac
    done

    print_header "Jenova Installation"
    
    # System check
    print_step "Detecting your system..."
    echo "  OS: $JENOVA_OS ($JENOVA_DISTRO)"
    echo "  CPU: $JENOVA_CPU_MODEL ($JENOVA_CPU_THREADS threads)"
    echo "  RAM: ${JENOVA_RAM_GIB}GB"
    
    # Disk space check
    REQUIRED_SPACE=20
    FREE_SPACE=$(df -kP "$JENOVA_ROOT" | tail -1 | awk '{print int($4 / 1048576)}')
    if [ "${FREE_SPACE:-0}" -lt "$REQUIRED_SPACE" ]; then
        print_warning "Low disk space: ${FREE_SPACE}GB free (recommended: ${REQUIRED_SPACE}GB+)"
    else
        print_success "Sufficient disk space: ${FREE_SPACE}GB free"
    fi

    ensure_external_repos
    
    # 1. Install dependencies
    print_step "Installing system dependencies..."
    "$JENOVA_ROOT/scripts/install-dependencies.sh"
    
    # 2. Pre-flight checks
    print_step "Running pre-flight checks..."
    set +e
    "$JENOVA_ROOT/scripts/preflight-check.sh"
    _preflight_status=$?
    set -e
    if [ "$_preflight_status" = "0" ]; then
        print_success "Pre-flight checks passed"
    elif [ "$_preflight_status" = "2" ]; then
        print_warning "Pre-flight checks passed with warnings"
    else
        print_error "Pre-flight checks failed"
        exit 1
    fi
    
    # 3. Build everything
    print_step "Building Jenova components..."
    if command -v gmake >/dev/null 2>&1; then
        MAKE_CMD="gmake"
    else
        MAKE_CMD="make"
    fi
    
    COMPONENTS="llama jvim mcsh jenova-ui"
    [ "$MINIMAL" = "0" ] && COMPONENTS="$COMPONENTS web"
    
    for component in $COMPONENTS; do
        print_info "Building $component..."
        if "$MAKE_CMD" "$component"; then
            print_success "$component built successfully"
        else
            if [ "$component" = "mcsh" ]; then
                print_warning "Failed to build $component (optional, continuing)"
            else
                print_error "Failed to build $component"
                exit 1
            fi
        fi
    done
    
    # 4. Deploy to JENOVA_HOME
    print_step "Deploying to $JENOVA_HOME..."
    _install_flags="$FORCE"
    if [ "$MINIMAL" = "1" ]; then
        # For minimal, we tell install.sh to skip model downloads if possible
        # Currently install.sh doesn't have a direct --skip-models, but we can 
        # pass --client-only if we want a TRULY minimal system (no llama),
        # but here we just want to avoid the interactive prompt.
        JENOVA_SKIP_MODELS=1; export JENOVA_SKIP_MODELS
    fi
    "$JENOVA_ROOT/scripts/install.sh" $_install_flags
    
    # 5. Verification
    print_step "Verifying installation..."
    "$JENOVA_ROOT/scripts/verify-install.sh" --full
    
    print_header "Installation Complete!"
    echo "🚀 ${BOLD}Quick Start:${NC}"
    echo "  jenova-tui      # Jenova Manager (Operational TUI)"
    echo "  jenova          # Full environment (editor + backend)"
    echo "  jvim            # Just the editor"
}

cmd_uninstall() {
    print_header "Uninstalling Jenova"
    "$JENOVA_ROOT/scripts/uninstall.sh" "$@"
}

cmd_update() {
    print_header "Updating Jenova"
    ensure_external_repos
    "$JENOVA_ROOT/scripts/update.sh" "$@"
}

cmd_status() {
    print_header "Jenova Status"
    "$JENOVA_ROOT/scripts/verify-install.sh" --full
}

# --- Main Logic ---

if [ $# -eq 0 ]; then
    if [ -t 1 ]; then
        exec "$JENOVA_ROOT/scripts/jenova-manager.sh"
    else
        show_help
        exit 0
    fi
fi

COMMAND="$1"
# Check if first arg is an option instead of a command
case "$COMMAND" in
    --*) COMMAND="install" ;;
    *) shift ;;
esac

case "$COMMAND" in
    install)    cmd_install "$@" ;;
    uninstall)  cmd_uninstall "$@" ;;
    update)     cmd_update "$@" ;;
    status|verify) cmd_status "$@" ;;
    tui)        exec "$JENOVA_ROOT/scripts/jenova-manager.sh" ;;
    help|--help|-h) show_help ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        show_help
        exit 1
        ;;
esac
