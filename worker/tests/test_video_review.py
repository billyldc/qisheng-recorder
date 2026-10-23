import sys
import os
import unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from video_review import UNKNOWN, merge, perspective, board_slots, stable_patch, menu_visible, resolve_perspectives, BoardMatcher, local_pixel_agreement


def frame(t, names, view='bottom'):
    return dict(time=t, perspective=view, cards=[dict(name=n, crop=f'{t}-{i}.jpg') for i, n in enumerate(names)])


class VideoReviewTests(unittest.TestCase):
    def setUp(self):
        self.initial = dict(left=['A', UNKNOWN, 'C'], right=[UNKNOWN]*3)
        self.names = ['D', 'E', 'F', 'A', 'B', 'C']

    def test_one_or_nearby_frames_never_confirm(self):
        for times in ([10], [10, 11, 12]):
            result = merge(self.initial, [frame(t, self.names) for t in times])
            self.assertTrue(all(s['state'] == 'unconfirmed' for s in result))

    def test_multiple_stable_frames_fill_unknown(self):
        result = merge(self.initial, [frame(t, self.names) for t in (10, 13, 16)])
        self.assertEqual([s['value'] for s in result], ['A', 'B', 'C', 'D', 'E', 'F'])
        self.assertTrue(all(s['state'] == 'confirmed' for s in result))

    def test_disagreement_is_not_silently_overwritten(self):
        self.initial['left'][1] = 'wrong'
        result = merge(self.initial, [frame(t, self.names) for t in (10,13,16)])
        self.assertEqual(result[1]['state'], 'conflict')
        self.assertEqual(result[1]['value'], 'wrong')

    def test_manual_confirmation_survives_recheck(self):
        previous = dict(slots=[dict(manual=True, value='human')])
        result = merge(self.initial, [frame(t, self.names) for t in (10,13,16)], previous)
        self.assertEqual((result[0]['state'], result[0]['value']), ('manual', 'human'))
        self.initial['manualCharacters'] = [True]*6
        result = merge(self.initial, [frame(t, self.names) for t in (10,13,16)])
        self.assertEqual(result[1]['value'], UNKNOWN)

    def test_switching_perspective_maps_each_frame(self):
        self.assertEqual(perspective(self.names, self.initial), 'bottom')
        swapped = self.names[3:] + self.names[:3]
        self.assertEqual(perspective(swapped, self.initial), 'top')
        frames = [frame(10, self.names), frame(13, swapped, 'top'), frame(16, swapped, 'top')]
        self.assertEqual([s['value'] for s in merge(self.initial, frames)], ['A','B','C','D','E','F'])

    def test_mirror_and_missing_anchors_do_not_guess_view(self):
        mirror = dict(left=['A','B','C'], right=['A','B','C'])
        self.assertEqual(perspective(['A','B','C']*2, mirror), 'unknown')
        self.assertEqual(perspective(self.names, {}), 'unknown')
        result = merge(self.initial, [frame(t, self.names, 'unknown') for t in (10,13,16)])
        self.assertTrue(all(s['state'] == 'unconfirmed' for s in result))

    def test_conflicting_video_votes_do_not_use_majority(self):
        frames = [frame(t, self.names) for t in (10,13,16)]
        other = list(self.names); other[4] = 'other'
        result = merge(self.initial, frames + [frame(19, other)])
        self.assertEqual(result[1]['state'], 'conflict')

    def test_unknown_reference_stays_unknown(self):
        names = list(self.names); names[1] = UNKNOWN
        result = merge(self.initial, [frame(t, names) for t in (10,13,16)])
        self.assertEqual(result[4]['value'], UNKNOWN)
        self.assertEqual(result[4]['state'], 'unconfirmed')

    def test_stability_rejects_black_blur_and_animation(self):
        rng = np.random.default_rng(7)
        image = rng.integers(0,255,(120,70,3),dtype=np.uint8)
        self.assertTrue(stable_patch(image, image))
        self.assertFalse(stable_patch(image, 255-image))
        black = np.zeros_like(image)
        self.assertFalse(stable_patch(black, black))
        blur = cv2.GaussianBlur(image, (41,41), 10)
        self.assertFalse(stable_patch(blur, blur))

    def test_missing_slot_inferred_only_in_full_board_geometry(self):
        cards = [dict(name=str(i), box=[x,y,x+100,y+180], score=.9)
                 for i,(x,y) in enumerate(( (440,150),(580,150),(720,170),(440,440),(580,440),(720,460) ))]
        result = board_slots(cards[:4] + cards[5:], (800,1300,3))
        self.assertIsNotNone(result)
        self.assertEqual(result[4]['name'], UNKNOWN)
        self.assertIsNone(board_slots(cards[:3], (800,1300,3)))
        self.assertIsNone(board_slots([], (800,1300,3)))

    def test_menu_is_not_a_stable_board(self):
        image = np.zeros((800,1300,3), np.uint8)
        for y in (60,110,160):
            cv2.rectangle(image, (950,y), (1220,y+30), (210,210,210), -1)
        self.assertTrue(menu_visible(image))
        self.assertFalse(menu_visible(np.zeros_like(image)))

    def test_temporal_view_anchors_do_not_guess_mirror(self):
        frames = [frame(t, ['A','B',UNKNOWN,'D','E','F'], 'unknown') for t in (10,13,16)]
        frames.append(frame(19, ['A','B','C','D','E','F'], 'top'))
        resolve_perspectives(frames, self.initial, 'auto')
        self.assertTrue(all(f['perspective'] == 'top' for f in frames))
        mirror = [frame(t, ['A','B','C']*2, 'unknown') for t in (10,13,16)]
        resolve_perspectives(mirror, dict(left=['A','B','C'],right=['A','B','C']), 'auto')
        self.assertTrue(all(f['perspective'] == 'unknown' for f in mirror))

    def test_local_pixels_reject_unrelated_reference(self):
        rng = np.random.default_rng(11)
        art = rng.integers(0,255,(400,240,3),dtype=np.uint8)
        points = np.float32([(x,y) for y in (80,160,240,320) for x in (50,120,190)])
        self.assertTrue(local_pixel_agreement(art, art, points, 1))
        self.assertFalse(local_pixel_agreement(255-art, art, points, 1))


class BoardImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assets = Path(os.environ.get('QISHENG_TEST_ASSETS', Path(__file__).resolve().parents[2] / 'Assets'))
        cls.matcher = BoardMatcher(assets)
        cls.names = ['诺艾尔','嘉明','阿贝多','伊涅芙','芙宁娜','菲林斯']
        references = {e[0]: e[3] for e in cls.matcher.entries}
        if any(name not in references for name in cls.names):
            raise unittest.SkipTest('Full reference catalog required')
        cls.scene = np.full((800,1300,3), (100,140,110), np.uint8)
        for i,name in enumerate(cls.names):
            x,y = 420+(i%3)*170, 100+(i//3)*330
            cls.scene[y:y+250,x:x+146] = cv2.resize(references[name], (146,250))

    def test_full_cards_survive_resolution_and_padding(self):
        for scale in (1, .8):
            scene = cv2.resize(self.scene, None, fx=scale, fy=scale)
            scene = cv2.copyMakeBorder(scene, 35, 12, 8, 8, cv2.BORDER_CONSTANT)
            slots = board_slots(self.matcher.cards(scene), scene.shape)
            self.assertIsNotNone(slots)
            self.assertEqual([s['name'] for s in slots], self.names)

    def test_removed_card_is_not_forced_to_an_old_character(self):
        matcher = self.matcher
        old = matcher.entries
        try:
            matcher.entries = [e for e in old if e[0] != '诺艾尔']
            matcher.matcher.clear()
            matcher.matcher.add([e[2] for e in matcher.entries]); matcher.matcher.train()
            slots = board_slots(matcher.cards(self.scene), self.scene.shape)
            self.assertIsNotNone(slots)
            self.assertEqual(slots[0]['name'], UNKNOWN)
            self.assertEqual([s['name'] for s in slots[1:]], self.names[1:])
        finally:
            matcher.entries = old
            matcher.matcher.clear()
            matcher.matcher.add([e[2] for e in old]); matcher.matcher.train()


if __name__ == '__main__':
    unittest.main()
