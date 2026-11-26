#!/usr/bin/env bash
# macstyle: a macOS-like GNOME desktop for Fedora, Ubuntu and Debian, in one command.
#
#   git clone https://github.com/TYFSADIK/macstyle
#   cd macstyle
#   ./install.sh
#
# Run it as your normal user (no sudo in front) from a terminal inside your GNOME session.
# It asks for your password once (for a few small packages and a Firefox setting), installs
# everything, then asks you to log out and back in. ./uninstall.sh puts your desktop back as it
# was.
#
# Options:
#   -y, --yes          answer every question with its default (no prompts)
#   --no-packages      skip everything that needs sudo (packages, the Firefox setting)
#   --no-apps          leave VS Code, Chrome and Firefox alone
#   --no-terminal      leave the terminal and zsh alone
#   --force            run on a distribution macstyle is not made for
#   -h, --help         show this help
set -Eeuo pipefail
shopt -s nullglob

REPO="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
# shellcheck source=lib/distro.sh
source "$REPO/lib/distro.sh"

# GNOME 43 (Debian 12) and newer. extensions/ holds copies for GNOME 45 to 51; extensions-50/ and
# extensions-51/ hold the ones that differ per version. Anything without a copy for this GNOME
# comes from extensions.gnome.org (or its project's GitHub releases), checked for this version.
MIN_GNOME=43
GNOME_MAJOR=""   # set by preflight
GNOME_SET=""     # the extensions-NN folder for this GNOME, if there is one
WHITESUR_COMMIT=d5782652d412137e26fb8ff55b55a5572e4c6995   # WhiteSur GTK theme, for GNOME 47 and older
WHITESUR_URL="https://github.com/vinceliuice/WhiteSur-gtk-theme/archive/$WHITESUR_COMMIT.tar.gz"
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

ASSUME_YES=0 PACKAGES_ON=1 APPS_ON=1 TERMINAL_ON=1 FORCE=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-packages) PACKAGES_ON=0 ;;
        --no-apps) APPS_ON=0 ;;
        --no-terminal) TERMINAL_ON=0 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,/^set -E/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg (see ./install.sh --help)" ;;
    esac
done

trap 'die "install.sh stopped at line $LINENO. Your desktop is half set up: run ./install.sh again, or ./uninstall.sh to go back."' ERR
detect_distro

# Before anything is written: as root, every setting would go to root's account, not yours.
[[ $EUID -ne 0 ]] || die "run ./install.sh as your normal user, without sudo. It asks for your password itself when it needs it."

# --- checks --------------------------------------------------------------------------------------

