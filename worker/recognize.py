#!/usr/bin/env python3
"""Offline replay-row recognition; input is an app-owned PNG and Vision OCR JSON."""
from __future__ import annotations

import argparse
import json
import re
import sys
from itertools import combinations
from pathlib import Path

import cv2
import numpy as np

# Tiny descriptor batches are slower when each OpenCV call starts many threads.
cv2.setNumThreads(1)


def card_features(assets: Path, extra_assets: Path | None = None):
    names = json.loads((assets / "names.json").read_text(encoding="utf-8"))
    paths = {stem: assets / "portraits" / f"{stem}.png" for stem in names}
    if extra_assets and (extra_assets / "names.json").exists():
        extra_names = json.loads((extra_assets / "names.json").read_text(encoding="utf-8"))
        for stem, name in extra_names.items():
            if re.fullmatch(r"UI_Gcg_CardFace_Char_[A-Za-z0-9_]+", stem) and (extra_assets / "portraits" / f"{stem}.png").is_file():
                names[stem] = name
                paths[stem] = extra_assets / "portraits" / f"{stem}.png"
    sift = cv2.SIFT_create(nfeatures=1000, contrastThreshold=0.025)
    entries = []
    for stem, name in sorted(names.items()):
        image = cv2.imread(str(paths[stem]))
        if image is None:
            continue
        h, w = image.shape[:2]
        mask = np.zeros((h, w), np.uint8)
        mask[round(h * .025):round(h * .97), round(w * .06):round(w * .94)] = 255
        keypoints, descriptors = sift.detectAndCompute(image, mask)
        if descriptors is not None:
            entries.append((name, np.float32([k.pt for k in keypoints]), descriptors, image))
    return sift, entries


def identify(image, circle, sift, entries, diagnostics=None):
    x, y, r = (int(v) for v in circle)
    h, w = image.shape[:2]
    if r <= 0 or x - r < 0 or y - r < 0 or x + r > w or y + r > h:
        return "未识别"
    crop = image[y-r:y+r, x-r:x+r]
    # Small screen portraits lose SIFT extrema at their native size. Normalize
    # before extraction; resizing adds no evidence, so still verify the pixels.
    candidates = {}
    for size in dict.fromkeys((160, 224, crop.shape[0])):
        normalized = crop if size == crop.shape[0] else cv2.resize(crop, (size, size), interpolation=(
            cv2.INTER_CUBIC if crop.shape[0] < size else cv2.INTER_AREA))
        candidates = portrait_candidates(normalized, sift, entries, diagnostics)
        # Retry missing evidence, never resolve an ambiguous match by choosing
        # whichever resize happens to favor one of the competing characters.
        if candidates:
            break
    ranked = sorted(candidates.items(), key=lambda item: -item[1])
    if not ranked or (len(ranked) > 1 and ranked[0][1] < ranked[1][1] + 3):
        return "未识别"
    return ranked[0][0]


def pixel_correlation(crop, mask, reference, affine):
    size = (crop.shape[1], crop.shape[0])
    warped = cv2.warpAffine(reference, affine, size, flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP)
    valid = cv2.warpAffine(np.full(reference.shape[:2], 255, np.uint8), affine, size,
                          flags=cv2.INTER_NEAREST | cv2.WARP_INVERSE_MAP) > 0
    valid &= mask > 0
    if valid.sum() < np.count_nonzero(mask) * .8:
        return 0.0
    a = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)[valid].astype(np.float32)
    b = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY)[valid].astype(np.float32)
    return float(np.corrcoef(a, b)[0, 1]) if a.size and min(a.std(), b.std()) > 1 else 0.0


