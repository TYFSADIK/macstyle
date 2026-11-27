# shellcheck shell=bash disable=SC2034
# Steps both Linux editions (GNOME and KDE Plasma) share: the MacTahoe icons and cursor, and the
# zsh setup of the terminal. Sourced by install.sh and kde/install.sh, after lib/files.sh.

ICONS_COMMIT=839848b9a8a38a92a6936e30c4abe35cc6f2546d   # MacTahoe icon theme, 2026-09-10
ICONS_URL="https://github.com/vinceliuice/MacTahoe-icon-theme/archive/$ICONS_COMMIT.tar.gz"
# The terminal: JetBrains Mono with Nerd Font icons, and Powerlevel10k (the prompt engine).
# fastfetch and lsd, for distributions that do not package them:
FASTFETCH_TAG=2.71.0
LSD_TAG=v1.2.0
FONT_URL=https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz
FONT_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
P10K_COMMIT=d05a1b00f9a61f9578bf9dc19b8451942dde8734   # 2026-09-06
P10K_URL="https://github.com/romkatv/powerlevel10k/archive/$P10K_COMMIT.tar.gz"
WALLPAPERS=(mountain:Mountain sub-arctic:Sub-Arctic coast:Coast waterfall:Waterfall orionids:Orionids nuvole:Nuvole)
DEFAULT_WALLPAPER=mountain

# MacTahoe icons and cursor (light and dark), from the project, at a fixed commit
icons() {
    local t
    if [[ -f "$ICONS_DIR/MacTahoe-light/index.theme" && -f "$ICONS_DIR/MacTahoe-dark/index.theme" ]]; then
        ok "MacTahoe icons are already installed"
    else
        info "downloading the MacTahoe icon theme (about 10 MB)..."
        local tmp; tmp="$(mktemp -d)"
        curl -fsSL --retry 3 "$ICONS_URL" -o "$tmp/icons.tar.gz" ||
            die "could not download $ICONS_URL. Check the internet connection and run ./install.sh again."
        tar -xzf "$tmp/icons.tar.gz" -C "$tmp"
        local src; src="$(find "$tmp" -maxdepth 1 -type d -name 'MacTahoe-icon-theme-*' -print -quit)"
        [[ -n "$src" && -x "$src/install.sh" ]] || die "the icon download looks wrong ($ICONS_URL)."
        for t in MacTahoe MacTahoe-light MacTahoe-dark; do keep_original "$ICONS_DIR/$t"; done
        # It ends with gtk-update-icon-cache, which a KDE-only system may not have; the cache only
        # speeds up GTK apps, so without the command a stand-in that does nothing is used
        mkdir -p "$tmp/bin"
        if ! command -v gtk-update-icon-cache >/dev/null; then
            printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/gtk-update-icon-cache"
            chmod 755 "$tmp/bin/gtk-update-icon-cache"
        fi
        (cd "$src" && PATH="$tmp/bin:$PATH" ./install.sh -d "$ICONS_DIR" >"$tmp/icons.log" 2>&1) ||
            { tail -n 15 "$tmp/icons.log" >&2; die "the MacTahoe icon installer failed (see above)."; }
        for t in MacTahoe MacTahoe-light MacTahoe-dark; do mark_installed "$ICONS_DIR/$t"; done
        rm -rf -- "$tmp"
        ok "MacTahoe icons and cursor installed"
    fi
}

