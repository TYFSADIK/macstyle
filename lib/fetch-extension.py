"""Download GNOME Shell extensions made for this exact GNOME version.

    fetch-extension.py GNOME_MAJOR DEST_DIR UUID [UUID...]

For each UUID: its GitHub releases first (for extensions whose newest versions are published only
there), then extensions.gnome.org. A download is used only if its metadata.json lists this GNOME
version: extensions.gnome.org answers with its nearest release even when that release does not
support the version asked for, and an extension made for another version can stop GNOME Shell
from starting. Each extension that fits is unpacked into DEST_DIR/UUID, its settings schema
compiled. Prints one line per UUID: "ok UUID VERSION SOURCE" or "none UUID REASON". Exit 0.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

EGO = "https://extensions.gnome.org"
UA = {"User-Agent": "macstyle-installer"}
# Extensions released on GitHub ahead of extensions.gnome.org: (repo, asset name pattern).
GITHUB = {
    "unite@hardpixel.eu": ("hardpixel/unite-shell", "unite-{tag}.zip"),
}


def get(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fits(data, major):
    """The metadata of a zip, if it declares this GNOME major version."""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            meta = json.loads(z.read("metadata.json"))
    except (KeyError, zipfile.BadZipFile, ValueError):
        return None
    versions = [str(v).split(".")[0] for v in meta.get("shell-version", [])]
    return meta if str(major) in versions else None


def from_github(uuid, major):
    repo, pattern = GITHUB[uuid]
    # The release list page, not the API: no token needed and no API rate limit.
    html = get(f"https://github.com/{repo}/releases").decode("utf-8", "replace")
    tags = []
    for part in html.split(f'href="/{repo}/releases/tag/')[1:]:
        tag = part.split('"', 1)[0]
        if tag not in tags:
            tags.append(tag)
    for tag in tags[:6]:
        try:
            data = get(f"https://github.com/{repo}/releases/download/{tag}/{pattern.format(tag=tag)}")
        except Exception:
            continue
        meta = fits(data, major)
        if meta:
            return data, meta, f"GitHub {tag}"
    return None


def from_ego(uuid, major):
    q = urllib.parse.urlencode({"uuid": uuid, "shell_version": str(major)})
    try:
        info = json.loads(get(f"{EGO}/extension-info/?{q}"))
    except Exception:
        return None
    if not info.get("download_url"):
        return None
    data = get(EGO + info["download_url"])
    meta = fits(data, major)
    return (data, meta, "extensions.gnome.org") if meta else None


def install(data, dest):
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(dest)
        # extractall drops the permission bits: put back the executable ones (Desktop Icons NG
        # starts app/ding.js as a program, and fails with "Permission denied" without them)
        for info in z.infolist():
            mode = (info.external_attr >> 16) & 0o777
            if mode and not info.is_dir():
                os.chmod(os.path.join(dest, info.filename), mode)
    schemas = os.path.join(dest, "schemas")
    if os.path.isdir(schemas):
        subprocess.run(["glib-compile-schemas", schemas], check=False, capture_output=True)


def main():
    major, dest_dir, uuids = sys.argv[1], sys.argv[2], sys.argv[3:]
    for uuid in uuids:
        found = None
        try:
            if uuid in GITHUB:
                found = from_github(uuid, major)
            if not found:
                found = from_ego(uuid, major)
        except Exception as e:  # the network, mostly: report and go on with the others
            print(f"none {uuid} download failed: {e}")
            continue
        if not found:
            print(f"none {uuid} no release for GNOME {major}")
            continue
        data, meta, source = found
        install(data, os.path.join(dest_dir, uuid))
        print(f"ok {uuid} {meta.get('version', '?')} {source}")


if __name__ == "__main__":
    main()