def portrait_candidates(crop, sift, entries, diagnostics=None):
    r = crop.shape[0] // 2
    mask = np.zeros(crop.shape[:2], np.uint8)
    cv2.circle(mask, (r, r), round(r * .84), 255, -1)
    keys, descriptors = sift.detectAndCompute(crop, mask)
    if descriptors is None or len(keys) < 5:
        return {}
    matcher = cv2.BFMatcher()
    candidates = {}
    for entry in entries:
        name, reference_points, reference_descriptors = entry[:3]
        pairs = matcher.knnMatch(descriptors, reference_descriptors, k=2)
        good = [pair[0] for pair in pairs if len(pair) == 2 and pair[0].distance < .74 * pair[1].distance]
        # Each feature on the source card must correspond to a different image feature.
        unique = {}
        for match in sorted(good, key=lambda m: m.distance):
            unique.setdefault(match.trainIdx, match)
        good = list(unique.values())
        if len(good) < 5:
            continue
        src = np.float32([keys[m.queryIdx].pt for m in good])
        dst = np.float32([reference_points[m.trainIdx] for m in good])
        affine, inliers = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=3.0)
        if affine is None or inliers is None:
            continue
        selected = inliers.ravel().astype(bool)
        count = int(selected.sum())
        coverage = np.ptp(src[selected], axis=0) if count else np.zeros(2)
        scale = np.hypot(affine[0, 0], affine[0, 1])
        rotation = abs(np.arctan2(affine[1, 0], affine[0, 0]))
        if diagnostics is not None:
            diagnostics.append({"name": name, "matches": len(good), "inliers": count,
                                "coverage": float(min(coverage) / r), "scale": float(scale), "rotation": float(rotation),
                                "crop_size": crop.shape[0]})
        if count < 5 or min(coverage) < r * .2 or not .08 < scale < 10 or rotation >= .2:
            continue
        correlation = None
        if len(entry) > 3:
            correlation = pixel_correlation(crop, mask, entry[3], affine)
            if diagnostics is not None:
                diagnostics[-1]["pixel_correlation"] = correlation
            if correlation < .65:
                continue
        strong_consensus = False
        # Repeated textures can produce many outliers despite a strong correct
        # transform. Accept that case only with independent pixel agreement.
        if correlation is not None and count >= 12 and count / len(good) >= .35 and min(coverage) >= r * .45:
            strong_consensus = True
        if count / len(good) >= .65 or strong_consensus:
            candidates[name] = max(count, candidates.get(name, 0))
    return candidates


def date_value(text):
    text = re.sub(r"\s+", "", text)
    match = re.search(r"(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})[:：](\d{2})", text)
    if not match:
        return None
    y, m, d, hh, mm = map(int, match.groups())
    if not (2000 <= y <= 2100 and 1 <= m <= 12 and 1 <= d <= 31 and 0 <= hh <= 23 and 0 <= mm <= 59):
        return None
    return f"{y:04d}-{m:02d}-{d:02d}_{hh:02d}{mm:02d}"


def portrait_triplet(circles):
    ranked = []
    for triple in combinations(sorted(circles, key=lambda c: c[0]), 3):
        a, b, c = np.asarray(triple)
        gaps = (b[0] - a[0], c[0] - b[0])
        radius = np.mean([p[2] for p in triple])
        if min(gaps) < radius * 1.8 or max(gaps) > radius * 3.0:
            continue
        if max(gaps) / min(gaps) > 1.18:
            continue
        score = abs(gaps[0] - gaps[1]) + np.std([p[1] for p in triple]) * 2 + np.std([p[2] for p in triple])
        ranked.append((score, triple))
    return list(min(ranked, key=lambda item: item[0])[1]) if ranked else []


def is_play_button(image, circle):
    x, y, r = map(int, circle)
    inner = max(4, round(r * .55))
    patch = image[max(0, y-inner):y+inner, max(0, x-inner):x+inner]
    if patch.shape[:2] != (inner * 2, inner * 2):
        return False
    dark = (cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY) < 130).astype(np.uint8) * 255
    contours, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for contour in contours:
        if not .12 * patch.shape[0] ** 2 < cv2.contourArea(contour) < .75 * patch.shape[0] ** 2:
            continue
        shape = cv2.approxPolyDP(contour, .055 * cv2.arcLength(contour, True), True).reshape(-1, 2)
        if len(shape) != 3:
            continue
        tip = shape[np.argmax(shape[:, 0])]
        base = shape[np.argsort(shape[:, 0])[:2]]
        if abs(int(base[0, 0]) - int(base[1, 0])) < inner * .4 and abs(float(tip[1]) - np.mean(base[:, 1])) < inner * .35:
            return True
    return False


