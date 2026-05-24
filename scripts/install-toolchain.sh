#!/bin/sh
# install-toolchain.sh: Install developer tools, LSPs, linters, and formatters

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

# Colours
if [ -t 1 ]; then
    _G=$(printf '\033[38;2;118;148;106m')
    _Y=$(printf '\033[38;2;192;163;110m')
    _R=$(printf '\033[38;2;195;64;67m')
    _B=$(printf '\033[38;2;126;156;216m')
    _P=$(printf '\033[38;2;120;81;169m')
    _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _P=""; _N=""
fi

ok()   { printf "${_G}✓${_N}  %s\n" "$1"; }
warn() { printf "${_Y}⚠${_N}  %s\n" "$1"; }
fail() { printf "${_R}✗${_N}  %s\n" "$1"; }
info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

info "Installing LSP servers, linters and formatters..."

_have() { command -v "$1" >/dev/null 2>&1; }

_PRIV="" 
if [ "$(id -u)" != "0" ]; then
    _have sudo && _PRIV="sudo " || { _have doas && _PRIV="doas "; }
fi

_apt_install() {
    _have apt-get || return 1
    $_PRIV DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null 2>&1
}

_pkg_install() {
    _have pkg || return 1
    $_PRIV pkg install -y "$@" >/dev/null 2>&1
}

_pacman_install() {
    if _have yay; then
        yay -S --noconfirm --needed "$@" >/dev/null 2>&1
    elif _have pacman; then
        $_PRIV pacman -S --noconfirm --needed "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

_dnf_install() {
    _have dnf || return 1
    $_PRIV dnf install -y -q "$@" >/dev/null 2>&1
}

_zypper_install() {
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

for _d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin" "$HOME/.local/share/pipx/venvs"; do
    case ":$PATH:" in *":$_d:"*) : ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH

WARNINGS=0

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

_GH_ARCH_LLS="$JENOVA_GH_ARCH_LLS"
_GH_ARCH_ZLS="$JENOVA_GH_ARCH_ZLS"

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

_install_lsp "shellcheck"             "shellcheck"          "shellcheck"           "shellcheck"                 ""                           ""               ""                                                          ""                          "shellcheck"                "shellcheck"
_install_lsp "stylua"                 "stylua"              ""                     "stylua"                     ""                           "stylua"         ""                                                          ""                          "stylua"                    "stylua"
_install_lsp "shfmt"                  "shfmt"               "shfmt"                "shfmt"                      ""                           ""               "mvdan.cc/sh/v3/cmd/shfmt@latest"                            ""                          "shfmt"                     "shfmt"
_install_lsp "goimports"              "goimports"           "goimports"            "go"                         ""                           ""               "golang.org/x/tools/cmd/goimports@latest"                    ""                          ""                          "go"
_install_lsp "black"                  "black"               "black"                "py311-black"                ""                           ""               ""                                                          "black"                     "python-black"              "black"
_install_lsp "isort"                  "isort"               "isort"                "py311-isort"                ""                           ""               ""                                                          "isort"                     "python-isort"              "isort"

if [ "$WARNINGS" -gt 0 ]; then
    warn "Some toolchain components failed to install."
    exit 2
fi

ok "Toolchain installation complete."
exit 0
