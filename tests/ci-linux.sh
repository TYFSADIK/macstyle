#!/usr/bin/env bash
# CI: install macstyle in a Fedora, Ubuntu or Debian container, check every result, start GNOME
# Shell headless to see that each extension loads, take a screenshot, then uninstall and check that
# the settings are back. Runs as root in the container; the install itself runs as a normal user.
#
#   tests/ci-linux.sh            (in the container, from the repository root)
set -Eeuo pipefail
REPO="$(cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$REPO/tests/out"
mkdir -p "$OUT"
# shellcheck source=/dev/null
. /etc/os-release
echo "== $PRETTY_NAME"

# 1. GNOME Shell, a session bus, software rendering, and a normal user with sudo
case " $ID ${ID_LIKE:-} " in
    *" fedora "*)
        dnf install -y -q gnome-shell dconf dbus-daemon python3 curl tar git sudo \
            mesa-dri-drivers ptyxis firefox glib2 which findutils procps-ng xorg-x11-server-Xwayland python3-dbusmock >/dev/null
        ;;
    *" debian "* | *" ubuntu "*)
        export DEBIAN_FRONTEND=noninteractive
        pkgs=(gnome-shell dconf-cli dbus dbus-user-session python3 curl tar git sudo ca-certificates libgl1-mesa-dri
              libglib2.0-bin xz-utils gnome-terminal procps passwd xwayland python3-dbusmock)
        # a mirror can replace a package between update and install: refresh and try once more
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null ||
            { apt-get update -qq && apt-get install -y -qq --no-install-recommends --fix-missing "${pkgs[@]}" >/dev/null; }
        ;;
esac
id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester
# what a real login provides: X11's socket folder (for XWayland) and the user's runtime folder
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
mkdir -p /run/user/1000 && chown tester:tester /run/user/1000 && chmod 700 /run/user/1000
# ...and the system message bus, which GNOME Shell asks about the login session at start
dbus-uuidgen --ensure
mkdir -p /run/dbus
[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork
# ...and the login manager on it. A container does not boot systemd, so a stand-in answers GNOME
# Shell's questions, as in GNOME's own tests (python-dbusmock's logind template).
python3 -m dbusmock --system --template logind >/tmp/logind-mock.log 2>&1 &
for _ in $(seq 1 20); do
    gdbus introspect --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 >/dev/null 2>&1 && break
    sleep 0.5
done
# the test user and its session, as logind would know them
mock() { gdbus call --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 --method "org.freedesktop.DBus.Mock.$1" "${@:2}" >/dev/null; }
mock AddSeat seat0 || true
mock AddUser 1000 tester true || true
mock AddSession c1 seat0 1000 tester true || true
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester
cp -a "$REPO" /home/tester/macstyle
chown -R tester:tester /home/tester/macstyle
gnome-shell --version

# 2. as the user, in one session bus: install, verify, headless shell, uninstall, verify
cat > /home/tester/run.sh <<'EOF'
set -Eeuo pipefail
cd ~/macstyle
export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland XDG_RUNTIME_DIR="/run/user/$(id -u)"
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p /tmp/rt-tester && chmod 700 /tmp/rt-tester && export XDG_RUNTIME_DIR=/tmp/rt-tester; }
gsettings set org.gnome.desktop.interface color-scheme default
dconf dump / > /tmp/before.ini
./install.sh --yes
python3 tests/verify.py installed /tmp/before.ini

# GNOME Shell, headless, with every enabled extension: each must load (state ACTIVE)
gnome-shell --headless --unsafe-mode --virtual-monitor 1440x900 > /tmp/shell.log 2>&1 &
shell=$!
for _ in $(seq 1 60); do gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell >/dev/null 2>&1 && break; sleep 1; done
sleep 15
python3 tests/verify.py extensions
gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot false false /tmp/desktop-light.png >/dev/null || true
gsettings set org.gnome.desktop.interface color-scheme prefer-dark
sleep 4
gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot false false /tmp/desktop-dark.png >/dev/null || true
gsettings set org.gnome.desktop.interface color-scheme default
kill "$shell" 2>/dev/null || true
wait "$shell" 2>/dev/null || true

./uninstall.sh --yes
python3 tests/verify.py uninstalled /tmp/before.ini
EOF
chown tester:tester /home/tester/run.sh
status=0
su - tester -c 'dbus-run-session -- bash ~/run.sh' || status=$?
cp /tmp/shell.log /tmp/desktop-*.png "$OUT/" 2>/dev/null || true
cp -r /home/tester/.local/state/macstyle-uninstalled-*/install-*.log "$OUT/" 2>/dev/null || true
exit $status
