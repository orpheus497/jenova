#!/bin/sh
# install.sh: Jenova Cognitive Architecture — System Installation Script
# Supports all Vulkan hardware profiles (auto-detected via detect-hardware.sh)
#
# This is the single installer for the whole monorepo: it builds (or verifies)
# llama.cpp, builds the bundled jvim editor (which contains the embedded
# Jenova agent), downloads missing model GGUFs, deploys the jvim user config,
# and symlinks `jvim`, `jenova`, and `jenova-ca` onto your PATH.
#
# Usage: ./install.sh [--force] [--link] [--skip-config] [--skip-jvim]
#                     [--skip-llama] [--skip-lsp] [--client-only]
#
#   --force        Overwrite existing ~/.config/jvim without prompting and
#                  force a fresh jvim rebuild even if jvim/build/ exists
#   --link         Install Jenova jvim config as symlinks into ~/.config/jvim
#                  (development workflow — edits in repo apply immediately)
#   --skip-config  Skip the jvim user-config deployment step
#   --skip-jvim    Skip building the bundled jvim editor (jvim/)
#   --skip-llama   Skip llama.cpp build check
#   --skip-lsp     Skip auto-installing LSP servers / linters / formatters
#   --client-only  LAN client install: skip llama.cpp, skip jvim build,
#                  skip model downloads. Use when this host will only ever
#                  connect to a remote Jenova CA via 'jvim --remote <host>'.
#
# This script:
#   1. Verifies required system dependencies
#   2. Creates required runtime directories (var/log, var/cache, models, .jenova)
#   3. Checks for llama.cpp build (skipped with --client-only)
#   4. Downloads required model files (skipped with --client-only)
#   5. Detects whether the installed nvim is jvim or upstream Neovim
#   6. Installs the Jenova nvim configuration to ~/.config/jvim/
#   7. Installs bin/jvim, bin/jenova, bin/jenova-ca symlinks to PATH
#   8. Prints a summary plus next-step commands

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
JVIM_CONFIG_SRC="$JENOVA_ROOT/jvim-config"
JVIM_CONFIG_DST="$HOME/.config/jvim"

# Shared OS/hardware detection — populates JENOVA_OS, JENOVA_DISTRO,
# JENOVA_PKG_MGR, JENOVA_VULKAN_OK, JENOVA_GH_ARCH_*, etc.
. "$JENOVA_ROOT/lib/detect-env.sh"
# Backward-compat alias used by legacy case-statements in this file.
case "$JENOVA_OS" in
    freebsd) _OS="FreeBSD" ;;
    linux)   _OS="Linux" ;;
    macos)   _OS="Darwin" ;;
    *)       _OS="$(uname -s)" ;;
esac

FORCE=0
LINK=0
SKIP_NVIM=0
SKIP_JVIM=0
SKIP_LLAMA=0
SKIP_LSP=0
CLIENT_ONLY=0

for _arg in "$@"; do
    case "$_arg" in
        --force)       FORCE=1 ;;
        --link)        LINK=1 ;;
        --skip-config|--skip-nvim) SKIP_NVIM=1 ;;
        --skip-jvim)   SKIP_JVIM=1 ;;
        --skip-llama)  SKIP_LLAMA=1 ;;
        --skip-lsp)    SKIP_LSP=1 ;;
        --client-only) CLIENT_ONLY=1; SKIP_LLAMA=1; SKIP_JVIM=1 ;;
        -h|--help)
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            echo "Run: $0 --help" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours (disabled if not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R} FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

echo ""
printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_B}║  Jenova Cognitive Architecture — Install             ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# 1. OS Check & Hardware Profile Detection
# ---------------------------------------------------------------------------
info "Checking operating system..."
case "$JENOVA_OS" in
    freebsd)
        _VER="$(uname -r | cut -d. -f1)"
        if [ "${_VER:-0}" -ge 15 ] 2>/dev/null; then
            ok "FreeBSD ${_VER} — fully supported"
        else
            warn "FreeBSD ${_VER} — recommended FreeBSD 15+; some features may differ"
            WARNINGS=$((WARNINGS + 1))
        fi
        ;;
    linux)
        if [ "$JENOVA_WSL" = "1" ]; then
            ok "Linux (WSL) detected — ${JENOVA_DISTRO} / pkg: ${JENOVA_PKG_MGR}"
            warn "WSL environment detected. Some native GPU features may require specific drivers."
        else
            ok "Linux detected — ${JENOVA_DISTRO} / pkg: ${JENOVA_PKG_MGR}"
        fi
        info "Replace 'Vulkan0,Vulkan1' device names in etc/jenova.conf with your Vulkan device names (run: vulkaninfo --summary)"
        ;;
    macos)
        warn "macOS detected — experimental, not regularly tested"
        WARNINGS=$((WARNINGS + 1))
        ;;
    *)
        warn "Unsupported OS: $(uname -s) — proceeding but results may vary"
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

