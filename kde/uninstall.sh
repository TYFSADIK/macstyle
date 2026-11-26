#!/usr/bin/env bash
# macstyle for KDE Plasma: put the desktop back as it was before the first ./install.sh.
#
#   ./uninstall.sh        (asks first; from the repository root it starts this script)
#   ./uninstall.sh --yes  (does not ask)
#
# It brings back every KDE settings file as it was (panels, theme, window buttons, Konsole),
# removes what the install added and stops the Konsole service. Packages stay (harmless).
set -Eeuo pipefail
shopt -s nullglob

REPO="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^set -E/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done
trap 'die "uninstall.sh stopped at line $LINENO. Run it again; it continues where it stopped."' ERR
[[ $EUID -ne 0 ]] || die "run ./uninstall.sh as your normal user, without sudo."
[[ -e "$INSTALLED" ]] || die "nothing to undo: install.sh has not run for this user."
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || die "run it from a terminal inside your Plasma desktop."

printf '%smacstyle%s uninstall (KDE Plasma)\n' "$B" "$N"
when="$(cat "$ORIGINAL/date" 2>/dev/null || echo 'before the first install')"
if [[ $ASSUME_YES != 1 ]]; then
    ask "Put your desktop back as it was on $when? [y/N]" n || { echo "Nothing changed."; exit 0; }
fi

step "Stopping the Konsole service"
systemctl --user disable --now macstyle-kde-darkswitch.path macstyle-kde-darkswitch.service >/dev/null 2>&1 || true
ok "stopped"

step "Terminal"
if [[ -f "$HOME/.zshrc" ]] && grep -q '# >>> macstyle terminal' "$HOME/.zshrc"; then
    zshrc_args=(remove "$HOME/.zshrc")
    [[ -e "$STATE/zshrc-created" ]] && zshrc_args+=(--created)
    python3 -I "$REPO/lib/zshrc-blocks.py" "${zshrc_args[@]}"
    ok "$HOME/.zshrc: the macstyle lines are out (your own lines stay)"
else
    ok "nothing to undo in ~/.zshrc"
fi

step "Panels, theme and files"
# Plasma holds the panels in memory and writes them out when it quits: stop it first, so the
# panels file it writes is replaced by yours, then start it again.
plasma_service=0
if systemctl --user is-active --quiet plasma-plasmashell.service 2>/dev/null; then
    plasma_service=1
    systemctl --user stop plasma-plasmashell.service
elif gdbus introspect --session --dest org.kde.plasmashell --object-path /PlasmaShell >/dev/null 2>&1; then
    kquitapp6 plasmashell >/dev/null 2>&1 || true
fi
for _ in $(seq 1 20); do
    gdbus introspect --session --dest org.kde.plasmashell --object-path /PlasmaShell >/dev/null 2>&1 || break
    sleep 0.5
done
removed=0 restored=0
# Last in, first out, so a folder goes after the files in it.
while IFS= read -r path; do
    [[ -n "$path" && "$path" == "$HOME"/* ]] || continue
    rm -rf -- "$path"
    removed=$((removed + 1))
    rel="${path#"$HOME"/}"
    if [[ -e "$ORIGINAL/files/$rel" || -L "$ORIGINAL/files/$rel" ]]; then
        mkdir -p -- "$(dirname -- "$path")"
        cp -a -- "$ORIGINAL/files/$rel" "$path"
        restored=$((restored + 1))
    fi
done < <(tac "$INSTALLED")
rmdir "$CONFIG_HOME/$NAME/zsh" "$CONFIG_HOME/$NAME" "$DATA_HOME/$NAME/licenses" "$DATA_HOME/$NAME" 2>/dev/null || true
systemctl --user daemon-reload >/dev/null 2>&1 || true
ok "$removed paths removed, $restored of them brought back as they were"
if [[ $plasma_service = 1 ]]; then
    systemctl --user start plasma-plasmashell.service || true
elif [[ -z "${MACSTYLE_NO_PLASMA_RESTART:-}" ]]; then
    (setsid plasmashell >/dev/null 2>&1 &) || true
fi
gdbus call --session --dest org.kde.KWin --object-path /KWin --method org.kde.KWin.reconfigure >/dev/null 2>&1 || true
ok "Plasma started again with your panels"

mkdir -p "$STATE_HOME"
mv -- "$STATE" "$STATE_HOME/$NAME-uninstalled-$(date +%Y%m%d-%H%M%S)"

step "Done"
cat <<EOT
    Log out and log back in to finish (apps pick up your old theme then).
    The saved copy of your old desktop stays in $STATE_HOME/$NAME-uninstalled-*
    (delete it when you are happy). Kvantum and the terminal packages stay installed.
EOT
if ask "Log out now? [y/N]" n; then
    gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown --method org.kde.Shutdown.logout >/dev/null 2>&1 || true
fi
