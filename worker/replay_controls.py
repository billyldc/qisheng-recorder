"""Locate the paired pause/fast-forward controls and read the speed highlight."""
import cv2
import numpy as np


def glyph_template(kind, size):
    result = np.zeros((32, 32), np.uint8)
    if kind == "speed":
        for left in (3, 16):
            cv2.fillPoly(result, [np.array([(left, 3), (left, 29), (left + 13, 16)])], 255)
    elif kind == "play":
        cv2.fillPoly(result, [np.array([(6, 3), (6, 29), (28, 16)])], 255)
    else:
        cv2.rectangle(result, (5, 3), (12, 29), 255, -1)
        cv2.rectangle(result, (20, 3), (27, 29), 255, -1)
    return cv2.resize(result, (size, size), interpolation=cv2.INTER_AREA)


def glyph_score(image, circle, kind, light=False):
    x, y, radius = map(int, circle)
    if min(x-radius, y-radius) < 0 or x+radius > image.shape[1] or y+radius > image.shape[0]:
        return 0.0
    patch = cv2.resize(image[y-radius:y+radius, x-radius:x+radius], (64, 64))
    gray = cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY)
    binary = ((gray > 218) if light else (gray < 135)).astype(np.uint8) * 255
    interior = np.zeros((64, 64), np.uint8)
    cv2.circle(interior, (32, 32), 24, 255, -1)
    binary &= interior
    score = max(float(cv2.minMaxLoc(cv2.matchTemplate(binary[12:53, 12:53], glyph_template(kind, size),
                                                     cv2.TM_CCOEFF_NORMED))[1]) for size in (24, 28, 32, 36, 40))
    if kind == "speed" and light:
        # The real gold 2x button can have one pale and one darker triangle;
        # Hough also chooses its inner ring. Cover that glyph without changing
        # the paired-control and ambiguity requirements.
        cv2.circle(interior, (32, 32), 28, 255, -1)
        brighter = (gray > 185).astype(np.uint8) * 255 & interior
        score = max(score, *(float(cv2.minMaxLoc(cv2.matchTemplate(brighter, glyph_template(kind, size),
                                                                cv2.TM_CCOEFF_NORMED))[1])
                             for size in (40, 42, 44, 46, 48)))
    return score


def toolbar_control(image):
    h, w = image.shape[:2]
    x0, y0 = round(w * .70), round(h * .68)
    gray = cv2.cvtColor(image[y0:, x0:], cv2.COLOR_BGR2GRAY)
    circles = []
    # Search small button rings separately: a rounded toolbar's larger arcs
    # otherwise suppress the actual rings in Hough's minimum-distance filter.
    for lower, upper in ((.012, .035), (.018, .060)):
        found = cv2.HoughCircles(gray, cv2.HOUGH_GRADIENT, dp=1, minDist=max(12, h * .025),
                                 param1=100, param2=22, minRadius=max(8, round(h * lower)),
                                 maxRadius=round(h * upper))
        if found is not None:
            circles.extend((x+x0, y+y0, r) for x, y, r in found[0])
    candidates = []
    for speed in circles:
        dark = glyph_score(image, speed, "speed")
        light = glyph_score(image, speed, "speed", light=True)
        if max(dark, light) < .70 or abs(dark-light) < .12:
            continue
        for pause in circles:
            radius = (speed[2] + pause[2]) / 2
            if not 2.2 * radius < speed[0]-pause[0] < 4.5 * radius or abs(speed[1]-pause[1]) > radius * .35:
                continue
            if max(speed[2], pause[2]) / min(speed[2], pause[2]) > 1.3:
                continue
            pause_score = glyph_score(image, pause, "pause")
            play_score = glyph_score(image, pause, "play")
            if max(pause_score, play_score) < .70 or abs(pause_score - play_score) < .12:
                continue
            candidates.append((min(max(dark, light), max(pause_score, play_score)), speed,
                               2 if light > dark else 1, pause,
                               "running" if pause_score > play_score else "paused"))
    candidates.sort(key=lambda item: -item[0])
    if not candidates:
        return None
    best = candidates[0]
    # Multiple radii of the same pair are one detection, not competing toolbars.
    if any(best[0] - item[0] < .08 and
           (np.linalg.norm(np.array(best[1][:2])-item[1][:2]) > min(best[1][2], item[1][2]) * .6 or
            np.linalg.norm(np.array(best[3][:2])-item[3][:2]) > min(best[3][2], item[3][2]) * .6 or
            best[2] != item[2] or best[4] != item[4]) for item in candidates[1:]):
        return None
    score, circle, multiplier, playback, state = candidates[0]
    return {"speed": {"point": {"x": float(circle[0]/w), "y": float(circle[1]/h)},
                      "multiplier": multiplier, "confidence": score},
            "playback": {"point": {"x": float(playback[0]/w), "y": float(playback[1]/h)},
                         "state": state}}


def speed_control(image):
    toolbar = toolbar_control(image)
    return toolbar["speed"] if toolbar else None


def gear_control(image, reference):
    if reference is None:
        return None
    h, w = image.shape[:2]
    x0, y1 = round(w * .85), round(h * .30)
    search = cv2.cvtColor(image[:y1, x0:], cv2.COLOR_BGR2GRAY)
    template = cv2.cvtColor(reference, cv2.COLOR_BGR2GRAY)
    candidates = []
    # Search actual icon pixels rather than extrapolating the source video's coordinates.
    for size in range(max(14, round(h * .035)), max(16, round(h * .085)), 2):
        if size > min(search.shape):
            continue
        resized = cv2.resize(template, (size, size), interpolation=cv2.INTER_AREA)
        scores = cv2.matchTemplate(search, resized, cv2.TM_CCOEFF_NORMED)
        _, score, _, location = cv2.minMaxLoc(scores)
        if score >= .80:
            candidates.append((score, x0 + location[0] + size/2, location[1] + size/2, size))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    best = candidates[0]
    if any(abs(c[1]-best[1]) + abs(c[2]-best[2]) > best[3] and c[0] > best[0]-.08 for c in candidates[1:]):
        return None
    return {"x": float(best[1]/w), "y": float(best[2]/h)}


def playback_controls(image, reference):
    toolbar = toolbar_control(image)
    return {"gear": gear_control(image, reference) if toolbar else None,
            "playback": toolbar["playback"] if toolbar else None,
            "speed": toolbar["speed"] if toolbar else None}