info "Detecting hardware profile..."
DETECT_SCRIPT="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"
_PROFILE=""
if [ -f "$DETECT_SCRIPT" ] && [ -x "$DETECT_SCRIPT" ]; then
    _PROFILE=$("$DETECT_SCRIPT" 2>/dev/null) || _PROFILE=""
    if [ -n "$_PROFILE" ]; then
        ok "Matched hardware profile: $_PROFILE"
        # Automatically apply the profile configuration (non-fatal: installer
        # continues even if the copy fails so the user is not left mid-install)
        if ! "$DETECT_SCRIPT" --apply; then
            warn "Failed to apply hardware profile: $_PROFILE"
            WARNINGS=$((WARNINGS + 1))
        fi
        _PROFILE_DIR="$JENOVA_ROOT/hardware-profiles/$_PROFILE"
    else
        warn "No hardware profile matched this system."
        warn "Run: $DETECT_SCRIPT --info  to see detection details."
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warn "Hardware detection script not found at $DETECT_SCRIPT"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 2. Create required runtime directories & Permission checks
# ---------------------------------------------------------------------------
info "Creating runtime directories..."

mkdir -p "$JENOVA_ROOT/.jenova" 2>/dev/null || {
    fail "Cannot create $JENOVA_ROOT/.jenova directory"
    fail "Do not run install.sh with sudo — run as regular user"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JENOVA_ROOT/var/log" || true
mkdir -p "$JENOVA_ROOT/var/cache" || true
mkdir -p "$JENOVA_ROOT/models/agent" || true
mkdir -p "$JENOVA_ROOT/models/embed" || true
mkdir -p "$JENOVA_ROOT/models/draft" || true

if [ -w "$JENOVA_ROOT/.jenova" ]; then
    ok "Runtime directories created with proper permissions"
else
    warn ".jenova directory exists but may have permission issues"
    warn "Run: chmod -R u+w $JENOVA_ROOT/.jenova"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for root-owned build artifacts that block regular-user builds
if [ -d "$JENOVA_ROOT/jvim/build" ] && [ ! -w "$JENOVA_ROOT/jvim/build" ]; then
    _owner=$(ls -ld "$JENOVA_ROOT/jvim/build" | awk '{print $3}')
    if [ "$_owner" = "root" ]; then
        fail "jvim/build is owned by root. This will cause the build to fail."
        fail "Run: sudo chown -R $(id -u):$(id -g) $JENOVA_ROOT/jvim"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 3. Required binaries
# ---------------------------------------------------------------------------
info "Checking required binaries..."

check_bin() {
    _name="$1"; _pkg="$2"
    if command -v "$_name" >/dev/null 2>&1; then
        ok "$_name"
    else
        fail "$_name not found — install: $_pkg"
        ERRORS=$((ERRORS + 1))
    fi
}

check_optional() {
    _name="$1"; _pkg="$2"
    if command -v "$_name" >/dev/null 2>&1; then
        ok "$_name (optional)"
    else
        warn "$_name not found (optional) — install: $_pkg"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_bin  "luajit"  "pkg install luajit-openresty"
check_bin  "git"     "pkg install git"

if [ "$SKIP_NVIM" = "0" ]; then
    # Prefer the in-tree jvim build (jvim/build/bin/nvim) which the unified
    # `make jvim` target produces. Fall back to whatever `nvim` is on PATH
    # (warn if it's not jvim) and finally fail with a build hint.
    _JVIM_BIN="$JENOVA_ROOT/jvim/build/bin/nvim"
    if [ -x "$_JVIM_BIN" ]; then
        _NVIM_VLINE=$("$_JVIM_BIN" --version 2>/dev/null | head -n 1)
        case "$_NVIM_VLINE" in
            *JVIM*) ok "in-tree jvim build ($_NVIM_VLINE) — fully integrated" ;;
            *)      warn "in-tree binary $_JVIM_BIN is not jvim ($_NVIM_VLINE)"; WARNINGS=$((WARNINGS + 1)) ;;
        esac
    elif command -v jvim >/dev/null 2>&1; then
        _NVIM_VLINE=$(jvim --version 2>/dev/null | head -n 1)
        case "$_NVIM_VLINE" in
            *JVIM*)
                ok "system nvim is jvim ($_NVIM_VLINE) — fully integrated"
                ;;
            *)
                warn "system nvim is upstream Neovim ($_NVIM_VLINE), not jvim."
                warn "Build the bundled jvim editor: make jvim"
                WARNINGS=$((WARNINGS + 1))
                ;;
        esac
    else
        if [ "$SKIP_JVIM" = "0" ]; then
            info "No editor found — will build bundled jvim later in this script"
        else
            fail "No editor found. Build the bundled jvim: make jvim"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    check_optional "gmake"  "pkg install gmake  (needed for telescope-fzf-native)"
