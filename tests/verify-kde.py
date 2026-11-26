"""Checks for the KDE Plasma edition in CI (run as the test user inside the Plasma session).

    verify-kde.py snapshot FILE       record every file under ~/.config, ~/.local/share and ~ dotfiles
    verify-kde.py installed           the theme, the window buttons, the panels, Konsole
    verify-kde.py dark                after switching to MacTahoe Dark: Konsole follows
    verify-kde.py uninstalled FILE    every file as in the snapshot
"""
import hashlib
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config")
DATA = os.path.join(HOME, ".local", "share")
# written by Plasma, KWin and friends on their own while the session runs, not by macstyle
NOISE = ("kactivitymanagerd", "baloo", "recently-used", "user-places.xbel", "RecentDocuments",
         "kded6", "kwalletd", "plasmashellrc.lock", ".lock", "klipper", "dolphin", "konsole/sessions",
         "kscreen", "kcookiejar", "kioworker", "Trash", "kxkbrc", "ksmserver", "pulse", "plasma-systemmonitor",
         "kdedefaults", "kservicemenurc", "mimeapps.list", "kded5rc", "kded6rc", "kwalletrc", "kconf_update",
         "plasma_workspace.notifyrc", "plasmanotifyrc", "kglobalshortcutsrc", "kiorc", "kfontinst",
         "xdg-desktop-portal", "flatpak", "applications/mimeinfo.cache", "gtk-3.0/bookmarks", "kactivitymanagerdrc",
         "systemsettingsrc", "khotkeysrc", "akonadi", "kpeople", "kpeoplevcard", "plasma/plasmoids/.cache",
         "zsh/", ".zcompdump", "gitstatus", ".cache", "user-dirs", "dconf/user", "Kvantum/kvantum.kvconfig",
         "fontconfig", "kwinoutputconfig.json", "kwinrulesrc")
results = []


def check(name, cond, detail=""):
    results.append(cond)
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f": {detail}" if detail else ""))


def kread(f, g, k):
    return subprocess.run(["kreadconfig6", "--file", f, "--group", g, "--key", k],
                          capture_output=True, text=True).stdout.strip()


def plasma(js):
    out = subprocess.run(["gdbus", "call", "--session", "--dest", "org.kde.plasmashell", "--object-path",
                          "/PlasmaShell", "--method", "org.kde.PlasmaShell.evaluateScript", js],
                         capture_output=True, text=True)
    s = out.stdout.strip()
    return s[2:-3].encode().decode("unicode_escape") if s.startswith("('") else out.stderr.strip()


def snapshot():
    files = {}
    roots = [CONFIG, DATA] + [os.path.join(HOME, f) for f in os.listdir(HOME) if f.startswith(".") and
                               os.path.isfile(os.path.join(HOME, f))]
    for root in roots:
        walk = [(os.path.dirname(root), [], [os.path.basename(root)])] if os.path.isfile(root) else os.walk(root)
        for d, _, names in walk:
            for n in names:
                p = os.path.join(d, n)
                rel = os.path.relpath(p, HOME)
                if any(x in rel for x in NOISE) or not os.path.isfile(p) or os.path.islink(p):
                    continue
                with open(p, "rb") as f:
                    files[rel] = hashlib.sha256(f.read()).hexdigest()
    return files


