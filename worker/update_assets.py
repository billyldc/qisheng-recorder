"""Explicit, append-only reference updates. Never uploads screenshots or account data."""
from __future__ import annotations

import json
import hashlib
import re
import struct
import ssl
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

import cv2
import numpy as np
import certifi

CATALOG = "https://gi.yatta.moe/api/v2/chs/gcg"
IMAGE_BASE = "https://gi.yatta.moe/assets/UI/gcg/"


def download(url, limit):
    request = Request(url, headers={"User-Agent": "QishengRecorder/1.1 (local character references)"})
    with urlopen(request, timeout=20, context=ssl.create_default_context(cafile=certifi.where())) as response:
        if not response.geturl().startswith("https://gi.yatta.moe/"):
            raise ValueError("Unexpected reference host")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Reference response exceeds size limit")
    return data


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def valid_image(path):
    image = cv2.imread(str(path)) if path.is_file() else None
    return image is not None and 64 <= min(image.shape[:2]) and max(image.shape[:2]) <= 4096


def asset_inventory(bundled, extra):
    available = {}
    for root in (bundled, extra):
        if root is None or not (root / "names.json").exists():
            continue
        names = json.loads((root / "names.json").read_text(encoding="utf-8"))
        for stem, name in names.items():
            if re.fullmatch(r"UI_Gcg_CardFace_Char_[A-Za-z0-9_]+", stem) and valid_image(root / "portraits" / (stem + ".png")):
                available[stem] = name
    return available


def library_version(bundled, extra, available):
    digest = hashlib.sha256()
    for stem, name in sorted(available.items()):
        path = extra / 'portraits' / (stem + '.png')
        if not valid_image(path):
            path = bundled / 'portraits' / (stem + '.png')
        digest.update(json.dumps([stem, name]).encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()[:12]


def catalog_names(data):
    items = data["data"]["items"]
    if not isinstance(items, dict) or len(items) > 10000:
        raise ValueError("Invalid reference catalog")
    result = {}
    for entry in items.values():
        if not isinstance(entry, dict) or entry.get("type") != "characterCard":
            continue
        stem, name = entry.get("icon", ""), entry.get("name", "")
        if isinstance(stem, str) and re.fullmatch(r"UI_Gcg_CardFace_Char_[A-Za-z0-9_]+", stem) and isinstance(name, str) and 0 < len(name) <= 80 and all(ord(c) >= 32 for c in name):
            result[stem] = name
    if not result:
        raise ValueError("No character references in catalog")
    return result


def update_assets(bundled: Path, extra: Path, fetch=download):
    bundled_names = json.loads((bundled / "names.json").read_text(encoding="utf-8"))
    extra.mkdir(parents=True, exist_ok=True)
    (extra / "portraits").mkdir(exist_ok=True)
    names_path = extra / "names.json"
    names = json.loads(names_path.read_text(encoding="utf-8")) if names_path.exists() else {}
    report_path = extra / "update.json"
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    checked = datetime.now(timezone.utc).isoformat()
    try:
        catalog = catalog_names(json.loads(fetch(CATALOG, 4_000_000)))
    except (OSError, ValueError, KeyError, TypeError):
        report = dict(previous, checkedAt=checked, error="目录下载失败，保留旧库")
        report.setdefault("total", len(asset_inventory(bundled, extra)))
        report.update(added=[], failed=previous.get("failed", []))
        atomic_json(report_path, report)
        return report
    available = asset_inventory(bundled, extra)
    added, failed = [], []
    for stem, name in catalog.items():
        if stem in available:
            continue
        try:
            data = fetch(IMAGE_BASE + stem + ".png", 6_000_000)
            if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                raise ValueError("Expected a PNG portrait")
            width, height = struct.unpack(">II", data[16:24])
            if min(width, height) < 64 or max(width, height) > 4096:
                raise ValueError("Portrait dimensions exceed limits")
            image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_UNCHANGED)
            if image is None or min(image.shape[:2]) < 64 or max(image.shape[:2]) > 4096:
                raise ValueError("Invalid portrait image")
            scale = min(1, 640 / image.shape[0])
            image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            target = extra / "portraits" / (stem + ".png")
            temporary = target.with_suffix(".pending.png")
            if not cv2.imwrite(str(temporary), image) or not valid_image(temporary):
                raise OSError("Cannot save portrait")
            temporary.replace(target)
            names[stem] = name
            atomic_json(names_path, names)
            added.append(name)
        except (OSError, ValueError, cv2.error):
            failed.append(name)
    available = asset_inventory(bundled, extra)
    missing = [name for stem, name in catalog.items() if stem not in available]
    version = hashlib.sha256(json.dumps(catalog, sort_keys=True).encode()).hexdigest()[:12]
    report = {"source": CATALOG, "checkedAt": checked, "catalogVersion": version,
              "libraryVersion": library_version(bundled, extra, available),
              "lastSuccessAt": checked if not missing else previous.get("lastSuccessAt"),
              "total": len(available), "catalogTotal": len(catalog), "missing": missing,
              "added": added, "failed": failed, "error": None}
    atomic_json(extra / "update.json", report)
    return report