fi

check_optional "cmake"   "pkg install cmake     (needed to build llama.cpp)"
check_optional "curl"    "pkg install curl      (used by jenova-ca health probe fallback)"

# Web search dependency: FreeBSD 'fetch' (base system) or curl fallback
if command -v fetch >/dev/null 2>&1; then
    ok "fetch (web search: native FreeBSD fetch available)"
elif command -v curl >/dev/null 2>&1; then
    ok "curl (web search: curl fallback available)"
else
    warn "Neither fetch nor curl found — web search (<leader>as) and health probe fallback unavailable"
    warn "Install curl to enable web search: pkg install curl  OR  apt install curl"
    WARNINGS=$((WARNINGS + 1))
fi

# Vulkan loader
if [ "$JENOVA_VULKAN_OK" = "1" ]; then
    ok "libvulkan (Vulkan loader)"
else
    case "$JENOVA_PKG_MGR" in
        pkg)    _vhint="pkg install vulkan-loader" ;;
        pacman) _vhint="pacman -S vulkan-icd-loader (or yay -S vulkan-icd-loader)" ;;
        apt)    _vhint="apt-get install libvulkan1" ;;
        dnf)    _vhint="dnf install vulkan-loader" ;;
        zypper) _vhint="zypper install libvulkan1" ;;
        xbps)   _vhint="xbps-install vulkan-loader" ;;
        brew)   _vhint="brew install molten-vk" ;;
        *)      _vhint="install the vulkan-loader package for your OS" ;;
    esac
    warn "libvulkan not found — ${_vhint}"
    warn "Without Vulkan, llama-server falls back to CPU-only inference."
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 4. LSP servers / linters / formatters
# ---------------------------------------------------------------------------
# Without LSPs nothing in the editor lints, so we install the ones we can
# obtain from the local package manager / npm / cargo / go automatically.
# Anything we cannot install is downgraded to a warning with the manual
# install hint instead of failing the script.
if [ "$SKIP_LSP" = "1" ]; then
    info "Skipping LSP / linter / formatter installation (--skip-lsp)"
else
info "Installing LSP servers, linters and formatters..."

# ── helpers ──────────────────────────────────────────────────────────
_have() { command -v "$1" >/dev/null 2>&1; }

# Try sudo when available and the current user is not root.
_PRIV="" 
if [ "$(id -u)" != "0" ]; then
    _have sudo && _PRIV="sudo " || { _have doas && _PRIV="doas "; }
fi

_apt_install() {
    # Quietly install one-or-more apt packages (Debian/Ubuntu/derivatives).
    _have apt-get || return 1
    $_PRIV DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null 2>&1
}

_pkg_install() {
    # FreeBSD pkg(8). Run unattended; root is required.
    _have pkg || return 1
    $_PRIV pkg install -y "$@" >/dev/null 2>&1
}

