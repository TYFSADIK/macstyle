# shellcheck shell=bash disable=SC2034
# Which Linux this is, and how to install packages on it. Sourced by install.sh and uninstall.sh.
#
# Fedora uses dnf; Debian, Ubuntu and their relatives use apt. Package names differ between the
# two families, so every list below exists once per family.

DISTRO_ID="" DISTRO_NAME="" DISTRO_FAMILY="" DISTRO_VERSION=""

detect_distro() {
    local ID="" ID_LIKE="" PRETTY_NAME="" VERSION_ID=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    DISTRO_VERSION="${VERSION_ID:-}"
    case " $DISTRO_ID ${ID_LIKE:-} " in
        *" fedora "*) DISTRO_FAMILY=fedora ;;
        *" debian "* | *" ubuntu "*) DISTRO_FAMILY=debian ;;
        *) DISTRO_FAMILY="" ;;
    esac
}

# Packages for the desktop: top-bar menus (libdbusmenu), the Apps Menu extension, and Quick Look
# (sushi: press Space on a file in Files).
desktop_packages() {
    case "$DISTRO_FAMILY" in
        fedora) echo libdbusmenu libdbusmenu-gtk3 gnome-shell-extension-apps-menu gnome-shell-extension-background-logo sushi ;;
        debian) echo libdbusmenu-glib4 libdbusmenu-gtk3-4 gnome-shell-extensions gnome-menus gnome-sushi dconf-cli ;;
    esac
}

# KDE Plasma edition: Kvantum (the MacTahoe style for Qt and KDE apps) and gdbus (to talk to Plasma).
kde_packages() {
    case "$DISTRO_FAMILY" in
        fedora) echo kvantum glib2 ;;
        debian) echo qt6-style-kvantum libglib2.0-bin ;;
    esac
}

# To build the WhiteSur shell theme for GNOME versions it does not ship prebuilt for.
theme_build_packages() {
    case "$DISTRO_FAMILY" in
        fedora) echo sassc glib2-devel libxml2 ;;
        debian) echo sassc libglib2.0-dev-bin libxml2-utils ;;
    esac
}

# For the terminal. fastfetch and lsd are missing from some releases (Debian 12, Ubuntu 24.04);
# install.sh then downloads them from their projects instead.
terminal_packages() {
    echo zsh zsh-autosuggestions zsh-syntax-highlighting fzf zoxide fastfetch lsd
}

# Extensions that come from distribution packages, by UUID.
package_extensions() {
    case "$DISTRO_FAMILY" in
        fedora) echo apps-menu@gnome-shell-extensions.gcampax.github.com background-logo@fedorahosted.org ;;
        debian) echo apps-menu@gnome-shell-extensions.gcampax.github.com ;;
    esac
}

pkg_installed() {
    case "$DISTRO_FAMILY" in
        fedora) rpm -q "$1" >/dev/null 2>&1 ;;
        debian) [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]] ;;
    esac
}

APT_UPDATED=0
pkg_available() {
    case "$DISTRO_FAMILY" in
        fedora) dnf -q list --available "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1 ;;
        debian)
            if [[ $APT_UPDATED = 0 ]]; then
                sudo apt-get update -qq >/dev/null 2>&1 || true
                APT_UPDATED=1
            fi
            # (capture first: with pipefail, grep -q closing the pipe early would fail the check)
            local policy; policy="$(apt-cache policy "$1" 2>/dev/null || true)"
            [[ "$policy" =~ Candidate:\ [0-9] ]]
            ;;
    esac
}

pkg_install() {
    case "$DISTRO_FAMILY" in
        fedora) sudo dnf install -y "$@" ;;
        debian)
            if [[ $APT_UPDATED = 0 ]]; then
                sudo apt-get update -qq
                APT_UPDATED=1
            fi
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
            ;;
    esac
}
