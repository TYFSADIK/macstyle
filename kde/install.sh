#!/usr/bin/env bash
# macstyle for KDE Plasma 6: a macOS-like desktop on Fedora KDE, Kubuntu and Debian with KDE.
#
#   ./install.sh          (from the repository root: it starts this script inside Plasma)
#
# A top bar with the menus of the app in front, a floating dock, window buttons on the left, the
# MacTahoe theme in light and dark, day-and-night wallpapers and the macstyle terminal. Every
# file it changes is saved first; ./uninstall.sh puts them back.
#
# Options:
#   -y, --yes          answer every question with its default (no prompts)
#   --no-packages      skip everything that needs sudo
#   --no-terminal      leave the terminal and zsh alone
#   --force            run on a distribution macstyle is not made for
#   -h, --help         show this help
set -Eeuo pipefail
shopt -s nullglob

REPO="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
# shellcheck source=lib/distro.sh
source "$REPO/lib/distro.sh"
# shellcheck source=lib/files.sh
source "$REPO/lib/files.sh"
# shellcheck source=lib/shared.sh
source "$REPO/lib/shared.sh"

MIN_PLASMA=6
PLASMA_VERSION=""   # set by preflight
# MacTahoe KDE: global theme (light and dark), Plasma style, colours, window decorations, Kvantum
MACTAHOE_KDE_COMMIT=cbf6a1f71b591d143184855d62f6272ce533e7c3   # 2026-08-16
MACTAHOE_KDE_URL="https://github.com/vinceliuice/MacTahoe-kde/archive/$MACTAHOE_KDE_COMMIT.tar.gz"
LAF_LIGHT=com.github.vinceliuice.MacTahoe-Light
LAF_DARK=com.github.vinceliuice.MacTahoe-Dark

ASSUME_YES=0 PACKAGES_ON=1 TERMINAL_ON=1 FORCE=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-packages) PACKAGES_ON=0 ;;
        --no-apps) ;;   # the GNOME edition's option; nothing to leave alone here
        --no-terminal) TERMINAL_ON=0 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,/^set -E/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg (see ./install.sh --help)" ;;
    esac
done

trap 'die "install.sh stopped at line $LINENO. Your desktop is half set up: run ./install.sh again, or ./uninstall.sh to go back."' ERR
detect_distro
[[ $EUID -ne 0 ]] || die "run ./install.sh as your normal user, without sudo. It asks for your password itself when it needs it."

# Every KDE settings file the install changes. Each is saved whole before the first change and
# put back whole by ./uninstall.sh (Plasma writes many lines of its own when a theme is applied).
KDE_FILES=(
    "$CONFIG_HOME/kdeglobals"
    "$CONFIG_HOME/kwinrc"
    "$CONFIG_HOME/plasmarc"
    "$CONFIG_HOME/kcminputrc"
    "$CONFIG_HOME/ksplashrc"
    "$CONFIG_HOME/kdedefaults"                          # the global theme's values (Plasma 6.1+)
    "$CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"   # the panels and the wallpaper
    "$CONFIG_HOME/plasmashell-appletsrc"                # (their name since Plasma 6.8)
    "$CONFIG_HOME/plasmashellrc"
    "$CONFIG_HOME/kglobalshortcutsrc"
    "$CONFIG_HOME/konsolerc"
    "$CONFIG_HOME/Kvantum/kvantum.kvconfig"
    "$CONFIG_HOME/gtk-3.0/settings.ini"
    "$CONFIG_HOME/gtkrc"                                # written by Plasma 6.3 with a theme
    "$CONFIG_HOME/gtkrc-2.0"
    "$CONFIG_HOME/Trolltech.conf"
    "$CONFIG_HOME/gtk-4.0/settings.ini"
    "$CONFIG_HOME/xsettingsd/xsettingsd.conf"
    "$HOME/.gtkrc-2.0"
)

kwrite() { kwriteconfig6 --file "$1" --group "$2" --key "$3" "$4"; }
kread()  { kreadconfig6 --file "$1" --group "$2" --key "$3" 2>/dev/null || true; }
plasma_script() {   # run JavaScript in Plasma (the desktop scripting API)
    gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
        --method org.kde.PlasmaShell.evaluateScript "$1"
}

