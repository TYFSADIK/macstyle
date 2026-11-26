"""CI checks for tests/ci-linux.sh. Each prints PASS or FAIL lines; the exit code is the number of
failures.

    verify.py installed BEFORE.INI     after install.sh: extensions, settings, files
    verify.py extensions               with GNOME Shell running: every enabled extension loaded
    verify.py uninstalled BEFORE.INI   after uninstall.sh: the settings are back as they were
"""
import configparser
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".local/state/macstyle")
EXT = os.path.join(HOME, ".local/share/gnome-shell/extensions")
failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f": {detail}" if detail else ""))
    failures += 0 if ok else 1


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def gget(schema, key):
    return run("gsettings", "get", schema, key)


def gnome_major():
    return run("gnome-shell", "--version").split()[-1].split(".")[0]


def installed():
    major = gnome_major()
    uuids = [u for u in open(os.path.join(STATE, "extensions.list")).read().split() if u]
    check("extensions chosen", len(uuids) >= 8, f"{len(uuids)} for GNOME {major}: {' '.join(uuids)}")
    wrong = []
    for u in uuids:
        meta = json.load(open(os.path.join(EXT, u, "metadata.json")))
        if major not in [str(v).split(".")[0] for v in meta.get("shell-version", [])]:
            wrong.append(u)
    check("every extension declares this GNOME version", not wrong, ", ".join(wrong) or f"GNOME {major}")
    ding = os.path.join(EXT, "ding@rastersoft.com", "app", "ding.js")
    if "ding@rastersoft.com" in uuids:
        check("desktop icons can start (ding.js executable)", os.access(ding, os.X_OK))
    docks = [u for u in uuids if u.startswith(("dash2dock", "dash-to-dock"))]
    check("one dock", len(docks) == 1, " ".join(docks))
    enabled = gget("org.gnome.shell", "enabled-extensions")
    missing = [u for u in uuids if u not in enabled]
    check("extensions switched on", not missing, ", ".join(missing) or "all")
    check("Ubuntu Dock switched off", "ubuntu-dock@ubuntu.com" not in enabled or "ubuntu-dock" in gget("org.gnome.shell", "disabled-extensions"))
    check("GTK theme", gget("org.gnome.desktop.interface", "gtk-theme") == "'WhiteSur-Light-soft'", gget("org.gnome.desktop.interface", "gtk-theme"))
    for t in ("WhiteSur-Light", "WhiteSur-Dark", "WhiteSur-Light-soft"):
        check(f"theme {t}", os.path.isfile(os.path.join(HOME, ".themes", t, "index.theme")))
    shell_css = os.path.join(HOME, ".themes", "WhiteSur-Light", "gnome-shell", "gnome-shell.css")
    check("top-bar theme", os.path.isfile(shell_css))
    check("icons", os.path.isfile(os.path.join(HOME, ".local/share/icons/MacTahoe-light/index.theme")))
    check("window buttons on the left", gget("org.gnome.desktop.wm.preferences", "button-layout").startswith("'close,minimize,maximize:"))
    uri = gget("org.gnome.desktop.background", "picture-uri")
    dark = gget("org.gnome.desktop.background", "picture-uri-dark")
    check("day and night wallpaper", uri.endswith("-l.jpg'") and dark.endswith("-d.jpg'"), f"{uri} / {dark}")
    zshrc = open(os.path.join(HOME, ".zshrc")).read() if os.path.exists(os.path.join(HOME, ".zshrc")) else ""
    check("zsh prompt block", "# >>> macstyle terminal" in zshrc)
    for tool in ("zsh", "fastfetch", "lsd", "fzf", "zoxide"):
        found = run("bash", "-lc", f"command -v {tool} || ls ~/.local/bin/{tool} 2>/dev/null")
        check(f"terminal tool {tool}", bool(found), found)
    ptyxis = gget("org.gnome.Ptyxis", "default-profile-uuid") if run("bash", "-c", "command -v ptyxis") else ""
    gterm = os.path.exists(os.path.join(STATE, "gnome-terminal-profile"))
    check("terminal app styled", bool(ptyxis.strip("'")) or gterm, "Ptyxis" if ptyxis.strip("'") else "GNOME Terminal" if gterm else "none")
    if gterm:
        uuid = open(os.path.join(STATE, "gnome-terminal-profile")).read().strip()
        pal = run("dconf", "read", f"/org/gnome/terminal/legacy/profiles:/:{uuid}/palette")
        check("GNOME Terminal palette", pal.count("#") == 16, pal[:60])


