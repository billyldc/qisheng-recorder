"""Offline, bounded multi-frame review. Never edits or uploads a source recording."""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np

from recognize import card_features
from update_assets import atomic_json

UNKNOWN = "未识别"


def local_pixel_agreement(warped, reference, points, scale):
    """Verify separated image patches when an animated card is not globally rigid."""
    h, w = reference.shape[:2]
    radius = max(8, round(w*.06))
    scores, cells = [], set()
    for px, py in points:
        x,y = round(float(px)), round(float(py))
        cell = (int(x/(w*.15)), int(y/(h*.15)))
        if cell in cells or not (radius <= x < w-radius and radius <= y < h-radius):
            continue
        cells.add(cell)
        a = warped[y-radius:y+radius, x-radius:x+radius]
        b = reference[y-radius:y+radius, x-radius:x+radius]
        size = max(6, round(radius*2*scale))
        a = cv2.cvtColor(cv2.resize(a, (size,size), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        b = cv2.cvtColor(cv2.resize(b, (size,size), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        if min(a.std(), b.std()) > 6:
            scores.append(float(np.corrcoef(a.ravel(),b.ravel())[0,1]))
    return len(scores) >= 5 and np.median(scores) >= .82 and sum(s >= .7 for s in scores)/len(scores) >= .75


class BoardMatcher:
    def __init__(self, assets, extra=None):
        _, self.entries = card_features(assets, extra)
        self.sift = cv2.SIFT_create(nfeatures=6000, contrastThreshold=.025)
        self.matcher = cv2.FlannBasedMatcher(dict(algorithm=1, trees=4), dict(checks=64))
        if self.entries:
            self.matcher.add([entry[2] for entry in self.entries])
            self.matcher.train()

    def cards(self, image, diagnostics=None):
        keys, descriptors = self.sift.detectAndCompute(image, None)
        if descriptors is None or not self.entries:
            return []
        groups = defaultdict(list)
        for pair in self.matcher.knnMatch(descriptors, k=2):
            if len(pair) == 2 and pair[0].distance < .7 * pair[1].distance:
                groups[pair[0].imgIdx].append(pair[0])
        result = []
        ih, iw = image.shape[:2]
        for entry_index, matches in groups.items():
            name, points, _, art = self.entries[entry_index]
            # The global index rejects features shared with other cards. For a
            # plausible but sparse candidate, verify against its own texture;
            # geometry and pixel checks below still decide acceptance.
            if 6 <= len(matches) < 35:
                pairs = cv2.BFMatcher().knnMatch(descriptors, self.entries[entry_index][2], k=2)
                matches = [p[0] for p in pairs if len(p) == 2 and p[0].distance < .7*p[1].distance]
            if diagnostics is not None and len(matches) >= 6:
                diagnostics.append(dict(name=name, matches=len(matches)))
            ah, aw = art.shape[:2]
            # Same character can appear on both teams; fit separate instances.
            for _ in range(2):
                if len(matches) < 10:
                    break
                source = np.float32([points[m.trainIdx] for m in matches])
                dest = np.float32([keys[m.queryIdx].pt for m in matches])
                transform, inliers = cv2.estimateAffine2D(source, dest, method=cv2.RANSAC,
                                                        ransacReprojThreshold=2.5)
                if transform is None or inliers is None:
                    break
                selected = inliers.ravel().astype(bool)
                matches = [m for m, keep in zip(matches, selected) if not keep]
                if selected.sum() < 10:
                    continue
                extent = np.ptp(source[selected], axis=0) / [aw, ah]
                sx, sy = transform[0, 0], transform[1, 1]
                if diagnostics is not None:
                    diagnostics.append(dict(name=name, extent=extent.tolist(), sx=float(sx), sy=float(sy)))
                if min(extent) < .3 or sx <= 0 or sy <= 0 or not .8 < sx / sy < 1.25:
                    continue
                if abs(transform[0, 1]) > sx * .15 or abs(transform[1, 0]) > sy * .15:
                    continue
                corners = cv2.transform(np.float32([[[0, 0], [aw, ah]]]), transform)[0]
                x1, y1 = corners[0]; x2, y2 = corners[1]
                if not (0 <= x1 < x2 <= iw and 0 <= y1 < y2 <= ih and .13 < (y2-y1)/ih < .34):
                    continue
                warped = cv2.warpAffine(image, transform, (aw, ah), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP)
                a = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY)[int(ah*.18):int(ah*.88), int(aw*.14):int(aw*.86)]
                b = cv2.cvtColor(art, cv2.COLOR_BGR2GRAY)[int(ah*.18):int(ah*.88), int(aw*.14):int(aw*.86)]
                # Compare at the observed card resolution, not upsampled video
                # pixels against the full-resolution reference texture.
                size = (max(16, round(a.shape[1]*sx)), max(24, round(a.shape[0]*sy)))
                a = cv2.GaussianBlur(cv2.resize(a, size, interpolation=cv2.INTER_AREA), (3, 3), .8)
                b = cv2.GaussianBlur(cv2.resize(b, size, interpolation=cv2.INTER_AREA), (3, 3), .8)
                if a.mean() < b.mean()*.65:
                    continue
                correlation = float(np.corrcoef(a.ravel(), b.ravel())[0, 1]) if min(a.std(), b.std()) > 3 else 0
                if diagnostics is not None:
                    diagnostics.append(dict(name=name, inliers=int(selected.sum()), correlation=correlation))
                local = (selected.sum() >= 14 and correlation >= .45 and
                         local_pixel_agreement(warped, art, source[selected], min(sx,sy)))
                if correlation < .72 and not (selected.sum() >= 20 and correlation >= .68) and not local:
                    continue
                result.append(dict(name=name, box=[float(x1), float(y1), float(x2), float(y2)],
                                   score=round(correlation, 4)))
        return result


def board_slots(cards, shape):
    """Require a coherent two-row board; infer missing slots only from its grid."""
    h, w = shape[:2]
    cards = [c for c in cards if .23*w < (c['box'][0]+c['box'][2])/2 < .77*w]
    if len(cards) < 4:
        return None
    widths = [c['box'][2]-c['box'][0] for c in cards]
    cw = float(np.median(widths))
    ch = float(np.median([c['box'][3]-c['box'][1] for c in cards]))
    if any(abs(v-cw) > cw*.18 for v in widths):
        return None
    ys = sorted((c['box'][1]+c['box'][3])/2 for c in cards)
    gaps = np.diff(ys)
    split = int(np.argmax(gaps))
    if gaps[split] < ch*.75:
        return None
    mid = (ys[split]+ys[split+1])/2
    rows = [[c for c in cards if ((c['box'][1]+c['box'][3])/2 < mid) == top] for top in (True, False)]
    if any(len(row) < 2 for row in rows):
        return None
    xs = sorted((c['box'][0]+c['box'][2])/2 for c in cards)
    clusters = []
    for x in xs:
        if not clusters or x - np.mean(clusters[-1]) > cw*.55:
            clusters.append([x])
        else:
            clusters[-1].append(x)
    if len(clusters) != 3:
        return None
    centers = [float(np.mean(c)) for c in clusters]
    dx = np.diff(centers)
    if not .9*cw < min(dx) < max(dx)+.01 < 1.65*cw or max(dx)/min(dx) > 1.2:
        return None
    slots = []
    for row in rows:
        cy = float(np.median([(c['box'][1]+c['box'][3])/2 for c in row]))
        if any(abs((c['box'][1]+c['box'][3])/2-cy) > ch*.3 for c in row):
            return None
        for cx in centers:
            candidates = [c for c in row if abs((c['box'][0]+c['box'][2])/2-cx) < cw*.35]
            names = {c['name'] for c in candidates}
            if len(names) == 1:
                slot = max(candidates, key=lambda c: c['score']).copy()
            else:
                slot = dict(name=UNKNOWN, score=0, box=[cx-cw/2, cy-ch/2, cx+cw/2, cy+ch/2])
            if not (0 <= slot['box'][0] < slot['box'][2] <= w and 0 <= slot['box'][1] < slot['box'][3] <= h):
                return None
            slots.append(slot)
    return slots


def stable_patch(a, b):
    if a.size == 0 or a.shape != b.shape:
        return False
    gray = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    other = cv2.cvtColor(b, cv2.COLOR_BGR2GRAY)
    correlation = float(np.corrcoef(gray.ravel(), other.ravel())[0,1]) if min(gray.std(), other.std()) > 3 else 0
    return (gray.mean() > 35 and gray.std() > 18 and cv2.Laplacian(gray, cv2.CV_32F).var() > 25
            and np.mean(np.abs(a.astype(np.float32)-b)) < 32 and correlation > .72)


def menu_visible(image):
    h, w = image.shape[:2]
    patch = cv2.cvtColor(image[:round(h*.35), round(w*.65):], cv2.COLOR_BGR2GRAY)
    mask = (patch > 175).astype(np.uint8)*255
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    bars = []
    for contour in contours:
        x,y,bw,bh = cv2.boundingRect(contour)
        if .12*w < bw < .3*w and .018*h < bh < .065*h and cv2.contourArea(contour) > bw*bh*.65:
            bars.append((x,y,bw,bh))
    return len(bars) >= 2


def perspective(names, initial, override="auto"):
    if override in ("top", "bottom"):
        return override
    own = {n for n in initial.get('left', []) if n and n != UNKNOWN}
    opponent = {n for n in initial.get('right', []) if n and n != UNKNOWN}
    # Shared characters cannot anchor perspective (especially mirror matches).
    own, opponent = own-opponent, opponent-own
    top, bottom = set(names[:3]), set(names[3:])
    top_score = len(top & own) + len(bottom & opponent)
    bottom_score = len(bottom & own) + len(top & opponent)
    if top_score >= 2 and bottom_score == 0:
        return 'top'
    if bottom_score >= 2 and top_score == 0:
        return 'bottom'
    return 'unknown'


def merge(initial, frames, previous=None):
    previous = previous or {}
    prior_slots = previous.get('slots', [])
    original = (initial.get('left', [UNKNOWN]*3) + initial.get('right', [UNKNOWN]*3))
    original = (original + [UNKNOWN]*6)[:6]
    locks = initial.get('manualCharacters') or [False]*6
    slots = []
    for index in range(6):
        votes = defaultdict(list)
        for frame in frames:
            view = frame['perspective']
            if view == 'unknown':
                continue
            physical = index if view == 'top' else (index+3) % 6
            item = frame['cards'][physical]
            if item['name'] != UNKNOWN:
                votes[item['name']].append(dict(time=frame['time'], crop=item['crop']))
        candidates = [dict(name=name, count=len(evidence), evidence=evidence) for name, evidence in sorted(votes.items())]
        old = prior_slots[index] if index < len(prior_slots) else {}
        manual = old.get('manual', False) or (index < len(locks) and locks[index])
        value = old.get('value', original[index]) if old.get('manual') else original[index]
        confirmed = [name for name, evidence in votes.items() if len(evidence) >= 3
                     and max(v['time'] for v in evidence)-min(v['time'] for v in evidence) >= 6]
        state = 'manual' if manual else 'unconfirmed'
        if not manual and len(confirmed) == 1 and len(votes) == 1:
            if original[index] in ('', UNKNOWN, confirmed[0]):
                value, state = confirmed[0], 'confirmed'
            else:
                state = 'conflict'
        elif not manual and len(votes) > 1:
            state = 'conflict'
        slots.append(dict(value=value, initial=original[index], manual=bool(manual), state=state, candidates=candidates))
    return slots


def resolve_perspectives(frames, initial, override):
    if override != 'auto':
        return
    # A directly anchored frame may reveal an initially unknown teammate.
    # Extend anchors only with names independently present in >=3 samples;
    # never use filenames or silently assume that the bottom team is ours.
    frequencies = Counter(name for f in frames for name in {card['name'] for card in f['cards']} if name != UNKNOWN)
    anchors = {'left': set(), 'right': set()}
    for f in frames:
        if f['perspective'] == 'unknown':
            continue
        own = f['cards'][:3] if f['perspective'] == 'top' else f['cards'][3:]
        other = f['cards'][3:] if f['perspective'] == 'top' else f['cards'][:3]
        for side, cards in (('left', own), ('right', other)):
            anchors[side].update(c['name'] for c in cards if frequencies[c['name']] >= 3)
    if not any(anchors.values()):
        return
    for f in frames:
        if f['perspective'] == 'unknown':
            f['perspective'] = perspective([c['name'] for c in f['cards']], anchors)


def review_video(video, metadata, output, assets, extra=None):
    video, output = Path(video), Path(output)
    initial = json.loads(metadata.read_text()) if metadata and metadata.exists() else {}
    report_path = output / 'review.json'
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    before = video.stat()
    fingerprint = hashlib.sha256()
    with video.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4*1024*1024), b''):
            fingerprint.update(chunk)
    digest = fingerprint.hexdigest()
    if previous.get('videoSHA256') not in (None, digest):
        raise ValueError('Video changed; preserve the old review and use a new evidence folder')
    capture = cv2.VideoCapture(str(video))
    try:
        fps = capture.get(cv2.CAP_PROP_FPS)
        duration = capture.get(cv2.CAP_PROP_FRAME_COUNT) / fps if fps > 0 else 0
        if not 1 < duration < 86400:
            raise ValueError('Cannot read video duration')
        matcher = BoardMatcher(assets, extra)
        frames = []
        thumbnails = []
        output.mkdir(parents=True, exist_ok=True)
        # Sweep many points throughout the opening and the rest of the replay.
        # Nearby pairs reject animation; accepted samples remain >=3s apart.
        times = sorted(set(np.arange(3, min(duration-1, 120), 3).tolist() +
                           np.linspace(min(120, duration*.5), duration-1, 24).tolist()))
        last = -10
        for time in times:
            if time-last < 3 or len(frames) >= 30:
                continue
            pair = []
            for t in (time, time+.4):
                capture.set(cv2.CAP_PROP_POS_MSEC, t*1000)
                ok, image = capture.read()
                if not ok:
                    break
                if image.shape[1] > 1440:
                    image = cv2.resize(image, (1440, round(image.shape[0]*1440/image.shape[1])))
                pair.append(image)
            if len(pair) != 2 or pair[0].shape != pair[1].shape:
                continue
            if menu_visible(pair[0]) or menu_visible(pair[1]):
                continue
            cards = board_slots(matcher.cards(pair[0]), pair[0].shape)
            if cards is None:
                continue
            boxes = [list(map(round, c['box'])) for c in cards]
            if not all(stable_patch(pair[0][y1:y2, x1:x2], pair[1][y1:y2, x1:x2]) for x1,y1,x2,y2 in boxes):
                continue
            thumb = np.concatenate([cv2.resize(pair[0][y1:y2,x1:x2], (16,24), interpolation=cv2.INTER_AREA)
                                    for x1,y1,x2,y2 in boxes]).astype(np.float32)
            if any(np.mean(np.abs(thumb-seen)) < 1.5 for seen in thumbnails):
                continue
            thumbnails.append(thumb)
            view = perspective([c['name'] for c in cards], initial, previous.get('perspectiveOverride', 'auto'))
            for index, (card, (x1,y1,x2,y2)) in enumerate(zip(cards, boxes)):
                filename = f'card-{round(time*1000):08d}-{index}.jpg'
                if not cv2.imwrite(str(output / filename), pair[0][y1:y2, x1:x2]):
                    raise OSError('Cannot save local card evidence')
                card['crop'] = filename
            frames.append(dict(time=round(time, 3), perspective=view, cards=cards))
            last = time
        after = video.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Video changed during review')
        resolve_perspectives(frames, initial, previous.get('perspectiveOverride', 'auto'))
        slots = merge(initial, frames, previous)
        asset_report = extra / 'update.json' if extra else None
        inventory = json.loads(asset_report.read_text()) if asset_report and asset_report.exists() else {}
        report = dict(schemaVersion=1, videoSHA256=digest, slots=slots, frames=frames,
                      perspectiveOverride=previous.get('perspectiveOverride', 'auto'),
                      assetVersion=inventory.get('libraryVersion', inventory.get('catalogVersion', 'bundled')),
                      missing=inventory.get('missing', []),
                      status='reviewed' if all(s['state'] in ('manual','confirmed') for s in slots) else 'needsReview')
        atomic_json(report_path, report)
        return report
    finally:
        capture.release()