# The Plasma version, from the package manager: a second plasmashell, even with --version, can
# crash on some releases (Debian 13 under Qt's offscreen platform) and open a crash dialog.
plasma_version() {
    local v=""
    case "$DISTRO_FAMILY" in
        fedora) v="$(rpm -q --qf '%{VERSION}' plasma-workspace 2>/dev/null || true)" ;;
        debian) v="$(dpkg-query -W -f='${Version}' plasma-workspace 2>/dev/null || true)"; v="${v#*:}"; v="${v%%[-+~]*}" ;;
    esac
    if [[ ! "$v" =~ ^[0-9]+\. ]]; then   # no package: ask plasmashell, without its crash reporter
        v="$(KDE_DEBUG=1 QT_QPA_PLATFORM=offscreen timeout 10 plasmashell --version 2>/dev/null | awk '{print $2}' || true)"
    fi
    echo "$v"
}

# --- checks --------------------------------------------------------------------------------------

preflight() {
    step "Checking this computer"
    for d in kde lib terminal wallpapers bin systemd; do
        [[ -d "$REPO/$d" ]] || die "$REPO/$d is missing. Run install.sh inside the folder you cloned with git."
    done
    if [[ -z "$DISTRO_FAMILY" ]]; then
        [[ $FORCE = 1 ]] || die "made for Fedora, Ubuntu and Debian (found: $DISTRO_NAME). Use --force to try anyway."
        warn "$DISTRO_NAME is not Fedora, Ubuntu or Debian; going on because of --force, without packages"
        PACKAGES_ON=0
    fi
    command -v plasmashell >/dev/null || die "KDE Plasma is not installed."
    PLASMA_VERSION="$(plasma_version)"
    [[ "${PLASMA_VERSION%%.*}" =~ ^[0-9]+$ ]] || die "could not tell the Plasma version (package plasma-workspace: '$PLASMA_VERSION')."
    ((${PLASMA_VERSION%%.*} >= MIN_PLASMA)) ||
        die "Plasma $PLASMA_VERSION is too old; macstyle needs Plasma 6 (Fedora 40, Kubuntu 25.04, Debian 13 and later)."
    [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
        die "run it from a terminal inside your Plasma desktop (not over SSH or from a text console)."
    for c in kwriteconfig6 kreadconfig6 plasma-apply-lookandfeel python3 curl tar; do
        command -v "$c" >/dev/null || die "the command '$c' is missing."
    done
    if ! command -v gdbus >/dev/null; then
        [[ $PACKAGES_ON = 1 ]] || die "the command 'gdbus' is missing; run without --no-packages to install it."
        info "gdbus is missing; it is installed with the packages"
    fi
    ok "$DISTRO_NAME, Plasma $PLASMA_VERSION, ${XDG_SESSION_TYPE:-?} session"
}

# --- steps ---------------------------------------------------------------------------------------

packages() {
    step "Packages (needs your password)"
    if [[ $PACKAGES_ON = 0 ]]; then
        warn "skipped (--no-packages): without Kvantum, apps use Plasma's Breeze style"
        return
    fi
    local wanted p missing=() absent=() get=()
    read -r -a wanted <<<"$(kde_packages)"
    if [[ $TERMINAL_ON = 1 ]]; then
        read -r -a p <<<"$(terminal_packages)" && wanted+=("${p[@]}")
    fi
    for p in "${wanted[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if ((${#missing[@]})); then
        sudo -v || die "sudo did not work (wrong password, or this account is not an administrator)." \
            "Nothing on your desktop has changed yet. Run ./install.sh again, or ./install.sh --no-packages to skip this step."
        for p in "${missing[@]}"; do
            if pkg_available "$p"; then get+=("$p"); else absent+=("$p"); fi
        done
        if ((${#get[@]})); then
            info "installing: ${get[*]}"
            pkg_install "${get[@]}"
        fi
    fi
    ok "packages: ${wanted[*]}"
    ((${#absent[@]})) && info "not in this distribution's repositories: ${absent[*]} (fastfetch and lsd are downloaded instead)"
    return 0
}

backup() {
    step "Saving your current desktop settings"
    mkdir -p "$STATE"
    echo kde > "$STATE/edition"
    if [[ ! -e "$ORIGINAL/date" ]]; then
        mkdir -p "$ORIGINAL"
        date -Iseconds > "$ORIGINAL/date"
    fi
    # Plasma keeps panels in memory and writes them out a moment later: save what is on screen now
    gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
        --method org.kde.PlasmaShell.evaluateScript 'print("")' >/dev/null 2>&1 || true
    local f
    for f in "${KDE_FILES[@]}"; do
        keep_original "$f"
        mark_installed "$f"
    done
    ok "saved in $ORIGINAL ($(cat "$ORIGINAL/date"); ./uninstall.sh uses it)"
}

themes() {
    step "Themes, icons and cursor"
    local tmp src t s
    tmp="$(mktemp -d)"
    info "downloading the MacTahoe KDE theme..."
    curl -fsSL --retry 3 "$MACTAHOE_KDE_URL" -o "$tmp/kde.tar.gz" ||
        die "could not download $MACTAHOE_KDE_URL. Check the internet connection and run ./install.sh again."
    tar -xzf "$tmp/kde.tar.gz" -C "$tmp"
    src="$(find "$tmp" -maxdepth 1 -type d -name 'MacTahoe-kde-*' -print -quit)"
    [[ -n "$src" && -d "$src/plasma/look-and-feel/$LAF_LIGHT" ]] || die "the MacTahoe KDE download looks wrong ($MACTAHOE_KDE_URL)."

    for t in Light Dark; do
        # Window buttons in macOS order (close, minimize, maximize) also when Plasma switches
        # between the light and dark theme by itself
        sed -i 's/^ButtonsOnLeft=XAI$/ButtonsOnLeft=XIA/' "$src/plasma/look-and-feel/com.github.vinceliuice.MacTahoe-$t/contents/defaults"
        put "$src/plasma/look-and-feel/com.github.vinceliuice.MacTahoe-$t" "$DATA_HOME/plasma/look-and-feel/com.github.vinceliuice.MacTahoe-$t"
        cp -r "$src/plasma/desktoptheme/icons" "$src/plasma/desktoptheme/MacTahoe-$t/"
        put "$src/plasma/desktoptheme/MacTahoe-$t" "$DATA_HOME/plasma/desktoptheme/MacTahoe-$t"
        put "$src/color-schemes/MacTahoe$t.colors" "$DATA_HOME/color-schemes/MacTahoe$t.colors"
        # Window decorations, as MacTahoe's own installer assembles them, at 1x, 1.25x and 1.5x
        for s in "" -1.25x -1.5x; do
            local d="$tmp/aurorae/MacTahoe-$t$s"
            mkdir -p "$d"
            cp "$src/aurorae/MacTahoe-$t$s"/*.svg "$src/aurorae/icons-$t"/*.svg "$d/"
            cp "$src/aurorae/${t}rc" "$d/MacTahoe-$t${s}rc"
            cp "$src/aurorae/metadata.desktop" "$src/aurorae/metadata.json" "$d/"
            sed -i "s/theme_name/MacTahoe-$t$s/g" "$d/metadata.desktop" "$d/metadata.json"
            put "$d" "$DATA_HOME/aurorae/themes/MacTahoe-$t$s"
        done
    done
    put "$src/Kvantum/MacTahoe" "$CONFIG_HOME/Kvantum/MacTahoe"
    put "$src/LICENSE" "$DATA_HOME/$NAME/licenses/MacTahoe-kde.LICENSE"
    rm -rf -- "$tmp"
    ok "MacTahoe KDE (commit ${MACTAHOE_KDE_COMMIT:0:7}): global theme, Plasma style, colours, window decorations, Kvantum"
    icons
}

wallpapers() {
    step "Wallpapers (day and night)"
    # Plasma wallpaper packages: images/ by day, images_dark/ with a dark global theme
    local w file title dir
    for w in "${WALLPAPERS[@]}"; do
        file="${w%%:*}" title="${w#*:}"
        dir="$(mktemp -d)"
        mkdir -p "$dir/contents/images" "$dir/contents/images_dark"
        cp "$REPO/wallpapers/$file-l.jpg" "$dir/contents/images/3840x2160.jpg"
        cp "$REPO/wallpapers/$file-d.jpg" "$dir/contents/images_dark/3840x2160.jpg"
        cat > "$dir/metadata.json" <<EOF
{
    "KPlugin": {
        "Id": "macstyle-$file",
        "Name": "$title (macstyle)",
        "License": "see CREDITS.txt",
        "Authors": [{ "Name": "KDE wallpaper artists" }]
    }
}
EOF
        cp "$REPO/wallpapers/CREDITS.txt" "$dir/"
        put "$dir" "$DATA_HOME/wallpapers/macstyle-$file"
        rm -rf -- "$dir"
    done
    ok "six day-and-night pairs (right-click the desktop > Configure Desktop and Wallpaper)"
}

look() {
    step "Global theme, window buttons, Dark mode"
    # Keep the side you are on: a dark colour scheme now gets MacTahoe Dark
    local laf="$LAF_LIGHT"
    [[ "$(kread kdeglobals General ColorScheme)" == *[Dd]ark* ]] && laf="$LAF_DARK"
    local out rc=0
    out="$(QT_FORCE_STDERR_LOGGING=1 plasma-apply-lookandfeel -a "$laf" 2>&1)" || rc=$?
    if ((rc)); then
        warn "plasma-apply-lookandfeel: exit $rc: $out (trying once more)"
        sleep 2; rc=0
        out="$(QT_FORCE_STDERR_LOGGING=1 plasma-apply-lookandfeel -a "$laf" 2>&1)" || rc=$?
        ((rc == 0)) || die "Plasma did not apply the MacTahoe global theme ($laf), exit $rc: $out"
    fi
    # Plasma 6.5 and newer switch between these two by themselves (System Settings > Colors &
    # Themes > Global Theme: light, dark or automatic at sunset)
    kwrite kdeglobals KDE DefaultLightLookAndFeel "$LAF_LIGHT"
    kwrite kdeglobals KDE DefaultDarkLookAndFeel "$LAF_DARK"
    # Qt's style plugins: /usr/lib64/qt6 (Fedora), /usr/lib/<architecture>/qt6 (Debian, Ubuntu)
    local styles
    styles="$(find /usr/lib64/qt6/plugins/styles /usr/lib/qt6/plugins/styles /usr/lib/*/qt6/plugins/styles \
        -name '*kvantum*' -print -quit 2>/dev/null || true)"
    if [[ -n "$styles" ]]; then
        kwrite Kvantum/kvantum.kvconfig General theme MacTahoe
        ok "Qt and KDE apps: Kvantum, MacTahoe"
    else
        kwrite kdeglobals KDE widgetStyle Breeze   # MacTahoe asks for Kvantum, which is not installed
        warn "Kvantum is not installed: apps keep Plasma's Breeze style (the colours are MacTahoe's)"
    fi
    kwrite kwinrc org.kde.kdecoration2 ButtonsOnLeft XIA
    kwrite kwinrc org.kde.kdecoration2 ButtonsOnRight ""
    gdbus call --session --dest org.kde.KWin --object-path /KWin --method org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    ok "MacTahoe ${laf##*-}; window buttons on the left (close, minimize, maximize)"
}

logo_icon() {   # the distribution's logo for the top-left menu, if an icon theme has it
    local name="distributor-logo-$DISTRO_ID"
    if compgen -G "/usr/share/icons/*/*/apps/$name.*" >/dev/null || compgen -G "/usr/share/icons/*/scalable/*/$name.*" >/dev/null ||
        compgen -G "/usr/share/pixmaps/$name.*" >/dev/null; then
        echo "$name"
    else
        echo start-here-kde-symbolic
    fi
}

layout() {
    step "Top bar and dock"
    local launchers=() a js out
    launchers+=(preferred://filemanager preferred://browser)
    for a in org.kde.konsole org.kde.discover systemsettings; do
        [[ -f "/usr/share/applications/$a.desktop" ]] && launchers+=("applications:$a.desktop")
    done
    js="$(cat "$REPO/kde/layout.js")"
    js="${js//@LOGO@/$(logo_icon)}"
    js="${js//@LAUNCHERS@/$(IFS=,; echo "${launchers[*]}")}"
    js="${js//@WALLPAPER@/file://$DATA_HOME/wallpapers/macstyle-$DEFAULT_WALLPAPER/}"
    out="$(plasma_script "$js" 2>&1)" || die "Plasma did not take the new panels: $out"
    ok "top bar: menu, the app's menus, tray, clock; dock: centred and floating, steps aside for windows"
    ok "wallpaper: \"Mountain\", day and night"
}

services() {
    step "Konsole follows Dark mode"
    put "$REPO/bin/macstyle-kde-darkswitch" "$BIN_DIR/macstyle-kde-darkswitch"
    local u
    for u in macstyle-kde-darkswitch.service macstyle-kde-darkswitch.path; do
        put "$REPO/systemd/$u" "$UNIT_DIR/$u"
    done
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user enable --now macstyle-kde-darkswitch.path >/dev/null 2>&1 ||
            warn "could not start macstyle-kde-darkswitch.path; Konsole will not switch with Dark mode"
        systemctl --user enable macstyle-kde-darkswitch.service >/dev/null 2>&1 || true
        ok "macstyle-kde-darkswitch (a small service: switches Konsole's colours with the theme)"
    else
        warn "no systemd user session here: Konsole will not switch with Dark mode"
    fi
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
    terminal_shell
    local login zsh_flag=() tmp f
    login="${MACSTYLE_LOGIN_SHELL:-$(getent passwd "$USER" | cut -d: -f7)}"
    [[ "${login##*/}" != zsh ]] && zsh_flag=(--zsh)   # the login shell stays; Konsole runs zsh
    tmp="$(mktemp -d)"
    python3 -I "$REPO/lib/palette-to-konsole.py" "$REPO/terminal/macstyle.palette" "$tmp" "${zsh_flag[@]}"
    for f in "$tmp"/*; do put "$f" "$DATA_HOME/konsole/${f##*/}"; done
    rm -rf -- "$tmp"
    sh "$BIN_DIR/macstyle-kde-darkswitch" 2>/dev/null || sh "$REPO/bin/macstyle-kde-darkswitch"
    ok "Konsole: macstyle colours in light and dark, the font, see-through with blur"
}

finish() {
    step "Done"
    cat <<EOF
    Log out and log back in once, so every app picks up the theme. Then:
      - The top bar shows the menus of the app in front (KDE and Qt apps).
      - Dark mode: System Settings > Colors & Themes > Global Theme, MacTahoe Dark (or, on
        Plasma 6.5 and newer, switch between light and dark there, or automatically at sunset).
        The wallpaper and Konsole follow.
      - Alt+Space or Alt+F2 searches apps, files and more (KRunner).
      - Open Konsole: zsh with the round pills prompt.

    Undo everything:  ./uninstall.sh
    Log of this run:  $LOG
EOF
    if ask "Log out now? [y/N]" n; then
        gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown --method org.kde.Shutdown.logout >/dev/null 2>&1 || true
    fi
}

main() {
    mkdir -p "$STATE"
    if [[ -e "$STATE/edition" && "$(cat "$STATE/edition")" != kde ]]; then
        die "the GNOME edition of macstyle is installed for this account: run ./uninstall.sh first."
    fi
    LOG="$STATE/install-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG") 2>&1
    printf '%smacstyle%s: a macOS-like KDE Plasma desktop for %s\n' "$B" "$N" "$DISTRO_NAME"
    preflight
    packages
    backup
    themes
    wallpapers
    look
    layout
    services
    terminal
    finish
}

main
