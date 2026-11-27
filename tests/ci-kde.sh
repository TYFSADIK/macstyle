#!/usr/bin/env bash
# CI, KDE Plasma edition: in a Fedora, Ubuntu or Debian container, install Plasma, start KWin
# (headless) and Plasma, then run tests/kde-session.sh as a normal user: install macstyle, check
# the theme, the panels and Konsole, switch to dark, uninstall, check every file is as before.
#
#   tests/ci-kde.sh            (in the container, from the repository root)
set -Eeuo pipefail
REPO="$(cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$REPO/tests/out"
mkdir -p "$OUT"
# shellcheck source=/dev/null
. /etc/os-release
echo "== $PRETTY_NAME (KDE Plasma)"

case " $ID ${ID_LIKE:-} " in
    *" fedora "*)
        dnf install -y -q plasma-workspace plasma-desktop kwin konsole dbus-daemon glib2 python3 curl tar git sudo \
            mesa-dri-drivers xorg-x11-server-Xwayland libcap which findutils procps-ng >/dev/null
        ;;
    *" debian "* | *" ubuntu "*)
        export DEBIAN_FRONTEND=noninteractive
        pkgs=(plasma-workspace plasma-desktop kwin-wayland konsole dbus dbus-user-session libglib2.0-bin python3 curl
              tar git sudo ca-certificates libgl1-mesa-dri libegl-mesa0 xwayland libcap2-bin procps passwd xz-utils)
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null ||
            { apt-get update -qq && apt-get install -y -qq --no-install-recommends --fix-missing "${pkgs[@]}" >/dev/null; }
        ;;
esac
# KWin asks for real-time priority through a file capability, which a container may not grant
kwin="$(command -v kwin_wayland)"
if getcap "$kwin" 2>/dev/null | grep -q cap_; then setcap -r "$kwin"; fi
dpkg-query -W -f='plasma-workspace ${Version}\n' plasma-workspace 2>/dev/null || rpm -q plasma-workspace

id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
mkdir -p /run/user/1000 && chown tester:tester /run/user/1000 && chmod 700 /run/user/1000
dbus-uuidgen --ensure
mkdir -p /run/dbus
[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester
cp -a "$REPO" /home/tester/macstyle
chown -R tester:tester /home/tester/macstyle

status=0
su - tester -c 'dbus-run-session -- bash ~/macstyle/tests/kde-session.sh' || status=$?
cp /tmp/kwin.log /tmp/plasma.log "$OUT/" 2>/dev/null || true
cp -r /home/tester/.local/state/macstyle-uninstalled-*/install-*.log "$OUT/" 2>/dev/null || true
exit $status
