#!/usr/bin/env python3
"""Refresh the Claude Skill's reference copies from the repository docs and build skill/gree-bridge.zip
(for the Claude app: Settings > Capabilities > Skills > Upload skill).  Run from anywhere:
    python3 skill/build_skill.py
The zip is reproducible (sorted entries, fixed dates), so it only changes when the content does."""
import os, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, ".claude", "skills", "gree-bridge")
COPIES = {                      # skill reference file <- repository file
    "SAFETY.md": "SAFETY.md",
    "install.md": "docs/install.md",
    "protocol.md": "docs/protocol.md",
    "adapting.md": "docs/adapting.md",
    "hardware.md": "docs/hardware.md",
    "firmware.md": "firmware/README.md",
}

def main():
    ref = os.path.join(SKILL, "references")
    os.makedirs(ref, exist_ok=True)
    for dst, src in COPIES.items():
        with open(os.path.join(ROOT, src), encoding="utf-8") as f:
            body = f.read()
        head = ("<!-- Copy of %s from the gree-bridge repository (github.com/reparationchlorinateur/gree-bridge), "
                "made by skill/build_skill.py. Links are relative to that file in the repository. -->\n\n" % src)
        with open(os.path.join(ref, dst), "w", encoding="utf-8") as f:
            f.write(head + body)
    # the two pictures the wiring steps refer to (the photo resized to keep the zip small)
    img = os.path.join(SKILL, "assets", "images")
    os.makedirs(img, exist_ok=True)
    import shutil
    shutil.copyfile(os.path.join(ROOT, "docs", "images", "j1_wiring.png"), os.path.join(img, "j1_wiring.png"))
    try:
        from PIL import Image
        im = Image.open(os.path.join(ROOT, "docs", "images", "gree_board_taps.jpg"))
        im.thumbnail((1400, 1400))
        im.save(os.path.join(img, "gree_board_taps.jpg"), quality=80, optimize=True)
    except ImportError:
        shutil.copyfile(os.path.join(ROOT, "docs", "images", "gree_board_taps.jpg"), os.path.join(img, "gree_board_taps.jpg"))
    out = os.path.join(ROOT, "skill", "gree-bridge.zip")
    files = []
    for d, _, names in os.walk(SKILL):
        for n in names:
            if n.endswith((".pyc", ".DS_Store")) or "__pycache__" in d:
                continue
            files.append(os.path.join(d, n))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(files):
            arc = os.path.join("gree-bridge", os.path.relpath(p, SKILL))
            info = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if p.endswith(".py") else 0o644) << 16
            with open(p, "rb") as f:
                z.writestr(info, f.read())
    print("references refreshed, %s: %d files" % (os.path.relpath(out, ROOT), len(files)))

if __name__ == "__main__":
    main()
