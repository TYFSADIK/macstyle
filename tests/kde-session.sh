#!/usr/bin/env bash
# CI, KDE Plasma: run as the test user inside dbus-run-session. Starts KWin (headless) and Plasma
# as a login would, installs macstyle, checks it, switches to dark, uninstalls, checks every file.
# No screenshots: KWin's screenshot path needs a graphics card, which the runners have not got.
set -Eeuo pipefail
cd ~/macstyle
uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/$uid" XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
    XDG_SESSION_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6
# A crash shows as an error in the log, not as a crash dialog waiting for a click (DrKonqi); and no
# "Welcome to Plasma" window at the first start
export KDE_DEBUG=1
mkdir -p ~/.config && printf '[General]\nLastSeenVersion=99.0.0\nShowUpdatePage=false\n' > ~/.config/plasma-welcomerc
# as startplasma sets it: the global theme's values live in ~/.config/kdedefaults
export XDG_CONFIG_DIRS="$HOME/.config/kdedefaults:${XDG_CONFIG_DIRS:-/etc/xdg}"
kwin_wayland --virtual --no-lockscreen --width 1440 --height 900 --xwayland > /tmp/kwin.log 2>&1 &

for _ in $(seq 1 30); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 1; done
export WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland
# (No dbus-update-activation-environment, unlike a real login: services D-Bus would then start on
# their own, kded and the portals, look for a graphics card, which a container has not got, and
# KWin crashes. Plasma and macstyle's own commands are started directly and see the session.)
kwin_pid=$!
# Plasma's desktops belong to an activity: the activity manager first (D-Bus would start it at a login)
kamd="$(find /usr/libexec /usr/lib -name kactivitymanagerd -type f -perm -u+x -print -quit 2>/dev/null)"
[ -n "$kamd" ] && { "$kamd" > /tmp/kamd.log 2>&1 & }
sleep 2
start_plasma() {
    plasmashell --no-respawn >> /tmp/plasma.log 2>&1 &
    for _ in $(seq 1 60); do
        gdbus introspect --session --dest org.kde.plasmashell --object-path /PlasmaShell >/dev/null 2>&1 && break
        sleep 1
    done
    sleep 8   # the panels, and the files Plasma writes at its first start
}
start_plasma
kwin_alive() {
    [ "$(ps -o stat= -p "$kwin_pid" 2>/dev/null | cut -c1)" != Z ] && kill -0 "$kwin_pid" 2>/dev/null
}
kwin_alive || { echo "FAIL  KWin stopped before the test began"; exit 1; }
python3 tests/verify-kde.py snapshot /tmp/before.json

./install.sh --yes
sleep 5
status=0
python3 tests/verify-kde.py installed || status=1

QT_FORCE_STDERR_LOGGING=1 plasma-apply-lookandfeel -a com.github.vinceliuice.MacTahoe-Dark 2>&1 | grep -v xrdb || true
sh ~/.local/bin/macstyle-kde-darkswitch   # what its systemd path unit does at a real login
sleep 4
python3 tests/verify-kde.py dark || status=1

# uninstall restarts Plasma itself (as at a login); here it is started by this script instead
MACSTYLE_NO_PLASMA_RESTART=1 ./uninstall.sh --yes
# the files exactly as before, then Plasma back with its own panels (it rewrites its file as it starts)
python3 tests/verify-kde.py uninstalled /tmp/before.json || status=1
start_plasma
python3 tests/verify-kde.py panels-back || status=1
if kwin_alive; then echo "PASS  KWin ran through the whole test"; else echo "FAIL  KWin stopped during the test"; status=1; fi
# shellcheck disable=SC2046
kill $(jobs -p) 2>/dev/null || true
exit "$status"