_pacman_install() {
    # Arch Linux pacman or yay.
    if _have yay; then
        yay -S --noconfirm --needed "$@" >/dev/null 2>&1
    elif _have pacman; then
        $_PRIV pacman -S --noconfirm --needed "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

_dnf_install() {
    # Fedora/RHEL/CentOS dnf.
    _have dnf || return 1
    $_PRIV dnf install -y -q "$@" >/dev/null 2>&1
}

_zypper_install() {
    # openSUSE zypper.
    _have zypper || return 1
    $_PRIV zypper install -y --quiet "$@" >/dev/null 2>&1
}

_xbps_install() {
    _have xbps-install || return 1
    $_PRIV xbps-install -y "$@" >/dev/null 2>&1
}

_brew_install() {
    _have brew || return 1
    brew install "$@" >/dev/null 2>&1
}

_npm_install_g() {
    _have npm || return 1
    if [ "$(id -u)" = "0" ]; then
        npm install -g --silent "$@" >/dev/null 2>&1
    else
        # User-prefix install avoids needing root.
        npm install -g --silent --prefix "$HOME/.local" "$@" >/dev/null 2>&1
    fi
}

_cargo_install() {
    _have cargo || return 1
    cargo install --quiet --locked "$@" >/dev/null 2>&1
}

_go_install() {
    _have go || return 1
    GOBIN="${GOBIN:-$HOME/go/bin}" go install "$@" >/dev/null 2>&1
}

_pip_install() {
    if _have pipx; then
        pipx install --quiet "$@" >/dev/null 2>&1
    elif _have pip3; then
        pip3 install --quiet --user "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

# Ensure the GOBIN / cargo / pipx / npm-prefix bins are on PATH for the
# rest of this script and any spawned tools.
for _d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin" "$HOME/.local/share/pipx/venvs"; do
    case ":$PATH:" in *":$_d:"*) : ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH

# Install one tool by trying the appropriate manager for this system first,
# then falling back through npm/cargo/go/pip. Already-present tools are skipped.
_install_lsp() {
    _exe="$1"; _label="$2"; _apt="$3"; _pkg="$4"; _npm="$5"; _cargo="$6"; _go="$7"; _pip="$8"; _pacman="$9"; shift 9; _brew="$1"
    if _have "$_exe"; then
        ok "$_label ($(command -v "$_exe"))"
        return 0
    fi
    case "$JENOVA_PKG_MGR" in
        pkg)    [ -n "$_pkg" ]    && _pkg_install    $_pkg    || true ;;
        pacman) [ -n "$_pacman" ] && _pacman_install $_pacman || true ;;
        apt)    [ -n "$_apt" ]    && _apt_install    $_apt    || true ;;
        dnf)    [ -n "$_apt" ]    && _dnf_install    $_apt    || true ;;
        zypper) [ -n "$_apt" ]    && _zypper_install $_apt    || true ;;
        xbps)   [ -n "$_apt" ]    && _xbps_install   $_apt    || true ;;
        brew)   [ -n "$_brew" ]   && _brew_install   $_brew   || true ;;
        *)      [ -n "$_apt" ]    && _apt_install    $_apt    || true ;;
    esac
    if ! _have "$_exe" && [ -n "$_npm" ];   then _npm_install_g $_npm  || true; fi
    if ! _have "$_exe" && [ -n "$_cargo" ]; then _cargo_install $_cargo || true; fi
    if ! _have "$_exe" && [ -n "$_go" ];    then _go_install $_go       || true; fi
    if ! _have "$_exe" && [ -n "$_pip" ];   then _pip_install $_pip     || true; fi
    if _have "$_exe"; then
        ok "$_label installed ($(command -v "$_exe"))"
    else
        warn "$_label could not be installed automatically"
        WARNINGS=$((WARNINGS + 1))
    fi
    return 0
}

# clangd: FreeBSD ships versioned binaries (clangd19, clangd18, …) without
# an unversioned symlink. Probe versioned names first.
_clangd_present() {
    for _c in clangd clangd21 clangd19 clangd18 clangd17 clangd16 clangd15; do
        _have "$_c" && { _CLANGD_BIN="$_c"; return 0; }
    done
    return 1
}
if _clangd_present; then
    ok "clangd (found as $_CLANGD_BIN)"
else
    case "$JENOVA_PKG_MGR" in
        pkg)    _pkg_install llvm || true ;;
        pacman) _pacman_install clang || true ;;
        apt)    _apt_install clangd || true ;;
        dnf)    _dnf_install clang-tools-extra || true ;;
        zypper) _zypper_install clang || true ;;
        xbps)   _xbps_install clang-tools-extra || true ;;
        brew)   _brew_install llvm || true ;;
        *)      _apt_install clangd || true ;;
    esac
    if _clangd_present; then
        ok "clangd installed (as $_CLANGD_BIN)"
    else
        warn "clangd could not be installed automatically"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Arch suffixes for GitHub release downloads — from shared detection.
_GH_ARCH_LLS="$JENOVA_GH_ARCH_LLS"
_GH_ARCH_ZLS="$JENOVA_GH_ARCH_ZLS"

