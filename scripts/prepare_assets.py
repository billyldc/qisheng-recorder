#!/usr/bin/env python3
"""Prepare attributed, bounded-size GCG references from the public asset archives."""
import argparse
import io
import json
from pathlib import Path
import urllib.request
import zipfile

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
ARCHIVES = {
    "avatars": "https://www.spriters-resource.com/media/assets/576/599016.zip",
    "monsters": "https://www.spriters-resource.com/media/assets/576/598986.zip",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-archives", type=Path)
    parser.add_argument("--local-names", type=Path)
    args = parser.parse_args()
    output = ROOT / "Assets"
    (output / "portraits").mkdir(parents=True, exist_ok=True)
    if args.local_names:
        names = json.loads(args.local_names.read_text(encoding="utf-8"))
    else:
        with urllib.request.urlopen("https://gi.yatta.moe/api/v2/chs/gcg", timeout=30) as response:
            data = json.load(response)
        names = {v["icon"]: v["name"] for v in data["data"]["items"].values() if v.get("icon", "").startswith("UI_Gcg_CardFace_Char_")}
    for kind, url in ARCHIVES.items():
        if args.local_archives:
            filename = "genshin-tcg-character-portraits.zip" if kind == "avatars" else "genshin-tcg-monster-portraits.zip"
            archive = zipfile.ZipFile(args.local_archives / filename)
        else:
            request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(request, timeout=90) as response:
                archive = zipfile.ZipFile(io.BytesIO(response.read()))
        best = {}
        with archive:
            for entry in archive.infolist():
                stem = Path(entry.filename).stem.removesuffix(" (1)")
                if stem not in names:
                    continue
                image = cv2.imdecode(np.frombuffer(archive.read(entry), np.uint8), cv2.IMREAD_UNCHANGED)
                if image is not None and (stem not in best or image.size > best[stem].size):
                    best[stem] = image
            for stem, image in best.items():
                scale = min(1, 640 / image.shape[0])
                image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
                cv2.imwrite(str(output / "portraits" / f"{stem}.png"), image)
    included = {stem: name for stem, name in names.items() if (output / "portraits" / f"{stem}.png").exists()}
    (output / "names.json").write_text(json.dumps(included, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(included)} character references")


if __name__ == "__main__":
    main()
