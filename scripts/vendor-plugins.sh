#!/bin/sh
# vendor-plugins.sh: Clone every Jenova-required nvim plugin into
# jvim/runtime/pack/jenova/start/<name> at the SHA pinned in
# nvim/plugins.lock.json, then strip .git so the plugin lives natively
# inside the jvim runtime tree (discovered by Neovim's packpath at startup).
#
# Run once after editing the slug map below; the result is committed.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/jvim/runtime/pack/jenova/start"
LOCK="$ROOT/jvim-config/plugins.lock.json"

mkdir -p "$DEST"

# Map: <lazy-lock-key>|<github-slug>
# Order is irrelevant; transitive deps are listed explicitly.
SPECS='
LuaSnip|L3MON4D3/LuaSnip
alpha-nvim|goolord/alpha-nvim
cmp-buffer|hrsh7th/cmp-buffer
cmp-nvim-lsp|hrsh7th/cmp-nvim-lsp
cmp-path|hrsh7th/cmp-path
cmp_luasnip|saadparwaiz1/cmp_luasnip
conform.nvim|stevearc/conform.nvim
diffview.nvim|sindrets/diffview.nvim
edgy.nvim|folke/edgy.nvim
gitsigns.nvim|lewis6991/gitsigns.nvim
indent-blankline.nvim|lukas-reineke/indent-blankline.nvim
kanagawa.nvim|rebelot/kanagawa.nvim
lazydev.nvim|folke/lazydev.nvim
llama.vim|ggml-org/llama.vim
lspkind.nvim|onsails/lspkind.nvim
lualine.nvim|nvim-lualine/lualine.nvim
luvit-meta|Bilal2453/luvit-meta
mini.nvim|echasnovski/mini.nvim
neogit|NeogitOrg/neogit
noice.nvim|folke/noice.nvim
nui.nvim|MunifTanjim/nui.nvim
nvim-cmp|hrsh7th/nvim-cmp
nvim-lspconfig|neovim/nvim-lspconfig
nvim-notify|rcarriga/nvim-notify
nvim-tree.lua|nvim-tree/nvim-tree.lua
nvim-treesitter|nvim-treesitter/nvim-treesitter
nvim-web-devicons|nvim-tree/nvim-web-devicons
plenary.nvim|nvim-lua/plenary.nvim
telescope-fzf-native.nvim|nvim-telescope/telescope-fzf-native.nvim
telescope.nvim|nvim-telescope/telescope.nvim
trouble.nvim|folke/trouble.nvim
vim-fugitive|tpope/vim-fugitive
which-key.nvim|folke/which-key.nvim
'

# Pull commit SHA out of plugins.lock.json by key (POSIX-portable, no jq).
sha_for() {
    awk -v key="$1" '
        $0 ~ "\"" key "\"" {
            if (match($0, /"commit":[[:space:]]*"[0-9a-f]+"/)) {
                s = substr($0, RSTART, RLENGTH)
                gsub(/.*"/, "", s)
                # back up: take the segment between the last two quotes
            }
            # safer: pull the SHA via a second pattern
            if (match($0, /[0-9a-f]{40}/)) {
                print substr($0, RSTART, RLENGTH)
                exit
            }
        }
    ' "$LOCK"
}

echo "==> Vendoring plugins into $DEST"
echo "$SPECS" | grep -v '^[[:space:]]*$' | while IFS='|' read -r KEY SLUG; do
    SHA="$(sha_for "$KEY")"
    if [ -z "$SHA" ]; then
        echo "  ! no SHA for $KEY in lazy-lock.json" >&2
        continue
    fi
    DIR="$DEST/$KEY"
    if [ -d "$DIR" ]; then
        echo "  - $KEY already vendored, skipping"
        continue
    fi
    echo "  + $SLUG @ ${SHA%%????????????????????????????????}…"
    git clone --quiet --filter=blob:none "https://github.com/$SLUG.git" "$DIR" >/dev/null
    git -C "$DIR" -c advice.detachedHead=false checkout --quiet "$SHA"
    rm -rf "$DIR/.git"
    # Drop CI / docs bloat that has no runtime value inside jvim.
    rm -rf "$DIR/.github" "$DIR/.gitignore" "$DIR/.gitattributes" \
           "$DIR/.editorconfig" "$DIR/.luarc.json" "$DIR/.styluaignore" \
           "$DIR/.stylua.toml" "$DIR/stylua.toml" \
           "$DIR/tests" "$DIR/test" "$DIR/spec" \
           "$DIR/.busted" "$DIR/Makefile.test" 2>/dev/null || true
done

echo
echo "Vendored plugins:"
ls "$DEST" | sed 's/^/  /'