# Install lua-language-server from upstream github release tarball.
# Debian/Ubuntu do not package it, npm/cargo do not provide it, and FreeBSD
# only has it via the lua-language-server pkg (handled above).
_install_lls_from_github() {
    [ -z "$_GH_ARCH_LLS" ] && return 1
    _have curl || return 1
    _ver="3.13.5"
    _dst="$HOME/.local/share/lua-language-server"
    info "Downloading lua-language-server $_ver from github..."
    mkdir -p "$_dst" "$HOME/.local/bin"
    _url="https://github.com/LuaLS/lua-language-server/releases/download/${_ver}/lua-language-server-${_ver}-linux-${_GH_ARCH_LLS}.tar.gz"
    _tmp="$(mktemp)"
    curl -fsSL "$_url" -o "$_tmp" || { rm -f "$_tmp"; return 1; }
    tar -xzf "$_tmp" -C "$_dst" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    printf '#!/bin/sh\nexec "%s/bin/lua-language-server" "$@"\n' "$_dst" > "$HOME/.local/bin/lua-language-server"
    chmod +x "$HOME/.local/bin/lua-language-server"
    _have lua-language-server
}

# Install zls from upstream github release tarball as a last resort.
_install_zls_from_github() {
    [ -z "$_GH_ARCH_ZLS" ] && return 1
    _have curl || return 1
    _ver="0.13.0"
    mkdir -p "$HOME/.local/bin"
    _url="https://github.com/zigtools/zls/releases/download/${_ver}/zls-${_GH_ARCH_ZLS}-linux.tar.xz"
    _tmp="$(mktemp)"
    _outdir="$(mktemp -d)"
    trap 'rm -f "$_tmp"; rm -rf "$_outdir"' RETURN
    info "Downloading zls $_ver from github..."
    curl -fsSL "$_url" -o "$_tmp" || return 1
    tar -xJf "$_tmp" -C "$_outdir" zls 2>/dev/null || return 1
    mv "$_outdir/zls" "$HOME/.local/bin/zls"
    chmod +x "$HOME/.local/bin/zls"
    _have zls
}

# args:        exe                    label                apt                    pkg                          npm                          cargo            go                                                          pip                         pacman                      brew
_install_lsp "rust-analyzer"          "rust-analyzer"       "rust-analyzer"        "rust-analyzer"              ""                           ""               ""                                                          ""                          "rust-analyzer"             "rust-analyzer"
_install_lsp "lua-language-server"    "lua-language-server" "lua-language-server"  "lua-language-server"        ""                           ""               ""                                                          ""                          "lua-language-server"       "lua-language-server"
if ! _have lua-language-server; then
    _install_lls_from_github && ok "lua-language-server installed ($(command -v lua-language-server))" || warn "lua-language-server could not be installed automatically"
fi
_install_lsp "pyright-langserver"     "pyright"             "pyright"              "py311-pyright"              "pyright"                    ""               ""                                                          ""                          "pyright"                   "pyright"
_install_lsp "bash-language-server"   "bash-language-server" ""                    "npm"                        "bash-language-server"       ""               ""                                                          ""                          "bash-language-server"      "bash-language-server"
_install_lsp "gopls"                  "gopls"               "gopls"                "go gopls"                   ""                           ""               "golang.org/x/tools/gopls@latest"                            ""                          "gopls"                     "go"
_install_lsp "zls"                    "zls"                 "zls"                  "zig"                        ""                           ""               ""                                                          ""                          "zls"                       "zls"
if ! _have zls; then
    _install_zls_from_github && ok "zls installed ($(command -v zls))" || warn "zls could not be installed automatically"
fi

# Linters (used by LSP-equivalents and conform.nvim).
_install_lsp "shellcheck"             "shellcheck"          "shellcheck"           "shellcheck"                 ""                           ""               ""                                                          ""                          "shellcheck"                "shellcheck"

# Formatters used by conform.nvim (format-on-save).
_install_lsp "stylua"                 "stylua"              ""                     "stylua"                     ""                           "stylua"         ""                                                          ""                          "stylua"                    "stylua"
_install_lsp "shfmt"                  "shfmt"               "shfmt"                "shfmt"                      ""                           ""               "mvdan.cc/sh/v3/cmd/shfmt@latest"                            ""                          "shfmt"                     "shfmt"
_install_lsp "goimports"              "goimports"           "goimports"            "go"                         ""                           ""               "golang.org/x/tools/cmd/goimports@latest"                    ""                          ""                          "go"
_install_lsp "black"                  "black"               "black"                "py311-black"                ""                           ""               ""                                                          "black"                     "python-black"              "black"
_install_lsp "isort"                  "isort"               "isort"                "py311-isort"                ""                           ""               ""                                                          "isort"                     "python-isort"              "isort"

fi  # SKIP_LSP


# ---------------------------------------------------------------------------
# 5. llama.cpp build check
# ---------------------------------------------------------------------------
if [ "$CLIENT_ONLY" = "1" ]; then
    info "Skipping llama.cpp build check (--client-only)"