preflight() {
    step "Checking this computer"
    for d in extensions themes settings bin systemd lib wallpapers; do
        [[ -d "$REPO/$d" ]] || die "$REPO/$d is missing. Run install.sh inside the folder you cloned with git."
    done
    if [[ -z "$DISTRO_FAMILY" ]]; then
        [[ $FORCE = 1 ]] || die "made for Fedora, Ubuntu and Debian (found: $DISTRO_NAME). Use --force to try anyway."
        warn "$DISTRO_NAME is not Fedora, Ubuntu or Debian; going on because of --force, without packages"
        PACKAGES_ON=0
    fi
    command -v gnome-shell >/dev/null || die "GNOME Shell is not installed. macstyle needs the GNOME desktop."
    GNOME_MAJOR="$(gnome-shell --version | awk '{split($3, v, "."); print v[1]}')"
    [[ "$GNOME_MAJOR" =~ ^[0-9]+$ ]] || die "could not tell the GNOME version ($(gnome-shell --version))."
    ((GNOME_MAJOR >= MIN_GNOME)) || die "GNOME $GNOME_MAJOR is too old; macstyle needs GNOME $MIN_GNOME or newer (Fedora 37, Ubuntu 22.10, Debian 12 and later)."
    [[ -d "$REPO/extensions-$GNOME_MAJOR" ]] && GNOME_SET="$GNOME_MAJOR"
    [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
        die "run it from a terminal inside your GNOME desktop (not over SSH or from a text console)."
    for c in gsettings python3 gio curl tar; do
        command -v "$c" >/dev/null || die "the command '$c' is missing."
    done
    if ! command -v dconf >/dev/null; then
        [[ $PACKAGES_ON = 1 ]] || die "the command 'dconf' is missing (package dconf-cli); run without --no-packages to install it."
        info "dconf is missing; it is installed with the packages"
    fi
    ok "$DISTRO_NAME, GNOME Shell $(gnome-shell --version | awk '{print $3}'), ${XDG_SESSION_TYPE:-?} session"
}

# --- record of what was there before -------------------------------------------------------------

mark_installed() {   # remember a path the install put in place
    mkdir -p "$STATE"
    grep -qxF -- "$1" "$INSTALLED" 2>/dev/null || printf '%s\n' "$1" >> "$INSTALLED"
}

keep_original() {    # save PATH as it was before the first install, once
    local path="$1" rel
    [[ -e "$path" || -L "$path" ]] || return 0
    grep -qxF -- "$path" "$INSTALLED" 2>/dev/null && return 0   # ours from an earlier run
    rel="${path#"$HOME"/}"
    [[ -e "$ORIGINAL/files/$rel" || -L "$ORIGINAL/files/$rel" ]] && return 0
    mkdir -p "$(dirname -- "$ORIGINAL/files/$rel")"
    cp -a -- "$path" "$ORIGINAL/files/$rel"
}

put() {              # put SRC at DEST (file or folder), keeping the original
    local src="$1" dest="$2"
    keep_original "$dest"
    rm -rf -- "$dest"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -a -- "$src" "$dest"
    mark_installed "$dest"
}

write_file() {       # write stdin to DEST, keeping the original
    local dest="$1" tmp
    keep_original "$dest"
    mkdir -p -- "$(dirname -- "$dest")"
    tmp="$(mktemp "$dest.XXXXXX")"
    cat > "$tmp"
    chmod 644 "$tmp"
    rm -rf -- "$dest"
    mv -- "$tmp" "$dest"
    mark_installed "$dest"
}

backup() {
    step "Saving your current desktop settings"
    mkdir -p "$STATE"
    if [[ ! -e "$ORIGINAL/dconf.ini" ]]; then
        mkdir -p "$ORIGINAL"
        dconf dump / > "$ORIGINAL/dconf.ini"
        date -Iseconds > "$ORIGINAL/date"
        ok "saved in $ORIGINAL (./uninstall.sh uses it)"
    else
        ok "kept the copy from your first install ($(cat "$ORIGINAL/date" 2>/dev/null || echo earlier))"
    fi
    dconf dump / > "$STATE/dconf-before-last-install.ini"
}

# --- steps ---------------------------------------------------------------------------------------

packages() {
    step "Packages and the Firefox setting (needs your password)"
    if [[ $PACKAGES_ON = 0 ]]; then
        warn "skipped (--no-packages): menus of Firefox, Chrome and VS Code may not reach the top bar"
        return
    fi
    local wanted p missing=() absent=()
    read -r -a wanted <<<"$(desktop_packages)"
    ((GNOME_MAJOR < 48)) && read -r -a p <<<"$(theme_build_packages)" && wanted+=("${p[@]}")
    if [[ $TERMINAL_ON = 1 ]]; then
        read -r -a p <<<"$(terminal_packages)" && wanted+=("${p[@]}")
        # A terminal app macstyle can style, if there is none (Debian's default, Console, cannot be)
        if ! command -v ptyxis >/dev/null && ! command -v gnome-terminal >/dev/null; then
            wanted+=(ptyxis)
        fi
    fi
    FIREFOX_BIN="$(command -v firefox || command -v firefox-esr || true)"
    for p in "${wanted[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if ((${#missing[@]})) || { [[ $APPS_ON = 1 && -n "$FIREFOX_BIN" ]]; }; then
        sudo -v || die "sudo did not work (wrong password, or this account is not an administrator)." \
            "Nothing on your desktop has changed yet. Run ./install.sh again, or ./install.sh --no-packages to skip this step."
    fi
    if ((${#missing[@]})); then
        local get=()
        for p in "${missing[@]}"; do
            if pkg_available "$p"; then get+=("$p"); else absent+=("$p"); fi
        done
        if [[ " ${absent[*]} " == *" ptyxis "* ]] && pkg_available gnome-terminal; then get+=(gnome-terminal); fi
        if ((${#get[@]})); then
            info "installing: ${get[*]}"
            pkg_install "${get[@]}"
        fi
    fi
    ok "packages: ${wanted[*]}"
    ((${#absent[@]})) && info "not in this distribution's repositories: ${absent[*]} (fastfetch and lsd are downloaded instead)"
    if [[ $APPS_ON = 1 && -n "$FIREFOX_BIN" ]]; then
        # Debian's Firefox ESR reads its defaults from its own folder; Fedora's, Ubuntu's snap and
        # Mozilla's packages read /etc/firefox/policies.
        if [[ "${FIREFOX_BIN##*/}" = firefox-esr && -d /usr/lib/firefox-esr && -z "${MACSTYLE_FIREFOX_POLICIES:-}" ]]; then
            FIREFOX_POLICIES=/usr/lib/firefox-esr/distribution/policies.json
        fi
        echo "$FIREFOX_POLICIES" > "$STATE/firefox-policies-path"
        # Firefox: its menu in the top bar, and GNOME's title bar instead of tabs in the title bar.
        # A default value for every profile, also ones made later; you can still change both
        # in about:config.
        local merged
        merged="$({ cat "$FIREFOX_POLICIES" 2>/dev/null || true; } | python3 -I -c '
import json, sys
text = sys.stdin.read().strip()
data = json.loads(text) if text else {}
prefs = data.setdefault("policies", {}).setdefault("Preferences", {})
prefs["widget.gtk.global-menu.enabled"] = {"Value": True, "Status": "default"}
prefs["browser.tabs.inTitlebar"] = {"Value": 0, "Status": "default"}
print(json.dumps(data, indent=2))')"
        if [[ ! -e "$STATE/firefox-policies-existed" && ! -e "$STATE/firefox-policies-new" ]]; then
            if [[ -e "$FIREFOX_POLICIES" ]]; then
                mkdir -p "$ORIGINAL/files-root"
                cp -- "$FIREFOX_POLICIES" "$ORIGINAL/files-root/policies.json"
                touch "$STATE/firefox-policies-existed"
            else
                touch "$STATE/firefox-policies-new"
            fi
        fi
        sudo mkdir -p "$(dirname -- "$FIREFOX_POLICIES")"
        printf '%s\n' "$merged" | sudo tee "$FIREFOX_POLICIES" >/dev/null
        sudo chmod 644 "$FIREFOX_POLICIES"
        ok "Firefox: top-bar menu and system title bar ($FIREFOX_POLICIES)"
    fi
}

# Does the extension in DIR declare this GNOME version?
declares_gnome() {
    python3 -I -c 'import json, sys
m = json.load(open(sys.argv[1] + "/metadata.json"))
sys.exit(0 if sys.argv[2] in [str(v).split(".")[0] for v in m.get("shell-version", [])] else 1)' "$1" "$GNOME_MAJOR"
}

# The extensions for this computer, recorded in $STATE/extensions.list: each bundled copy that
# declares this GNOME version; for the rest, the same extension from extensions.gnome.org (or its
# GitHub releases), checked for this version. The dock falls back from Dash2Dock Motion to
# Dash2Dock Lite (also magnifies) to Dash to Dock.
extensions() {
    step "GNOME extensions for GNOME $GNOME_MAJOR"
    local dir uuid got=() fetch=() tmp line count=0 status rest
    local per_version=(CoverflowAltTab@palatis.blogspot.com rounded-window-corners@fxgn user-theme@gnome-shell-extensions.gcampax.github.com)
    for dir in "$REPO"/extensions/*/ ${GNOME_SET:+"$REPO/extensions-$GNOME_SET"/*/}; do
        dir="${dir%/}" uuid="$(basename -- "$dir")"
        if declares_gnome "$dir"; then
            put "$dir" "$EXT_DIR/$uuid"
            got+=("$uuid")
            count=$((count + 1))
        else
            case "$uuid" in
                dash2dock-motion@unmade.space) fetch+=(dash2dock-lite@icedman.github.com) ;;
                downloads-fan@macstyle.local) ;;   # the Downloads icon opens the folder instead
                *) fetch+=("$uuid") ;;
            esac
        fi
    done
    [[ -n "$GNOME_SET" ]] || fetch+=("${per_version[@]}")
    if ((${#fetch[@]})); then
        info "downloading the extensions made for GNOME $GNOME_MAJOR: ${fetch[*]}"
        tmp="$(mktemp -d)"
        while IFS= read -r line; do
            read -r status uuid rest <<<"$line"
            if [[ "$status" = ok ]]; then
                put "$tmp/$uuid" "$EXT_DIR/$uuid"
                got+=("$uuid")
                count=$((count + 1))
            else
                warn "$uuid: $rest"
            fi
        done < <(python3 -I "$REPO/lib/fetch-extension.py" "$GNOME_MAJOR" "$tmp" "${fetch[@]}")
        # No magnifying dock for this GNOME: Dash to Dock, set up like a Mac's dock.
        if [[ " ${fetch[*]} " == *" dash2dock-lite@icedman.github.com "* && " ${got[*]} " != *" dash2dock-lite@icedman.github.com "* ]]; then
            if python3 -I "$REPO/lib/fetch-extension.py" "$GNOME_MAJOR" "$tmp" dash-to-dock@micxgx.gmail.com | grep -q '^ok'; then
                put "$tmp/dash-to-dock@micxgx.gmail.com" "$EXT_DIR/dash-to-dock@micxgx.gmail.com"
                got+=(dash-to-dock@micxgx.gmail.com)
                count=$((count + 1))
            fi
        fi
        rm -rf -- "$tmp"
    fi
    mkdir -p "$STATE"
    printf '%s\n' "${got[@]}" > "$STATE/extensions.list"
    ok "$count extensions in $EXT_DIR"
}

# The dock this install uses: the first of these it put in place.
chosen_dock() {
    local d
    for d in dash2dock-motion@unmade.space dash2dock-lite@icedman.github.com dash-to-dock@micxgx.gmail.com; do
        grep -qxF "$d" "$STATE/extensions.list" && { echo "$d"; return; }
    done
}

themes() {
    step "Themes, icons and cursor"
    local t
    if ((GNOME_MAJOR >= 48)); then
        # Built for GNOME 48 and newer (WhiteSur's top-bar theme is the same for all of them)
        for t in WhiteSur-Light WhiteSur-Dark; do
            put "$REPO/themes/$t" "$THEMES_DIR/$t"
        done
    else
        # Older GNOME: built here by WhiteSur's own installer, for this GNOME version
        info "building the WhiteSur theme for GNOME $GNOME_MAJOR..."
        command -v sassc >/dev/null || die "sassc is needed to build the theme for GNOME $GNOME_MAJOR (run without --no-packages)."
        local wtmp wsrc; wtmp="$(mktemp -d)"
        curl -fsSL --retry 3 "$WHITESUR_URL" -o "$wtmp/ws.tar.gz" ||
            die "could not download $WHITESUR_URL. Check the internet connection and run ./install.sh again."
        tar -xzf "$wtmp/ws.tar.gz" -C "$wtmp"
        wsrc="$(find "$wtmp" -maxdepth 1 -type d -name 'WhiteSur-gtk-theme-*' -print -quit)"
        for t in WhiteSur-Light WhiteSur-Dark; do keep_original "$THEMES_DIR/$t"; done
        (cd "$wsrc" && ./install.sh -d "$THEMES_DIR" -c light -c dark >"$wtmp/build.log" 2>&1) ||
            { tail -n 20 "$wtmp/build.log" >&2; die "the WhiteSur theme did not build (see above)."; }
        for t in WhiteSur-Light WhiteSur-Dark; do
            [[ -d "$THEMES_DIR/$t" ]] || die "the WhiteSur build made no $t theme."
            mark_installed "$THEMES_DIR/$t"
        done
        rm -rf -- "$wtmp"
    fi
    keep_original "$THEMES_DIR/WhiteSur-Light-soft"
    bash "$REPO/lib/make-soft-theme.sh" "$THEMES_DIR/WhiteSur-Light" "$THEMES_DIR/WhiteSur-Light-soft" \
        "$REPO/lib/map-softer.json" >/dev/null
    mark_installed "$THEMES_DIR/WhiteSur-Light-soft"
    ok "WhiteSur Light (soft), WhiteSur Dark"

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
        (cd "$src" && ./install.sh -d "$ICONS_DIR" >/dev/null 2>&1) ||
            die "the MacTahoe icon installer failed."
        for t in MacTahoe MacTahoe-light MacTahoe-dark; do mark_installed "$ICONS_DIR/$t"; done
        rm -rf -- "$tmp"
        ok "MacTahoe icons and cursor installed"
    fi

    # GTK 4 and libadwaita apps (Files, Settings, Text Editor...) take the theme from this file,
    # in light and dark. Unite adds its own lines for the window buttons at the next login.
    local f
    for f in gtk.css gtk-dark.css assets windows-assets; do
        [[ -L "$CONFIG_HOME/gtk-4.0/$f" ]] && { keep_original "$CONFIG_HOME/gtk-4.0/$f"; rm -f -- "$CONFIG_HOME/gtk-4.0/$f"; }
    done
    write_file "$CONFIG_HOME/gtk-4.0/gtk.css" <<EOF
@media (prefers-color-scheme: light) { @import url("file://$THEMES_DIR/WhiteSur-Light-soft/gtk-4.0/gtk.css"); }
@media (prefers-color-scheme: dark)  { @import url("file://$THEMES_DIR/WhiteSur-Dark/gtk-4.0/gtk.css"); }
EOF
    ok "GTK 4 apps follow the theme ($CONFIG_HOME/gtk-4.0/gtk.css)"
}

wallpapers() {
    step "Wallpapers (day and night)"
    local w file title xml="" list="$DATA_HOME/gnome-background-properties/$NAME.xml"
    keep_original "$WALL_DIR"
    mkdir -p "$WALL_DIR"
    mark_installed "$WALL_DIR"
    for w in "${WALLPAPERS[@]}"; do
        file="${w%%:*}" title="${w#*:}"
        cp -f "$REPO/wallpapers/$file-l.jpg" "$REPO/wallpapers/$file-d.jpg" "$WALL_DIR/"
        xml+="  <wallpaper deleted=\"false\">
    <name>$title</name>
    <filename>$WALL_DIR/$file-l.jpg</filename>
    <filename-dark>$WALL_DIR/$file-d.jpg</filename-dark>
    <options>zoom</options>
    <shade_type>solid</shade_type>
    <pcolor>#1c3b5a</pcolor>
    <scolor>#000000</scolor>
  </wallpaper>
"
    done
    cp -f "$REPO/wallpapers/CREDITS.txt" "$WALL_DIR/"
    if [[ -f "$list" ]]; then   # pictures listed there before, other than ours, stay in the list
        xml+="$(python3 -I "$REPO/lib/wallpaper-list.py" "$list" "$WALL_DIR")"
        [[ -z "$xml" || "$xml" == *$'\n' ]] || xml+=$'\n'
    fi
    write_file "$list" <<EOF
<?xml version="1.0"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
$xml</wallpapers>
EOF
    # A run after an update keeps the pair you picked from ours; otherwise "Mountain".
    local current; current="$(gsettings get org.gnome.desktop.background picture-uri)"
    if [[ "$current" == "'file://$WALL_DIR/"*"-l.jpg'" && -f "$(sed "s|^'file://||; s|'$||" <<<"$current")" ]]; then
        ok "six day-and-night pairs (Settings > Appearance), your choice kept"
        return
    fi
    gsettings set org.gnome.desktop.background picture-uri "file://$WALL_DIR/$DEFAULT_WALLPAPER-l.jpg"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALL_DIR/$DEFAULT_WALLPAPER-d.jpg"
    gsettings set org.gnome.desktop.background picture-options zoom
    ok "six day-and-night pairs (Settings > Appearance), \"Mountain\" set"
}

services() {
    step "Dark Style switch and app helper (small background services)"
    put "$REPO/bin/macstyle-darkswitch" "$BIN_DIR/macstyle-darkswitch"
    put "$REPO/bin/macstyle-appfollow" "$BIN_DIR/macstyle-appfollow"
    put "$REPO/libexec/downloads-stack" "$LIBEXEC_DIR/downloads-stack"
    chmod 755 "$BIN_DIR/macstyle-darkswitch" "$BIN_DIR/macstyle-appfollow" "$LIBEXEC_DIR/downloads-stack"
    local u
    for u in macstyle-darkswitch.service macstyle-appfollow.service macstyle-appfollow.path; do
        put "$REPO/systemd/$u" "$UNIT_DIR/$u"
    done
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "no systemd user session here: the services start at your next login"
        return
    fi
    systemctl --user daemon-reload
    systemctl --user enable macstyle-darkswitch.service >/dev/null 2>&1
    if [[ $APPS_ON = 1 ]]; then
        systemctl --user enable macstyle-appfollow.service macstyle-appfollow.path >/dev/null 2>&1
        systemctl --user start macstyle-appfollow.path
    fi
    systemctl --user restart macstyle-darkswitch.service
    ok "Dark Style now switches themes, icons, top bar, dock and window shadows together"
}

launcher() {
    # The Downloads icon in the dock: a click fans out the newest files (Downloads Fan extension).
    write_file "$APPS_DIR/downloads-folder.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Downloads
Comment=Show the newest downloads; opens the Downloads folder when the Downloads Fan extension is off
Icon=folder-download
Exec="$LIBEXEC_DIR/downloads-stack" toggle
Terminal=false
StartupNotify=false
Categories=Utility;
Actions=folder;latest;reveal;

[Desktop Action folder]
Name=Open Downloads Folder
Exec="$LIBEXEC_DIR/downloads-stack" open-folder

[Desktop Action latest]
Name=Open Most Recent Download
Exec="$LIBEXEC_DIR/downloads-stack" open-latest

[Desktop Action reveal]
Name=Show Most Recent in Files
Exec="$LIBEXEC_DIR/downloads-stack" reveal-latest
EOF
}

settings() {
    step "Settings"
    dconf load / < "$REPO/settings/extensions.dconf"
    # The top bar's menu shows this distribution's logo
    local logo=start-here-symbolic
    if find /usr/share/icons /usr/share/pixmaps "$ICONS_DIR" -name "distributor-logo-$DISTRO_ID*" -print -quit 2>/dev/null | grep -q .; then
        logo="distributor-logo-$DISTRO_ID"
    fi
    dconf write /org/gnome/shell/extensions/appmenu/menu-icon "'$logo'"
    local dock; dock="$(chosen_dock)"
    if [[ "$dock" = dash-to-dock@micxgx.gmail.com ]]; then
        dconf load /org/gnome/shell/extensions/dash-to-dock/ < "$REPO/settings/dash-to-dock.dconf"
    fi
    ok "settings of the extensions (dock: ${dock:-none})"
    gsettings set org.gnome.desktop.interface gtk-theme 'WhiteSur-Light-soft'
    gsettings set org.gnome.desktop.interface icon-theme 'MacTahoe-light'
    gsettings set org.gnome.desktop.interface cursor-theme 'MacTahoe-light'
    gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:appmenu'
    gsettings set org.gnome.mutter workspaces-only-on-primary false
    if fc-list : family 2>/dev/null | grep -E '(^|,)SF Pro Display(,|$)' >/dev/null; then
        gsettings set org.gnome.desktop.interface font-name 'SF Pro Display 11'
        ok "font: SF Pro Display (found on this computer)"
    fi
    ok "window buttons on the left, themes, icons and cursor"
    launcher
    local uuids=() pkgext=() conflicts=() c
    mapfile -t uuids < "$STATE/extensions.list"
    read -r -a pkgext <<<"$(package_extensions)"
    for c in "${CONFLICTING_EXTENSIONS[@]}"; do [[ "$c" = "$dock" ]] || conflicts+=("$c"); done
    gsettings set org.gnome.shell disable-user-extensions false
    python3 -I "$REPO/lib/dconf-tool.py" enable "${uuids[@]}" "${pkgext[@]}" --disable "${conflicts[@]}"
    python3 -I "$REPO/lib/dconf-tool.py" add-favorite downloads-folder.desktop
    ok "extensions switched on (they start at your next login); Downloads added to the dock"
}

apps() {
    step "Apps: VS Code, Chrome, Firefox and other Chromium or Electron apps"
    if [[ $APPS_ON = 0 ]]; then
        warn "skipped (--no-apps)"
        return
    fi
    # Chromium browsers and Electron apps (VS Code, Chrome, Brave, Discord...) as X11 clients with
    # GNOME's title bar: their menus go to the top bar and the window buttons follow Unite. The
    # service does this again for every app installed later.
    "$BIN_DIR/macstyle-appfollow" || warn "macstyle-appfollow reported a problem (see above)"
    if [[ -x /usr/bin/code ]]; then
        # "code" typed in a terminal starts VS Code the same way.
        write_file "$BIN_DIR/code" <<'EOF'
#!/bin/sh
# VS Code as an X11 client, like its launcher (macstyle): the top bar shows its menu.
exec /usr/bin/code --ozone-platform=x11 "$@"
EOF
        chmod 755 "$BIN_DIR/code"
    fi
    local vscode_args=("$STATE")
    [[ $TERMINAL_ON = 1 ]] && vscode_args+=(--terminal)
    python3 -I "$REPO/lib/vscode-colors.py" "${vscode_args[@]}"
    # Firefox as packaged by Fedora, Mozilla, Debian (ESR) and Ubuntu (snap)
    local ff
    for ff in /usr/share/applications/org.mozilla.firefox.desktop /usr/share/applications/firefox.desktop \
              /usr/share/applications/firefox-esr.desktop /var/lib/snapd/desktop/applications/firefox_firefox.desktop; do
        [[ -f "$ff" ]] || continue
        { echo "# macstyle: copy of $ff with MOZ_ENABLE_WAYLAND=0,"
          echo "# so Firefox runs as an X11 client and its menu and window buttons go to the top bar."
          sed 's/^Exec=/Exec=env MOZ_ENABLE_WAYLAND=0 /' "$ff"
        } | write_file "$APPS_DIR/$(basename -- "$ff")"
        ok "Firefox launcher ($(basename -- "$ff"))"
    done
    update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
    ok "apps done; an app that is open now changes the next time you start it"
}

terminal() {
    step "Terminal: zsh with round pills, icons, your distribution's logo and a see-through window"
    if [[ $TERMINAL_ON = 0 ]]; then
        warn "skipped (--no-terminal)"
        return
    fi
    if ! command -v zsh >/dev/null; then
        warn "zsh is not installed (--no-packages?), so the terminal is left as it is"
        return
    fi
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

    # Ptyxis, Fedora's terminal: our colours (light and dark), the font, a see-through background.
    if [[ -f /usr/share/glib-2.0/schemas/org.gnome.Ptyxis.gschema.xml ]]; then
        put "$REPO/terminal/macstyle.palette" "$DATA_HOME/org.gnome.Ptyxis/palettes/macstyle.palette"
        local uuid login profile
        uuid="$(gsettings get org.gnome.Ptyxis default-profile-uuid | tr -d "'")"
        [[ -n "$uuid" ]] || uuid="$(gsettings get org.gnome.Ptyxis profile-uuids | grep -oE '[0-9a-f]{32}' | head -n 1 || true)"
        if [[ -z "$uuid" ]]; then   # Ptyxis has not been opened yet: make its first profile
            uuid="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
            gsettings set org.gnome.Ptyxis profile-uuids "['$uuid']"
        fi
        gsettings set org.gnome.Ptyxis default-profile-uuid "$uuid"
        echo "$uuid" > "$STATE/ptyxis-profile"
        profile="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$uuid/"
        gsettings set org.gnome.Ptyxis use-system-font false
        gsettings set org.gnome.Ptyxis font-name 'JetBrainsMono Nerd Font 11'
        gsettings set org.gnome.Ptyxis interface-style 'system'
        gsettings set "$profile" palette 'macstyle'
        gsettings set "$profile" opacity 0.88
        login="${MACSTYLE_LOGIN_SHELL:-$(getent passwd "$USER" | cut -d: -f7)}"
        if [[ "${login##*/}" != zsh ]]; then   # the login shell stays; the terminal app runs zsh
            gsettings set "$profile" use-custom-command true
            gsettings set "$profile" custom-command 'zsh'
        fi
        # Blur my Shell blurs the desktop behind Ptyxis; the window stays opaque, so text is sharp.
        local blur=/org/gnome/shell/extensions/blur-my-shell/applications
        python3 -I "$REPO/lib/dconf-tool.py" add-to-list "$blur/whitelist" org.gnome.Ptyxis
        dconf write "$blur/blur" true
        dconf write "$blur/opacity" 255
        dconf write "$blur/dynamic-opacity" false
        ok "Ptyxis: macstyle colours in light and dark, the font, see-through with blur"
    elif command -v gnome-terminal >/dev/null; then
        # GNOME Terminal (Ubuntu 24.04, Debian): the macstyle colours, the font, zsh, see-through
        local guuid gp
        guuid="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'")"
        if [[ -z "$guuid" ]]; then
            guuid="$(cat /proc/sys/kernel/random/uuid)"
            gsettings set org.gnome.Terminal.ProfilesList list "['$guuid']"
            gsettings set org.gnome.Terminal.ProfilesList default "$guuid"
        fi
        echo "$guuid" > "$STATE/gnome-terminal-profile"
        gp="/org/gnome/terminal/legacy/profiles:/:$guuid"
        # the palette file and the converter stay installed, for macstyle-darkswitch
        put "$REPO/terminal/macstyle.palette" "$DATA_HOME/org.gnome.Ptyxis/palettes/macstyle.palette"
        put "$REPO/lib/palette-to-gterm.py" "$LIBEXEC_DIR/macstyle-gterm-colors"
        python3 -I "$LIBEXEC_DIR/macstyle-gterm-colors" "$REPO/terminal/macstyle.palette" "$gp"
        dconf write "$gp/use-system-font" false
        dconf write "$gp/font" "'JetBrainsMono Nerd Font 11'"
        dconf write "$gp/use-transparent-background" true
        dconf write "$gp/background-transparency-percent" 8
        login="${MACSTYLE_LOGIN_SHELL:-$(getent passwd "$USER" | cut -d: -f7)}"
        if [[ "${login##*/}" != zsh ]]; then
            dconf write "$gp/use-custom-command" true
            dconf write "$gp/custom-command" "'zsh'"
        fi
        ok "GNOME Terminal: macstyle colours (follow Dark Style), the font, zsh, see-through"
    else
        warn "no Ptyxis or GNOME Terminal here: zsh and the prompt are set up, the terminal colours are not"
    fi
}

finish() {
    step "Done"
    cat <<EOF
    Log out and log back in to finish: GNOME starts new extensions only at login.

    After that:
      - Dark Style (Quick Settings) switches everything, wallpaper included.
      - Maximize a window: its buttons and its menu move to the top bar.
      - Click Downloads in the dock to fan out your newest files.
      - Open Terminal: zsh with the round pills prompt (open a new one to see it).

    Undo everything:  ./uninstall.sh
    Log of this run:  $LOG
EOF
    if ask "Log out now? [y/N]" n; then
        gnome-session-quit --logout || true
    fi
}

main() {
    mkdir -p "$STATE"
    LOG="$STATE/install-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG") 2>&1
    printf '%smacstyle%s: a macOS-like GNOME desktop for %s\n' "$B" "$N" "$DISTRO_NAME"
    preflight
    packages   # first: dconf itself may be one of them
    backup
    extensions
    themes
    wallpapers
    settings
    services
    apps
    terminal
    finish
}

main
