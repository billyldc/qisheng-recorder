"""Optional private regression data is supplied locally, never distributed."""
import json
import os
import sys
import unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from recognize import card_features, identify

FIXTURES = Path(os.environ['QISHENG_PRIVATE_PORTRAIT_FIXTURES']) if os.environ.get('QISHENG_PRIVATE_PORTRAIT_FIXTURES') else None
ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(FIXTURES is not None, 'Optional private portrait fixtures are not distributed')
class PortraitRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assets = Path(os.environ.get('QISHENG_TEST_ASSETS', ROOT / 'Assets'))
        cls.sift, cls.entries = card_features(assets)
        cls.samples = json.loads((FIXTURES / 'manifest.json').read_text())['samples']
        assert len(cls.entries) >= 145, 'Regression must search the complete reference catalog'
        assert len(cls.samples) == 30, 'The complete reviewed screenshot has 30 portraits'

    def test_reviewed_portraits_at_multiple_resolutions(self):
        for sample in self.samples:
            original = cv2.imread(str(FIXTURES / sample['file']))
            self.assertIsNotNone(original)
            for width in (2400, 1920, 1280):
                size = 2 * round(original.shape[0] * width / 2400 / 2)
                crop = cv2.resize(original, (size, size), interpolation=cv2.INTER_AREA)
                with self.subTest(file=sample['file'], width=width):
                    self.assertEqual(identify(crop, (size//2, size//2, size//2), self.sift, self.entries), sample['name'])

    def test_tiny_portraits_prefer_unknown_over_wrong_names(self):
        correct = 0
        for sample in self.samples:
            original = cv2.imread(str(FIXTURES / sample['file']))
            size = 2 * round(original.shape[0] * 960 / 2400 / 2)
            crop = cv2.resize(original, (size, size), interpolation=cv2.INTER_AREA)
            with self.subTest(file=sample['file']):
                result = identify(crop, (size//2, size//2, size//2), self.sift, self.entries)
                self.assertIn(result, (sample['name'], '未识别'))
                correct += result == sample['name']
        # Two twice-downsampled crocodile crops currently lack enough spatial
        # coverage. Keep those unknown instead of lowering the acceptance bar.
        self.assertGreaterEqual(correct, 28)

    def test_compressed_and_slightly_misaligned_portraits(self):
        # Independent perturbations, not extra training templates.
        for sample in self.samples:
            crop = cv2.imread(str(FIXTURES / sample['file']))
            crop = cv2.resize(crop, (72, 72), interpolation=cv2.INTER_AREA)
            ok, encoded = cv2.imencode('.jpg', crop, [cv2.IMWRITE_JPEG_QUALITY, 75])
            self.assertTrue(ok)
            crop = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
            canvas = cv2.copyMakeBorder(crop, 3, 3, 3, 3, cv2.BORDER_REFLECT_101)
            with self.subTest(file=sample['file']):
                result = identify(canvas, (40, 38, 36), self.sift, self.entries)
                self.assertEqual(result, sample['name'])

    def test_unrelated_images_stay_unknown(self):
        rng = np.random.default_rng(9)
        noise = rng.integers(0, 255, (160, 160, 3), dtype=np.uint8)
        for crop in (np.zeros_like(noise), noise, cv2.GaussianBlur(noise, (3, 3), .7)):
            self.assertEqual(identify(crop, (80, 80, 80), self.sift, self.entries), '未识别')


if __name__ == '__main__':
    unittest.main()