def shell_state(uuid):
    """One extension's state, straight from GNOME Shell over D-Bus (the gnome-extensions tool is a
    separate package on Debian and Ubuntu). One extension per call, so the reply has one state and
    nothing in a description can confuse the parsing. 1 active, 2 inactive, 3 error, 4 out of date,
    6 initialized (loaded, not enabled in this session mode); None: GNOME Shell does not know it."""
    import re
    out = run("gdbus", "call", "--session", "--dest", "org.gnome.Shell.Extensions", "--object-path",
              "/org/gnome/Shell/Extensions", "--method", "org.gnome.Shell.Extensions.GetExtensionInfo", uuid)
    m = re.search(r"'state': <([0-9.]+)>", out)
    return int(float(m.group(1))) if m else None


NAMES = {1: "ACTIVE", 2: "INACTIVE", 3: "ERROR", 4: "OUT OF DATE", 6: "INITIALIZED"}


def extensions():
    enabled = [u for u in gget("org.gnome.shell", "enabled-extensions").strip("[]").replace("'", "").split(", ") if u]
    states = {u: shell_state(u) for u in enabled}
    running = [u for u in enabled if states[u] is not None]
    check("GNOME Shell sees the extensions", len(running) >= 8, f"{len(running)} of {len(enabled)} enabled")
    bad = []
    for u in enabled:
        state = states.get(u)
        if state == 1:
            continue
        # an extension made only for the lock screen waits, loaded, until the screen locks
        meta_path = os.path.join(EXT, u, "metadata.json")
        modes = json.load(open(meta_path)).get("session-modes", ["user"]) if os.path.exists(meta_path) else ["user"]
        if "user" not in modes and state == 6:
            continue
        if state is None and not os.path.exists(meta_path) and not os.path.exists(f"/usr/share/gnome-shell/extensions/{u}"):
            continue   # enabled in settings but not installed (switched on by the system, not by macstyle)
        bad.append(f"{u} ({NAMES.get(state, state)})")
    check("every extension loaded", running and not bad, ", ".join(bad) or f"all {len(running)} ACTIVE")


def flat(path):
    cp = configparser.RawConfigParser(strict=False)
    cp.optionxform = str
    cp.read_string(open(path).read())
    return {f"/{s}/{k}": v for s in cp.sections() for k, v in cp.items(s)}


def uninstalled(before_path):
    after_path = "/tmp/after.ini"
    with open(after_path, "w") as f:
        f.write(run("dconf", "dump", "/") + "\n")
    before, after = flat(before_path), flat(after_path)
    watched = ("/org/gnome/shell/", "/org/gnome/desktop/interface/", "/org/gnome/desktop/background/",
               "/org/gnome/desktop/wm/preferences/", "/org/gnome/Ptyxis/", "/org/gnome/terminal/")
    # keys GNOME Shell writes by itself when it runs (the test started it), not macstyle's
    shell_own = ("/org/gnome/desktop/interface/enable-animations", "/org/gnome/shell/welcome-dialog-last-shown-version")
    diff = []
    for k in sorted(set(before) | set(after)):
        if k in shell_own:
            continue
        if not k.startswith(watched) or "/extensions/" in k and k not in before:
            continue   # extension settings with nothing set before are reset, not deleted
        if before.get(k) != after.get(k):
            diff.append(f"{k}: {before.get(k)} -> {after.get(k)}")
    check("settings back as before", not diff, "; ".join(diff[:6]) or "identical")
    leftovers = [p for p in (os.path.join(HOME, ".themes/WhiteSur-Light-soft"), os.path.join(EXT, "unite@hardpixel.eu"),
                             os.path.join(HOME, ".local/share/backgrounds/macstyle")) if os.path.exists(p)]
    check("files removed", not leftovers, ", ".join(leftovers) or "none left")
    zshrc = os.path.join(HOME, ".zshrc")
    check("zsh block removed", not os.path.exists(zshrc) or "# >>> macstyle" not in open(zshrc).read())


if __name__ == "__main__":
    mode = sys.argv[1]
    {"installed": installed, "extensions": extensions, "uninstalled": lambda: uninstalled(sys.argv[2])}[mode]()
    sys.exit(failures)