elif [ "$SKIP_LLAMA" = "0" ]; then
    info "Checking llama.cpp build..."
    LLAMA_BIN="$JENOVA_ROOT/llama.cpp/build/bin/llama-server"
    if [ -f "$LLAMA_BIN" ]; then
        ok "llama-server binary found at $LLAMA_BIN"
    else
        warn "llama-server not found. Build it using the Makefile:"
        warn "  make llama"
        warn "This will build llama.cpp with the appropriate backend (Vulkan, CUDA, Metal)"
        warn "based on your detected hardware profile."
        warn "For manual builds, see llama.cpp/docs/build.md"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for Vulkan SDK components (needed for build)
    if [ "$JENOVA_GLSLC_OK" = "0" ]; then
        case "$JENOVA_PKG_MGR" in
            pkg)    _glslc_hint="pkg install shaderc" ;;
            pacman) _glslc_hint="pacman -S shaderc (or yay -S shaderc)" ;;
            apt)    _glslc_hint="apt install glslc" ;;
            dnf)    _glslc_hint="dnf install glslc" ;;
            zypper) _glslc_hint="zypper install shaderc" ;;
            xbps)   _glslc_hint="xbps-install shaderc" ;;
            brew)   _glslc_hint="brew install shaderc" ;;
            *)      _glslc_hint="install the shaderc/glslc package for your OS" ;;
        esac
        warn "glslc (Vulkan shader compiler) not found — ${_glslc_hint}"
        warn "Without glslc, llama.cpp cannot be built with Vulkan GPU support."
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 5b. jvim editor — build the in-tree fork unless --skip-jvim was passed
# ---------------------------------------------------------------------------
if [ "$SKIP_JVIM" = "0" ] && [ "$CLIENT_ONLY" = "0" ]; then
    info "Building bundled jvim editor (jvim/)..."
    if [ ! -f "$JENOVA_ROOT/jvim/CMakeLists.txt" ]; then
        warn "jvim/ source tree missing — skipping jvim build"
        WARNINGS=$((WARNINGS + 1))
    else
        _JVIM_BIN_OUT="$JENOVA_ROOT/jvim/build/bin/nvim"
        if [ -x "$_JVIM_BIN_OUT" ] && [ "$FORCE" = "0" ]; then
            ok "jvim already built at $_JVIM_BIN_OUT (use --force to rebuild)"
        else
            _MAKE_CMD="make"
            if [ "$_OS" = "FreeBSD" ]; then
                if command -v gmake >/dev/null 2>&1; then
                    _MAKE_CMD="gmake"
                else
                    warn "gmake not found — FreeBSD requires gmake to build jvim"
                    WARNINGS=$((WARNINGS + 1))
                    _MAKE_CMD=""
                fi
            fi

            if [ -z "$_MAKE_CMD" ]; then
                warn "Skipping jvim build due to missing make tool"
            else
                _JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
                (
                    cd "$JENOVA_ROOT/jvim" && \
                    "$_MAKE_CMD" CMAKE_BUILD_TYPE=RelWithDebInfo \
                                 CMAKE_INSTALL_PREFIX="$JENOVA_ROOT/jvim/install" \
                                 -j"$_JOBS"
                ) || {
                    fail "jvim build failed — see above. Re-run: make jvim"
                    ERRORS=$((ERRORS + 1))
                }
                if [ -x "$_JVIM_BIN_OUT" ]; then
                    ok "jvim built at $_JVIM_BIN_OUT"
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. Model files — check and offer to download missing models
# ---------------------------------------------------------------------------
if [ "$CLIENT_ONLY" = "1" ]; then
    info "Skipping model checks (--client-only — models live on the remote host)"
