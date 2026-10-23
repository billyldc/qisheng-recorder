import sys
import unittest
from unittest.mock import patch
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from replay_controls import speed_control, playback_controls, gear_control


def controls_frame(enabled=False, scale=1):
    image = np.full((818, 1314, 3), (110, 135, 120), np.uint8)
    cv2.rectangle(image, (1100, 710), (1270, 793), (80, 70, 60), -1)
    for center in (1145, 1227):
        cv2.circle(image, (center, 752), 27, (115, 160, 190), -1)
        cv2.circle(image, (center, 752), 23, (210, 230, 242), -1)
    cv2.rectangle(image, (1136, 741), (1142, 763), (80, 70, 60), -1)
    cv2.rectangle(image, (1148, 741), (1154, 763), (80, 70, 60), -1)
    if enabled:
        cv2.circle(image, (1227, 752), 23, (95, 178, 220), -1)
    color = (185, 230, 250) if enabled else (80, 70, 60)
    for left in (1217, 1228):
        cv2.fillPoly(image, [np.array([(left, 742), (left, 762), (left+11, 752)])], color)
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)


class ControlTests(unittest.TestCase):
    def test_large_rounded_border_does_not_suppress_button_rings(self):
        image = controls_frame(enabled=True)
        h, w = image.shape[:2]
        x0, y0 = round(w * .70), round(h * .68)
        small = np.array([[[1145-x0, 752-y0, 27], [1227-x0, 752-y0, 27]]], np.float32)
        outer = np.array([[[1145-x0, 752-y0, 49], [1227-x0, 752-y0, 49]]], np.float32)
        # Reproduce Hough suppressing small rings when larger border arcs win.
        def circles(*args, **kwargs):
            return small if kwargs['maxRadius'] <= round(h * .035) else outer
        with patch('replay_controls.cv2.HoughCircles', side_effect=circles) as detector:
            control = playback_controls(image, None)
            self.assertEqual(control['playback']['state'], 'running')
            self.assertEqual(control['speed']['multiplier'], 2)
            self.assertEqual(detector.call_count, 2)

    def test_letterboxed_window_has_early_playback_and_speed_evidence(self):
        for enabled in (False, True):
            source = controls_frame(enabled)
            image = np.zeros((940, 1324, 3), np.uint8)
            image[54:872, 5:1319] = source
            for scale in (.8, 1, 1.5):
                with self.subTest(enabled=enabled, scale=scale):
                    frame = cv2.resize(image, None, fx=scale, fy=scale)
                    control = playback_controls(frame, None)
                    self.assertEqual(control['playback']['state'], 'running')
                    self.assertEqual(control['speed']['multiplier'], 2 if enabled else 1)

    def test_playback_state_and_gear_at_multiple_scales(self):
        reference = cv2.imread(str(Path(__file__).resolve().parents[2] / "Assets/controls/replay-gear.png"))
        self.assertIsNotNone(reference)
        for paused in (False, True):
            original = controls_frame(enabled=True)
            if paused:
                cv2.circle(original, (1145, 752), 23, (210, 230, 242), -1)
                cv2.fillPoly(original, [np.array([(1138, 740), (1138, 764), (1158, 752)])], (80, 70, 60))
            original[65:111, 1260:1306] = reference
            for scale in (.8, 1, 1.5, 2):
                image = cv2.resize(original, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
                control = playback_controls(image, reference)
                with self.subTest(scale=scale, paused=paused):
                    self.assertIsNotNone(control['playback'])
                    self.assertEqual(control['playback']['state'], 'paused' if paused else 'running')
                    self.assertIsNotNone(control['gear'])
                    self.assertAlmostEqual(control['gear']['x'], 1283/1314, delta=.005)
        self.assertEqual(playback_controls(np.zeros((720,1280,3), np.uint8), reference),
                         dict(gear=None, playback=None, speed=None))
        # A settings icon outside a verified replay toolbar is never enough to click.
        no_toolbar = np.zeros((818,1314,3), np.uint8)
        no_toolbar[65:111,1260:1306] = reference
        self.assertIsNotNone(gear_control(no_toolbar, reference))
        self.assertIsNone(playback_controls(no_toolbar, reference)['gear'])

    def test_reads_normal_and_highlighted_speed_at_multiple_scales(self):
        for scale in (.8, 1, 1.5, 2):
            for enabled in (False, True):
                with self.subTest(scale=scale, enabled=enabled):
                    control = speed_control(controls_frame(enabled, scale))
                    self.assertIsNotNone(control)
                    self.assertEqual(control["multiplier"], 2 if enabled else 1)
                    self.assertAlmostEqual(control["point"]["x"], 1227/1314, delta=.005)
                    self.assertAlmostEqual(control["point"]["y"], 752/818, delta=.005)

    def test_rejects_missing_pause_and_unrelated_screen(self):
        image = controls_frame()
        cv2.rectangle(image, (1110, 715), (1180, 787), (110, 135, 120), -1)
        self.assertIsNone(speed_control(image))
        self.assertIsNone(speed_control(np.zeros((720, 1280, 3), np.uint8)))


if __name__ == "__main__":
    unittest.main()