def main():
    what = sys.argv[1]
    if what == "snapshot":
        json.dump(snapshot(), open(sys.argv[2], "w"))
        return 0
    if what == "installed":
        check("global theme", kread("kdeglobals", "KDE", "LookAndFeelPackage").startswith("com.github.vinceliuice.MacTahoe-"),
              kread("kdeglobals", "KDE", "LookAndFeelPackage"))
        check("colours", kread("kdeglobals", "General", "ColorScheme").startswith("MacTahoe"), kread("kdeglobals", "General", "ColorScheme"))
        check("icons", kread("kdeglobals", "Icons", "Theme").startswith("MacTahoe"), kread("kdeglobals", "Icons", "Theme"))
        check("cursor", kread("kcminputrc", "Mouse", "cursorTheme").startswith("MacTahoe"), kread("kcminputrc", "Mouse", "cursorTheme"))
        check("Plasma style", kread("plasmarc", "Theme", "name").startswith("MacTahoe"), kread("plasmarc", "Theme", "name"))
        check("Kvantum style", kread("kdeglobals", "KDE", "widgetStyle").startswith("kvantum") and
              kread("Kvantum/kvantum.kvconfig", "General", "theme") == "MacTahoe", kread("kdeglobals", "KDE", "widgetStyle"))
        check("window decoration", kread("kwinrc", "org.kde.kdecoration2", "theme").startswith("__aurorae__svg__MacTahoe"),
              kread("kwinrc", "org.kde.kdecoration2", "theme"))
        check("window buttons on the left, macOS order", kread("kwinrc", "org.kde.kdecoration2", "ButtonsOnLeft") == "XIA" and
              kread("kwinrc", "org.kde.kdecoration2", "ButtonsOnRight") == "",
              kread("kwinrc", "org.kde.kdecoration2", "ButtonsOnLeft"))
        check("light and dark themes for Plasma's switch",
              kread("kdeglobals", "KDE", "DefaultDarkLookAndFeel") == "com.github.vinceliuice.MacTahoe-Dark")
        info = json.loads(plasma('''print(JSON.stringify(panels().map(function (p) { return {loc: p.location,
            floating: p.floating, fit: p.lengthMode, hiding: p.hiding,
            widgets: p.widgets().map(function (w) { return w.type; })}; })))'''))
        top = [p for p in info if p["loc"] == "top"]
        dock = [p for p in info if p["loc"] == "bottom"]
        check("two panels: a top bar and a dock", len(info) == 2 and len(top) == 1 and len(dock) == 1, json.dumps(info))
        if top:
            check("top bar: menu, app menus, tray, clock", top[0]["widgets"][:2] == ["org.kde.plasma.kickoff", "org.kde.plasma.appmenu"]
                  and "org.kde.plasma.systemtray" in top[0]["widgets"] and "org.kde.plasma.digitalclock" in top[0]["widgets"])
        if dock:
            check("dock: tasks, floating, fits its icons, steps aside", "org.kde.plasma.icontasks" in dock[0]["widgets"]
                  and dock[0]["floating"] and dock[0]["fit"] == "fit" and dock[0]["hiding"] == "dodgewindows", json.dumps(dock[0]))
        wall = plasma('print(desktops().map(function (d) { d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"]; return d.wallpaperPlugin + " " + d.readConfig("Image"); }).join(" | "))')
        check("wallpaper: macstyle day and night picture", "macstyle-mountain" in wall, wall)
        wp = os.path.join(DATA, "wallpapers", "macstyle-mountain", "contents")
        check("wallpaper has a night picture", os.path.isfile(os.path.join(wp, "images_dark", "3840x2160.jpg")))
        for m in ("light", "dark"):
            check(f"Konsole profile {m}", os.path.isfile(os.path.join(DATA, "konsole", f"macstyle-{m}.profile")) and
                  os.path.isfile(os.path.join(DATA, "konsole", f"macstyle-{m}.colorscheme")))
        check("Konsole uses the light profile", kread("konsolerc", "Desktop Entry", "DefaultProfile") == "macstyle-light.profile",
              kread("konsolerc", "Desktop Entry", "DefaultProfile"))
        for t in ("MacTahoe-light", "MacTahoe-dark"):
            check(f"icon theme {t}", os.path.isfile(os.path.join(DATA, "icons", t, "index.theme")))
        check("zsh prompt block", "# >>> macstyle terminal" in open(os.path.join(HOME, ".zshrc")).read())
    elif what == "dark":
        check("MacTahoe Dark applied", kread("kdeglobals", "General", "ColorScheme") == "MacTahoeDark", kread("kdeglobals", "General", "ColorScheme"))
        check("Kvantum dark", kread("kdeglobals", "KDE", "widgetStyle") == "kvantum-dark", kread("kdeglobals", "KDE", "widgetStyle"))
        check("window buttons stay in macOS order", kread("kwinrc", "org.kde.kdecoration2", "ButtonsOnLeft") == "XIA")
        check("Konsole follows: dark profile", kread("konsolerc", "Desktop Entry", "DefaultProfile") == "macstyle-dark.profile",
              kread("konsolerc", "Desktop Entry", "DefaultProfile"))
    elif what == "uninstalled":
        before = json.load(open(sys.argv[2]))
        after = snapshot()
        changed = sorted(k for k in before if k in after and before[k] != after[k])
        gone = sorted(k for k in before if k not in after)
        extra = sorted(k for k in after if k not in before)
        check("every file as before", not changed, " ".join(changed[:20]))
        check("nothing missing", not gone, " ".join(gone[:20]))
        check("nothing left behind", not extra, " ".join(extra[:20]))
        info = plasma('print(panels().length + ":" + panels().map(function (p) { return p.widgets().map(function (w) { return w.type; }).join("|"); }).join(" / "))')
        check("Plasma back with its own panels", info.split(":")[0] == "1" and "org.kde.plasma.appmenu" not in info, info)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