else
    if [ -x "$JENOVA_ROOT/scripts/model_dl.sh" ]; then
        "$JENOVA_ROOT/scripts/model_dl.sh" "$_PROFILE" || {
            warn "Model download process was incomplete or skipped."
            WARNINGS=$((WARNINGS + 1))
        }
    else
        warn "Model download script not found at scripts/model_dl.sh"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 7. Neovim config installation
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v jvim >/dev/null 2>&1; then
    info "Installing jvim configuration..."

    if [ -d "$JVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
        printf "  ~/.config/jvim already exists. Overwrite? [y/N] "
        read -r _ans
        case "$_ans" in
            y|Y|yes|YES) ;;
            *)
                warn "Skipping jvim config installation (use --force to override)"
                SKIP_NVIM=1
                ;;
        esac
    fi

    if [ "$SKIP_NVIM" = "0" ]; then
        # Backup existing config
        if [ -d "$JVIM_CONFIG_DST" ]; then
            _TS=$(date +%Y%m%d_%H%M%S)
            _BAK="${JVIM_CONFIG_DST}.bak.${_TS}"
            mv "$JVIM_CONFIG_DST" "$_BAK"
            ok "Backed up existing config to $_BAK"
        fi

        mkdir -p "$JVIM_CONFIG_DST/lua/plugins"
        mkdir -p "$JVIM_CONFIG_DST/lua/jenova"

        if [ "$LINK" = "1" ]; then
            # Symlink mode — changes in repo instantly reflected in jvim
            ln -sf "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            for _f in "$JVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/plugins/$(basename "$_f")"
            done
            # jenova/ contains both leaf .lua modules AND the agent/ subtree
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/jenova/$(basename "$_f")"
            done
            ln -sfn "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/agent"
            ok "Symlinked jvim user config (--link mode, edits in $JVIM_CONFIG_SRC take effect immediately)"
        else
            # Copy mode — stable snapshot
            cp "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            for _f in "$JVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/plugins/"
            done
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/jenova/"
            done
            cp -r "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/"
            ok "Copied jvim user config to $JVIM_CONFIG_DST"
        fi
        info "Plugins ship vendored inside jvim/runtime/pack/jenova/start/ — no network fetch required."
    fi
fi

# ---------------------------------------------------------------------------
# 8. Install launchers to PATH
# ---------------------------------------------------------------------------
info "Installing launchers to PATH..."

_BIN_DIR=""
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    if echo "$PATH" | grep -q "$_d"; then
        _BIN_DIR="$_d"
        break
    fi
done

if [ -n "$_BIN_DIR" ]; then
    mkdir -p "$_BIN_DIR"
    ln -sf "$JENOVA_ROOT/bin/jvim" "$_BIN_DIR/jvim"
    ln -sf "$JENOVA_ROOT/bin/jenova" "$_BIN_DIR/jenova"
    ln -sf "$JENOVA_ROOT/bin/jenova-ca" "$_BIN_DIR/jenova-ca"
    ln -sf "$JENOVA_ROOT/bin/jenova-tui" "$_BIN_DIR/jenova-tui"
    ln -sf "$JENOVA_ROOT/bin/jenova-term" "$_BIN_DIR/jenova-term"
    if [ -f "$JENOVA_ROOT/bin/mcsh" ]; then
        ln -sf "$JENOVA_ROOT/bin/mcsh" "$_BIN_DIR/mcsh"
        ln -sf "$JENOVA_ROOT/bin/mcsh" "$_BIN_DIR/tcsh"
        ln -sf "$JENOVA_ROOT/bin/mcsh" "$_BIN_DIR/csh"
        ok "Symlinked jvim, jenova, jenova-ca, jenova-tui, jenova-term, and mcsh to $_BIN_DIR"
    else
        ok "Symlinked jvim, jenova, jenova-ca, jenova-tui, and jenova-term to $_BIN_DIR"
    fi

    # Install Desktop Entry
    if [ "$JENOVA_OS" = "linux" ] || [ "$JENOVA_OS" = "freebsd" ]; then
        _APP_DIR="$HOME/.local/share/applications"
        mkdir -p "$_APP_DIR"
        [ -f "$JENOVA_ROOT/bin/jenova.desktop" ] && cp "$JENOVA_ROOT/bin/jenova.desktop" "$_APP_DIR/jenova.desktop"
        [ -f "$JENOVA_ROOT/bin/jenova-manager.desktop" ] && cp "$JENOVA_ROOT/bin/jenova-manager.desktop" "$_APP_DIR/jenova-manager.desktop"
        [ -f "$JENOVA_ROOT/bin/jvim.desktop" ] && cp "$JENOVA_ROOT/bin/jvim.desktop" "$_APP_DIR/jvim.desktop"
        ok "Installed desktop entries to $_APP_DIR"
        # Install Icons
        _ICON_DIR="$HOME/.local/share/icons"
        mkdir -p "$_ICON_DIR"
        if [ -d "$JENOVA_ROOT/png" ]; then
            # Convert .jpg icons to .png for better compatibility
            for icon in jenova jca jvim; do
                if [ -f "$JENOVA_ROOT/png/$icon.jpg" ]; then
                    if command -v convert >/dev/null 2>&1; then
                        convert "$JENOVA_ROOT/png/$icon.jpg" "$_ICON_DIR/$icon.png"
                    elif command -v magick >/dev/null 2>&1; then
                        magick "$JENOVA_ROOT/png/$icon.jpg" "$_ICON_DIR/$icon.png"
                    else
                        cp "$JENOVA_ROOT/png/$icon.jpg" "$_ICON_DIR/$icon.jpg"
                    fi
                fi
            done
            
            # Create symlinks without extension
            for icon in jenova jca jvim; do
                if [ -f "$_ICON_DIR/$icon.png" ]; then
                    ln -sf "$_ICON_DIR/$icon.png" "$_ICON_DIR/$icon"
                elif [ -f "$_ICON_DIR/$icon.jpg" ]; then
                    ln -sf "$_ICON_DIR/$icon.jpg" "$_ICON_DIR/$icon"
                fi
            done
            
            # Update icon cache
            gtk-update-icon-cache -f -t "$_ICON_DIR" 2>/dev/null || true
            ok "Installed icons to $_ICON_DIR"
        fi
    fi
