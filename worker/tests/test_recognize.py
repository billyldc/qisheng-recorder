import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from recognize import date_value, identify, recognize, portrait_triplet, is_play_button, pixel_correlation


class RecognitionTests(unittest.TestCase):
    def test_triplet_rejects_stray_circles(self):
        self.assertEqual(portrait_triplet([(100, 100, 20), (130, 95, 25), (150, 100, 20), (200, 100, 20)]),
                         [(100, 100, 20), (150, 100, 20), (200, 100, 20)])

    def test_play_triangle_not_floating_rectangle(self):
        canvas = np.full((160, 160, 3), 230, np.uint8)
        cv2.fillPoly(canvas, [np.array([(70, 60), (70, 100), (100, 80)])], (60, 60, 60))
        self.assertTrue(is_play_button(canvas, (80, 80, 45)))
        cv2.rectangle(canvas, (55, 55), (105, 105), (60, 60, 60), -1)
        self.assertFalse(is_play_button(canvas, (80, 80, 45)))

    def test_dates_and_invalid_input(self):
        self.assertEqual(date_value("2000年2月3日 04:05"), "2000-02-03_0405")
        self.assertEqual(date_value("2000年2月3日 04：05"), "2000-02-03_0405")
        self.assertIsNone(date_value("2000年99月3日 04:05"))
        self.assertIsNone(date_value("匹配模式"))

    def test_not_favorites_does_not_invent_rows(self):
        self.assertEqual(recognize(np.zeros((300, 500, 3), np.uint8), [], Path("nonexistent")), [])

    def test_flat_portrait_remains_unknown(self):
        sift = cv2.SIFT_create()
        self.assertEqual(identify(np.zeros((200, 200, 3), np.uint8), (100, 100, 70), sift, []), "未识别")

    def test_invalid_circle_remains_unknown(self):
        image = np.zeros((200, 200, 3), np.uint8)
        for circle in [(100, 100, 0), (100, 100, -1), (10, 10, 40)]:
            with self.subTest(circle=circle):
                self.assertEqual(identify(image, circle, None, []), "未识别")

    def test_resize_retry_preserves_ambiguity(self):
        image = np.zeros((100, 100, 3), np.uint8)
        with patch('recognize.portrait_candidates', return_value={'a': 12, 'b': 11}) as matcher:
            self.assertEqual(identify(image, (50, 50, 40), None, []), "未识别")
            self.assertEqual(matcher.call_count, 1)

    def test_missing_features_retry_at_bounded_sizes(self):
        image = np.zeros((100, 100, 3), np.uint8)
        with patch('recognize.portrait_candidates', side_effect=[{}, {}, {'a': 15}]) as matcher:
            self.assertEqual(identify(image, (50, 50, 40), None, []), 'a')
            self.assertEqual([call.args[0].shape[0] for call in matcher.call_args_list], [160, 224, 80])

    def test_pixels_reject_descriptor_only_false_positive(self):
        rng = np.random.default_rng(31)
        art = cv2.GaussianBlur(rng.integers(0, 255, (160, 160, 3), dtype=np.uint8), (3, 3), .7)
        sift = cv2.SIFT_create(nfeatures=1000, contrastThreshold=.025)
        keys, descriptors = sift.detectAndCompute(art, None)
        points = np.float32([key.pt for key in keys])
        # Simulate descriptors claiming a match while the actual card disagrees.
        entries = [('wrong', points, descriptors, 255-art)]
        self.assertEqual(identify(art, (80, 80, 80), sift, entries), '未识别')
        entries = [('correct', points, descriptors, art)]
        self.assertEqual(identify(art, (80, 80, 80), sift, entries), 'correct')
        entries.append(('ambiguous', points, descriptors, art))
        self.assertEqual(identify(art, (80, 80, 80), sift, entries), '未识别')

    def test_pixel_check_rejects_flat_and_out_of_frame_reference(self):
        image = np.full((160, 160, 3), 128, np.uint8)
        mask = np.full((160, 160), 255, np.uint8)
        identity = np.float64([[1, 0, 0], [0, 1, 0]])
        self.assertEqual(pixel_correlation(image, mask, image, identity), 0)
        identity[0, 2] = 1000
        self.assertEqual(pixel_correlation(image, mask, image, identity), 0)

    def test_matching_requires_spatially_consistent_features(self):
        rng = np.random.default_rng(20)
        art = rng.integers(0, 255, size=(280, 280, 3), dtype=np.uint8)
        art = cv2.GaussianBlur(art, (3, 3), .7)
        sift = cv2.SIFT_create(nfeatures=1000, contrastThreshold=.025)
        keys, descriptors = sift.detectAndCompute(art, None)
        entries = [("reference", np.float32([key.pt for key in keys]), descriptors)]
        self.assertEqual(identify(art, (140, 140, 100), sift, entries), "reference")
        shuffled = entries[0][1].copy()
        rng.shuffle(shuffled)
        self.assertEqual(identify(art, (140, 140, 100), sift, [("wrong", shuffled, descriptors)]), "未识别")


if __name__ == "__main__":
    unittest.main()
