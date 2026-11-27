"""Make Konsole colour schemes and profiles from the macstyle palette (terminal/macstyle.palette).

    palette-to-konsole.py PALETTE KONSOLE_DIR [--zsh]

Writes, in KONSOLE_DIR (~/.local/share/konsole):
  macstyle-light.colorscheme, macstyle-dark.colorscheme   the colours, see-through with blur
  macstyle-light.profile,     macstyle-dark.profile       the font, the colours, zsh with --zsh
Konsole has one colour scheme per profile, so macstyle-kde-darkswitch picks the profile that
matches the global theme (light or dark), also for windows already open.
"""
import configparser
import os
import sys

OPACITY = 0.88


def rgb(hexcolor):
    h = hexcolor.lstrip("#")
    return ",".join(str(int(h[i:i + 2], 16)) for i in (0, 2, 4))


def scheme(sec, title):
    out = [f"[General]\nDescription={title}\nOpacity={OPACITY}\nBlur=true\nWallpaper=\n"]
    fg, bg = sec["Foreground"], sec["Background"]
    for name, color in [("Foreground", fg), ("ForegroundIntense", fg), ("ForegroundFaint", fg),
                        ("Background", bg), ("BackgroundIntense", bg), ("BackgroundFaint", bg)]:
        out.append(f"[{name}]\nColor={rgb(color)}\n")
    for n in range(8):
        out.append(f"[Color{n}]\nColor={rgb(sec[f'Color{n}'])}\n")
        out.append(f"[Color{n}Intense]\nColor={rgb(sec[f'Color{n + 8}'])}\n")
        out.append(f"[Color{n}Faint]\nColor={rgb(sec[f'Color{n}'])}\n")
    return "\n".join(out)


def profile(mode, zsh):
    lines = ["[Appearance]", f"ColorScheme=macstyle-{mode}",
             "Font=JetBrainsMono Nerd Font,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1", "",
             "[General]", f"Name=macstyle {mode}", "Parent=FALLBACK/"]
    if zsh:
        lines.append("Command=zsh")
    lines += ["", "[Scrolling]", "ScrollBarPosition=2", ""]
    return "\n".join(lines)


def main():
    palette, dest = sys.argv[1], sys.argv[2]
    zsh = "--zsh" in sys.argv[3:]
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    cp.read(palette)
    os.makedirs(dest, exist_ok=True)
    for mode, section in (("light", "Light"), ("dark", "Dark")):
        with open(os.path.join(dest, f"macstyle-{mode}.colorscheme"), "w") as f:
            f.write(scheme(cp[section], f"macstyle {mode}"))
        with open(os.path.join(dest, f"macstyle-{mode}.profile"), "w") as f:
            f.write(profile(mode, zsh))


if __name__ == "__main__":
    main()