# zsh with the round-pill prompt: the font, fastfetch, lsd, Powerlevel10k and the ~/.zshrc block.
# The caller has checked that zsh is installed and the terminal step is wanted.
terminal_shell() {
    local tmp src fontdir="$DATA_HOME/fonts/JetBrainsMonoNerdFont" p10k="$DATA_HOME/$NAME/powerlevel10k"
    if [[ -f "$fontdir/JetBrainsMonoNerdFont-Regular.ttf" ]]; then
        ok "JetBrainsMono Nerd Font is already installed"
    else
        info "downloading the JetBrainsMono Nerd Font (about 7 MB)..."
        tmp="$(mktemp -d)"
        curl -fsSL --retry 3 "$FONT_URL" -o "$tmp/font.tar.xz" ||
            die "could not download $FONT_URL. Check the internet connection and run ./install.sh again."
        echo "$FONT_SHA256  $tmp/font.tar.xz" | sha256sum --check --quiet - ||
            die "the font download does not match its checksum ($FONT_URL)."
        mkdir -p "$tmp/font"
        tar -xJf "$tmp/font.tar.xz" -C "$tmp/font" OFL.txt \
            JetBrainsMonoNerdFont-{Regular,Bold,Italic,BoldItalic}.ttf
        put "$tmp/font" "$fontdir"
        rm -rf -- "$tmp"
        fc-cache -f "$DATA_HOME/fonts" >/dev/null 2>&1 || true
        ok "JetBrainsMono Nerd Font"
    fi

    # fastfetch and lsd, from their projects when the distribution does not package them
    local arch; arch="$(uname -m)"
    if ! command -v fastfetch >/dev/null; then
        local ffa=amd64; [[ "$arch" = aarch64 ]] && ffa=aarch64
        tmp="$(mktemp -d)"
        if curl -fsSL --retry 3 "https://github.com/fastfetch-cli/fastfetch/releases/download/$FASTFETCH_TAG/fastfetch-linux-$ffa.tar.gz" -o "$tmp/ff.tar.gz"; then
            tar -xzf "$tmp/ff.tar.gz" -C "$tmp"
            src="$(find "$tmp" -type f -name fastfetch -perm -u+x -print -quit)"
            [[ -n "$src" ]] && put "$src" "$BIN_DIR/fastfetch" && ok "fastfetch $FASTFETCH_TAG in $BIN_DIR"
        else
            warn "could not download fastfetch; new terminals open without the system summary"
        fi
        rm -rf -- "$tmp"
    fi
    if ! command -v lsd >/dev/null; then
        tmp="$(mktemp -d)"
        if curl -fsSL --retry 3 "https://github.com/lsd-rs/lsd/releases/download/$LSD_TAG/lsd-$LSD_TAG-$arch-unknown-linux-gnu.tar.gz" -o "$tmp/lsd.tar.gz"; then
            tar -xzf "$tmp/lsd.tar.gz" -C "$tmp"
            src="$(find "$tmp" -type f -name lsd -perm -u+x -print -quit)"
            [[ -n "$src" ]] && put "$src" "$BIN_DIR/lsd" && ok "lsd $LSD_TAG in $BIN_DIR"
        else
            warn "could not download lsd; ls stays as it is"
        fi
        rm -rf -- "$tmp"
    fi

    # Powerlevel10k draws the prompt. A setup that loads it already keeps its own copy.
    if [[ -f "$HOME/.zshrc" ]] && grep -q powerlevel10k "$HOME/.zshrc"; then
        ok "Powerlevel10k: your own, loaded by ~/.zshrc"
    elif [[ -f "$p10k/powerlevel10k.zsh-theme" ]]; then
        ok "Powerlevel10k is already downloaded"
    else
        info "downloading Powerlevel10k..."
        tmp="$(mktemp -d)"
        curl -fsSL --retry 3 "$P10K_URL" -o "$tmp/p10k.tar.gz" ||
            die "could not download $P10K_URL. Check the internet connection and run ./install.sh again."
        tar -xzf "$tmp/p10k.tar.gz" -C "$tmp"
        src="$(find "$tmp" -maxdepth 1 -type d -name 'powerlevel10k-*' -print -quit)"
        [[ -n "$src" && -f "$src/powerlevel10k.zsh-theme" ]] || die "the Powerlevel10k download looks wrong ($P10K_URL)."
        put "$src" "$p10k"
        rm -rf -- "$tmp"
        ok "Powerlevel10k (commit ${P10K_COMMIT:0:7})"
    fi
    # gitstatusd, Powerlevel10k's fast git helper: fetched now, so the first prompt needs no download.
    if [[ -f "$p10k/gitstatus/install" ]]; then
        sh "$p10k/gitstatus/install" >/dev/null 2>&1 ||
            warn "gitstatusd was not downloaded now; Powerlevel10k fetches it when you first open a terminal"
    fi

    local f
    for f in macstyle.zsh p10k-base.zsh p10k-macstyle.zsh; do
        put "$REPO/terminal/$f" "$CONFIG_HOME/$NAME/zsh/$f"
    done
    put "$REPO/terminal/fastfetch.jsonc" "$CONFIG_HOME/fastfetch/config.jsonc"   # the small logo of this distribution
    put "$REPO/terminal/lsd/config.yaml" "$CONFIG_HOME/lsd/config.yaml"
    put "$REPO/terminal/lsd/colors.yaml" "$CONFIG_HOME/lsd/colors.yaml"
    keep_original "$HOME/.zshrc"
    [[ -e "$HOME/.zshrc" || -e "$STATE/zshrc-created" ]] || touch "$STATE/zshrc-created"
    python3 -I "$REPO/lib/zshrc-blocks.py" add "$HOME/.zshrc"
    ok "zsh: round pills prompt, typing help, Ctrl+R search, z jumps, ls with icons"
}
