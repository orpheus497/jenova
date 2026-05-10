#!/bin/sh
# install-jenova.sh: Streamlined Jenova Installation for All Platforms
#
# Intelligent, end-to-end installation with OS detection, dependency management,
# graceful skipping, and user-friendly notifications.
#
# Usage: ./install-jenova.sh [--help] [--dry-run] [--minimal] [--full]
#
# Options:
#   --help      Show this help message
#   --dry-run   Show what would be installed without making changes
#   --minimal   Install only essential components (no Web UI, no models)
#   --full      Install everything including models (default)
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

JENOVA_ROOT="$(dirname "$(realpath "$0")")"

# Parse arguments
DRY_RUN=0
MINIMAL=0
FULL=1

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --minimal)
            MINIMAL=1
            FULL=0
            ;;
        --full)
            MINIMAL=0
            FULL=1
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run '$0 --help' for usage information." >&2
            exit 1
            ;;
    esac
done

# Colors
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[0;33m')
    RED=$(printf '\033[0;31m')
    BLUE=$(printf '\033[0;34m')
    NC=$(printf '\033[0m')
else
    BOLD=""
    GREEN=""
    YELLOW=""
    RED=""
    BLUE=""
    NC=""
fi

# Helper functions
print_header() {
    echo ""
    echo "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${BLUE}║ %-56s ║${NC}\n" "$1"
    echo "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    printf "${GREEN}▶${NC} %s\n" "$1"
}

print_success() {
    printf "${GREEN}✓${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}⚠${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}✗${NC} %s\n" "$1"
}

print_info() {
    printf "${BLUE}ℹ${NC} %s\n" "$1"
}

# Check if we're in the right directory
if [ ! -f "$JENOVA_ROOT/Makefile" ] || [ ! -d "$JENOVA_ROOT/scripts" ]; then
    print_error "Please run this script from the Jenova repository root directory."
    exit 1
fi

# Load environment detection
. "$JENOVA_ROOT/lib/detect-env.sh"

print_header "Jenova Installation"

if [ "$DRY_RUN" = "1" ]; then
    print_info "DRY RUN MODE - No changes will be made"
    echo ""
fi

# OS and package manager detection
print_step "Detecting your system..."
echo "  OS: $JENOVA_OS ($JENOVA_DISTRO)"
echo "  Package Manager: $JENOVA_PKG_MGR"
echo "  CPU: $JENOVA_CPU_MODEL ($JENOVA_CPU_THREADS threads)"
echo "  RAM: ${JENOVA_RAM_GIB}GB"
echo "  Vulkan: $([ "$JENOVA_VULKAN_OK" = "1" ] && echo "Available" || echo "Not available")"

if [ "$JENOVA_PKG_MGR" = "none" ]; then
    print_error "No supported package manager detected on this system."
    echo ""
    echo "This could mean:"
    echo "  • You're running in a container/sandboxed environment (Flatpak, Docker, etc.)"
    echo "  • Your Linux distribution is not supported"
    echo "  • Package manager is not installed"
    echo ""
    echo "Jenova supports:"
    echo "  • FreeBSD (pkg)"
    echo "  • Linux: Arch (pacman/yay), Debian/Ubuntu (apt), Fedora/RHEL (dnf)"
    echo "  • macOS (Homebrew)"
    echo ""
    echo "Please install dependencies manually on your host system."
    echo "See: docs/installation/dependencies.md"
    echo ""
    echo "Or try the manual installation process:"
    echo "  ./scripts/preflight-check.sh --fix    # Attempt auto-fix"
    echo "  make                                 # Build components"
    echo "  make install                         # Deploy to system"
    exit 1
fi

print_success "System detection complete"
echo ""

# Check disk space
REQUIRED_SPACE=20  # GB
FREE_SPACE=$(df -kP "$JENOVA_ROOT" | awk 'NR==2 {print int($4 / 1048576)}')

if [ "${FREE_SPACE:-0}" -lt "$REQUIRED_SPACE" ]; then
    print_warning "Low disk space: ${FREE_SPACE}GB free (recommended: ${REQUIRED_SPACE}GB+)"
    echo "  Installation may fail or be slow. Consider freeing up space."
else
    print_success "Sufficient disk space: ${FREE_SPACE}GB free"
fi

echo ""

# Dependency installation
print_step "Installing system dependencies..."

if [ "$DRY_RUN" = "1" ]; then
    "$JENOVA_ROOT/scripts/install-dependencies.sh" --dry-run
else
    set +e
    "$JENOVA_ROOT/scripts/install-dependencies.sh" 2>&1
    _dep_status=$?
    set -e
    if [ "$_dep_status" = "0" ] || [ "$_dep_status" = "2" ]; then
        [ "$_dep_status" = "0" ] && print_success "Dependencies installed successfully" || print_warning "Some optional dependencies could not be installed (continuing)"
    else
        print_error "Critical system dependencies failed to install."
        exit 1
    fi
fi

echo ""

# Pre-flight checks
print_step "Running pre-flight checks..."

if [ "$DRY_RUN" = "1" ]; then
    print_info "Would run: $JENOVA_ROOT/scripts/preflight-check.sh"
else
    if "$JENOVA_ROOT/scripts/preflight-check.sh" 2>&1 | grep -q "critical issue"; then
        print_error "Pre-flight checks failed - please resolve issues above"
        exit 1
    else
        print_success "Pre-flight checks passed"
    fi
fi

echo ""

# Build components
print_step "Building Jenova components..."

COMPONENTS="llama jvim mcsh"
if [ "$MINIMAL" = "0" ]; then
    COMPONENTS="$COMPONENTS web"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  Would build: $COMPONENTS"
else
    for component in $COMPONENTS; do
        echo "  Building $component..."
        if make "$component"; then
            print_success "  $component built successfully"
        else
            if [ "$component" = "mcsh" ]; then
                print_warning "  Failed to build $component (optional, continuing)"
            else
                print_error "  Failed to build $component"
                echo "  Check var/log/ for details"
                exit 1
            fi
        fi
    done
    print_success "Component build phase complete"
fi

echo ""

# Deploy to system
print_step "Deploying to system..."

if [ "$DRY_RUN" = "1" ]; then
    print_info "Would run: $JENOVA_ROOT/scripts/install.sh --skip-lsp"
else
    if "$JENOVA_ROOT/scripts/install.sh" --skip-lsp >/dev/null 2>&1; then
        print_success "Jenova deployed to your system"
        echo "  Binaries: ~/.local/bin/jenova, ~/.local/bin/jvim, ~/.local/bin/jenova-ca"
        echo "  Config: ~/.config/jvim/"
    else
        print_error "Deployment failed"
        exit 1
    fi
fi

echo ""

# Model download (unless minimal)
if [ "$MINIMAL" = "0" ]; then
    print_step "Checking AI models..."

    if [ "$DRY_RUN" = "1" ]; then
        print_info "Would download AI models (~5-10GB)"
    else
        if command -v curl >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1; then
            # Run model downloader interactively
            if "$JENOVA_ROOT/scripts/model_dl.sh"; then
                print_success "Model check complete"
            else
                print_warning "Model downloader reported issues"
                echo "  You can re-run: ./scripts/model_dl.sh"
            fi
        else
            print_warning "curl/fetch not found - skipping model download"
            echo "  Download models manually: ./scripts/model_dl.sh"
        fi
    fi

    echo ""
fi

# Verification
print_step "Verifying installation..."

if [ "$DRY_RUN" = "1" ]; then
    print_info "Would run: $JENOVA_ROOT/scripts/verify-install.sh"
else
    if "$JENOVA_ROOT/scripts/verify-install.sh" >/dev/null 2>&1; then
        print_success "Installation verified"
    else
        print_warning "Installation verification had warnings"
        echo "  This is usually OK - Jenova should still work"
    fi
fi

echo ""

# Success message
if [ "$DRY_RUN" = "1" ]; then
    print_header "Dry Run Complete"
    print_info "To perform actual installation, run: $0"
else
    print_header "Installation Complete!"
    echo ""
    echo "${BOLD}Welcome to Jenova!${NC}"
    echo ""
    echo "🚀 ${BOLD}Quick Start:${NC}"
    echo "  jenova-tui      # Jenova Manager (Operational TUI)"
    echo "  jenova          # Full environment (editor + backend)"
    echo "  jvim            # Just the editor"
    echo "  jenova-ca       # Just the backend"
    echo "  Open http://localhost:8080 in a browser for the Web UI"
    echo ""
    echo "📚 ${BOLD}Documentation:${NC}"
    echo "  README.md       # Overview and features"
    echo "  docs/           # Detailed documentation"
    echo ""
    echo "🛠️  ${BOLD}Next Steps:${NC}"
    echo "  • Run 'jenova-tui' to manage the backend and apps"
    echo "  • Or run 'jenova' to start your first session"
    echo "  • Or run 'jenova-ca --daemon' and open http://localhost:8080"
    echo "  • Check hardware profiles: ./hardware-profiles/detect-hardware.sh"
    echo "  • Join our community: https://github.com/orpheus497/jenova"
    echo ""
    print_success "Enjoy using Jenova!"
fi