# Builds windows/icons/svg and windows/icons/ico from the MacTahoe icon theme and map.txt.
import os, sys, glob, subprocess, shutil
from PIL import Image
theme, out = sys.argv[1], sys.argv[2]
idx = {}
for root in ('src', 'links'):
    for p in glob.glob(f'{theme}/{root}/*/scalable/*.svg'):
        idx.setdefault((root, os.path.basename(p)[:-4]), p)
def resolve(name, depth=0):
    p = idx.get(('src', name)) or idx.get(('links', name))
    if not p: raise SystemExit(f'missing {name}')
    if os.path.islink(p):
        return resolve(os.readlink(p)[:-4], depth + 1)
    return p
# windows name -> MacTahoe name
icons = dict(line.split() for line in open(sys.argv[3]) if line.strip() and not line.startswith('#'))
os.makedirs(f'{out}/svg', exist_ok=True); os.makedirs(f'{out}/ico', exist_ok=True)
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
for win, mt in icons.items():
    src = resolve(mt)
    shutil.copyfile(src, f'{out}/svg/{win}.svg')
    png = f'/tmp/{win}.png'
    subprocess.run(['rsvg-convert', '-w', '256', '-h', '256', '-o', png, src], check=True)
    im = Image.open(png).convert('RGBA')
    im.save(f'{out}/ico/{win}.ico', sizes=[(s, s) for s in sizes])
    print(win, '<-', os.path.relpath(src, theme))