else
    warn "No writable bin dir found on PATH (~/.local/bin or ~/bin)."
    warn "Add '$JENOVA_ROOT/bin' to your PATH or manually symlink:"
    warn "  mkdir -p ~/.local/bin"
    warn "  ln -sf $JENOVA_ROOT/bin/jvim ~/.local/bin/jvim"
    warn "  ln -sf $JENOVA_ROOT/bin/jenova ~/.local/bin/jenova"
    warn "  ln -sf $JENOVA_ROOT/bin/jenova-ca ~/.local/bin/jenova-ca"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"  # Add to ~/.bashrc or ~/.zshrc"
fi

# ---------------------------------------------------------------------------
# 9. System Tuning Reminders
# ---------------------------------------------------------------------------
if [ -n "$_PROFILE" ]; then
    _PROFILE_DIR="$JENOVA_ROOT/hardware-profiles/$_PROFILE"
    if [ -f "$_PROFILE_DIR/jenova-setup" ]; then
        warn "Run 'sudo $_PROFILE_DIR/jenova-setup' once to tune system for this hardware."
    fi
elif [ "$JENOVA_OS" = "freebsd" ]; then
    info "System tuning..."
    warn "Run 'sudo $JENOVA_ROOT/scripts/jenova-setup' once to tune vm.* sysctls and ZFS ARC"
    warn "for optimal Optane swap / Iris Xe UMA performance."
    WARNINGS=$((WARNINGS + 1))
fi


# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
printf "${_B}  Installation Summary${_N}\n"
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""
if [ "$ERRORS" -gt 0 ]; then
    fail "Installation incomplete — resolve errors above before running Jenova."
    echo ""
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    warn "Installation complete with warnings (see above). Core features will work;"
    warn "some optional features (LSP servers, formatters, speculative decoding)"
    warn "may be unavailable until dependencies are installed."
else
    ok "Installation complete — all required dependencies found."
fi

echo ""
info "Next steps:"
if [ "$CLIENT_ONLY" = "1" ]; then
    echo "  This is a LAN-client install. To connect to a remote Jenova CA:"
    echo "      jvim --remote <server-ip>            # default ports 8080/8081/8082"
    echo "      jvim --remote <server-ip> --remote-port 8080 --llama-port 8081"
    echo ""
    echo "  Make sure the server has JENOVA_HOST=0.0.0.0 in etc/jenova.conf and"
    echo "  the firewall allows ports 8080, 8081, and 8082 from this host."
else
    echo "  1. Place model GGUF files in type-specific folders:"
    echo "       Agent:  $JENOVA_ROOT/models/agent/"
    echo "       Embed:  $JENOVA_ROOT/models/embed/"
    echo "       Draft:  $JENOVA_ROOT/models/draft/"
    echo "  2. Build llama.cpp if not done:"
    echo "       make llama"
    echo "  3. Start the backend:  $JENOVA_ROOT/bin/jenova-ca --daemon"
    echo "     Or launch agent:    jenova"
    echo "     Or use Web UI:      Open http://localhost:8080 in a browser"
    echo "     Or launch editor:   $JENOVA_ROOT/bin/jvim  (or just: jvim)"
    echo "     LAN client mode:    jvim --remote <host>"
    if [ "$SKIP_NVIM" = "0" ]; then
        echo "  4. Inside the editor:  :checkhealth jenova"
        echo "                         (plugins are vendored under jvim/runtime/pack/jenova/start/)"
    fi
    echo ""
    echo "  Maintenance:"
    echo "    scripts/update.sh             — pull latest jenova + sync nvim config"
    echo "    scripts/cleanup.sh --all      — clear logs and cache"
    echo "    scripts/uninstall.sh          — remove deployed files (preserves models)"
    echo "    bin/jvim --check        — print resolved env without launching editor"
fi
echo