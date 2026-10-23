import json
import sys
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from update_assets import catalog_names, update_assets, CATALOG


class AssetUpdateTests(unittest.TestCase):
    def test_catalog_rejects_paths_and_action_cards(self):
        with self.assertRaises(ValueError):
            catalog_names({"data": {"items": {"1": {"type": "characterCard", "icon": "../../evil", "name": "bad"}}}})
        self.assertEqual(catalog_names({"data": {"items": {
            "1": {"type": "characterCard", "icon": "UI_Gcg_CardFace_Char_Test", "name": "valid"},
            "2": {"type": "actionCard", "icon": "UI_Gcg_CardFace_Char_Action", "name": "action"}}}}),
            {"UI_Gcg_CardFace_Char_Test": "valid"})

    def test_update_is_append_only_and_survives_failed_download(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bundled, extra = root / "bundled", root / "extra"
            bundled.mkdir()
            old, new, failed = ["UI_Gcg_CardFace_Char_" + name for name in ("Old", "New", "Failed")]
            original = json.dumps({old: "old name"})
            (bundled / "names.json").write_text(original)
            (bundled / "portraits").mkdir()
            cv2.imwrite(str(bundled / "portraits" / (old + ".png")), np.full((128,128,3),125,np.uint8))
            payload = json.dumps({"data": {"items": {str(i): {"type": "characterCard", "icon": stem, "name": stem}
                                                       for i, stem in enumerate((old, new, failed))}}}).encode()
            png = cv2.imencode(".png", np.full((128, 128, 3), 125, np.uint8))[1].tobytes()
            urls = []
            def fetch(url, limit):
                urls.append(url)
                if url == CATALOG: return payload
                if failed in url: raise OSError("offline")
                return png
            result = update_assets(bundled, extra, fetch)
            self.assertEqual(result["total"], 2)
            self.assertEqual(len(result["added"]), 1)
            self.assertEqual(len(result["failed"]), 1)
            self.assertFalse(any(old in url for url in urls))
            self.assertEqual((bundled / "names.json").read_text(), original)
            previous = (extra / "portraits" / (new + ".png")).read_bytes()
            result = update_assets(bundled, extra, fetch)
            self.assertEqual(result["added"], [])
            self.assertEqual((extra / "portraits" / (new + ".png")).read_bytes(), previous)

    def test_invalid_catalog_does_not_change_existing_names(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "names.json").write_text("{}")
            result = update_assets(root, root / "extra", lambda *args: b'{"data":{"items":{}}}')
            self.assertIsNotNone(result['error'])
            self.assertFalse((root / "extra" / "names.json").exists())

    def test_corrupt_registered_image_is_repaired_atomically(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); extra = root / 'extra'; extra.mkdir()
            stem = 'UI_Gcg_CardFace_Char_Test'
            (root / 'names.json').write_text('{}')
            (extra / 'names.json').write_text(json.dumps({stem: 'test'}))
            (extra / 'portraits').mkdir()
            target = extra / 'portraits' / (stem+'.png'); target.write_bytes(b'corrupt')
            payload = json.dumps({'data': {'items': {'1': {'type':'characterCard','icon':stem,'name':'test'}}}}).encode()
            png = cv2.imencode('.png', np.full((128,128,3),125,np.uint8))[1].tobytes()
            report = update_assets(root, extra, lambda url, _: payload if url == CATALOG else png)
            self.assertEqual(report['missing'], [])
            self.assertIsNotNone(report['lastSuccessAt'])
            self.assertIsNotNone(cv2.imread(str(target)))
            old_success = report['lastSuccessAt']
            report = update_assets(root, extra, lambda *_: b'bad')
            self.assertEqual(report['lastSuccessAt'], old_success)
            self.assertEqual(report['total'], 1)


if __name__ == "__main__":
    unittest.main()