def recognize(image, lines, assets, extra_assets=None):
    h, w = image.shape[:2]
    dates = sorted([(line, date_value(line["text"])) for line in lines if date_value(line["text"])], key=lambda item: item[0]["y"])
    if not dates:
        return []
    # Row geometry is inferred from OCR date baselines, not a screen-resolution profile.
    spacing = float(np.median(np.diff([line["y"] for line, _ in dates]))) if len(dates) > 1 else .18
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    radius = spacing * h * .27
    circles = cv2.HoughCircles(gray, cv2.HOUGH_GRADIENT, dp=1.2, minDist=radius * 1.6,
                              param1=110, param2=26, minRadius=max(8, round(radius * .75)), maxRadius=round(radius * 1.2))
    circles = [] if circles is None else circles[0].tolist()
    try:
        sift, entries = card_features(assets, extra_assets)
    except (OSError, ValueError, cv2.error):
        sift, entries = None, []
    rows = []
    modes = ("热斗模式", "匹配模式", "胜冠之试", "酒馆挑战", "好友对局")
    for index, (date_line, date) in enumerate(dates, 1):
        date_y = date_line["y"]
        center_x = date_line["x"] + date_line["width"] / 2
        portrait_y = date_y - spacing * .37
        candidates = [c for c in circles if abs(c[1] / h - portrait_y) < spacing * .20]
        left = portrait_triplet([c for c in candidates if c[0] / w < center_x - .07])
        right = portrait_triplet([c for c in candidates if center_x + .07 < c[0] / w < .79])
        left_names = [identify(image, c, sift, entries) for c in left] if len(left) == 3 and entries else ["未识别"] * 3
        right_names = [identify(image, c, sift, entries) for c in right] if len(right) == 3 and entries else ["未识别"] * 3
        buttons = [c for c in candidates if c[0] / w > .8 and is_play_button(image, c)]
        play = buttons[0] if len(buttons) == 1 else None
        mode = next((mode for line in lines for mode in modes if mode in line["text"] and
                     date_y - spacing * .6 < line["y"] < date_y and abs(line["x"] - date_line["x"]) < .12), "未知模式")
        rows.append({"id": index, "selected": True, "date": date, "mode": mode,
                     "left": left_names, "right": right_names,
                     "play": {"x": play[0] / w if play else .94,
                              "y": play[1] / h if play else max(0, portrait_y + spacing * .08)},
                     "playDetected": play is not None})
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path)
    parser.add_argument("--ocr", type=Path)
    parser.add_argument("--assets", required=True, type=Path)
    parser.add_argument("--extra-assets", type=Path)
    parser.add_argument("--update-assets", action="store_true")
    parser.add_argument("--controls", action="store_true")
    parser.add_argument("--playback-controls", action="store_true")
    parser.add_argument("--review-video", type=Path)
    parser.add_argument("--review-metadata", type=Path)
    parser.add_argument("--review-output", type=Path)
    args = parser.parse_args()
    if args.review_video:
        from video_review import review_video
        if not args.review_output:
            parser.error("--review-video requires --review-output")
        print(json.dumps(review_video(args.review_video, args.review_metadata, args.review_output,
                                      args.assets, args.extra_assets), ensure_ascii=False))
        return
    if args.update_assets:
        from update_assets import update_assets
        if not args.extra_assets:
            parser.error("--update-assets requires --extra-assets")
        print(json.dumps(update_assets(args.assets, args.extra_assets), ensure_ascii=False))
        return
    if not args.image:
        parser.error("--image is required for recognition")
    image = cv2.imread(str(args.image))
    if image is None:
        raise ValueError("Screenshot cannot be decoded")
    if args.controls:
        from replay_controls import speed_control
        print(json.dumps(speed_control(image)))
        return
    if args.playback_controls:
        from replay_controls import playback_controls
        reference = cv2.imread(str(args.assets / "controls" / "replay-gear.png"))
        print(json.dumps(playback_controls(image, reference)))
        return
    if not args.ocr:
        parser.error("--ocr is required for favorites recognition")
    lines = json.loads(args.ocr.read_text(encoding="utf-8"))
    # A bounded working size keeps 4K/Retina screenshots inexpensive.
    scale = min(1, 2400 / image.shape[1])
    if scale < 1:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    print(json.dumps(recognize(image, lines, args.assets, args.extra_assets), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Portrait recognition failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
