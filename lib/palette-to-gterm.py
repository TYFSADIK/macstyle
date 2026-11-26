"""Give a GNOME Terminal profile the colours of a Ptyxis palette file, light or dark.

    palette-to-gterm.py PALETTE DCONF_PROFILE_PATH [--mode light|dark]

Without --mode, the mode follows GNOME's Dark Style (org.gnome.desktop.interface color-scheme).
GNOME Terminal has one set of colours per profile, so macstyle-darkswitch runs this again whenever
Dark Style changes.
"""
import configparser
import subprocess
import sys


def dconf_write(key, value):
    subprocess.run(["dconf", "write", key, value], check=True)


def main():
    palette, path = sys.argv[1], sys.argv[2].rstrip("/")
    mode = None
    if "--mode" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode") + 1]
    if mode is None:
        scheme = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"],
                                capture_output=True, text=True).stdout.strip()
        mode = "dark" if scheme == "'prefer-dark'" else "light"
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    cp.read(palette)
    sec = cp["Dark" if mode == "dark" else "Light"]
    colours = [sec[f"Color{i}"] for i in range(16)]
    dconf_write(f"{path}/use-theme-colors", "false")
    dconf_write(f"{path}/foreground-color", f"'{sec['Foreground']}'")
    dconf_write(f"{path}/background-color", f"'{sec['Background']}'")
    dconf_write(f"{path}/palette", "[" + ", ".join(f"'{c}'" for c in colours) + "]")
    dconf_write(f"{path}/cursor-colors-set", "true")
    dconf_write(f"{path}/cursor-background-color", f"'{sec['Cursor']}'")
    dconf_write(f"{path}/cursor-foreground-color", f"'{sec['Background']}'")
    dconf_write(f"{path}/bold-is-bright", "false")


if __name__ == "__main__":
    main()
