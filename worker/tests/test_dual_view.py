import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('dual_view', Path(__file__).resolve().parents[2]/'scripts/merge_dual_view.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


def plan_fixture():
    metadata = dict(date='2026-01-01_1200', mode='Match', left=['A','B','C'], right=['D','E','F'])
    anchors = [dict(own=a, opponent=b, event=f'event {i}') for i, (a,b) in enumerate(((10,20),(20,25),(30,35),(40,55)))]
    plan = dict(schemaVersion=1, status='reviewed',
                own=dict(metadata=dict(metadata, recordingPerspective='own'), sha256='a', viewport=[0,0,1,1]),
                opponent=dict(metadata=dict(metadata, recordingPerspective='opponent'), sha256='b', viewport=[0,0,1,1]),
                opponentHand=[.2,.88,.6,.12], opponentDice=[.94,.1,.06,.4], ownDice=[.94,.1,.06,.4],
                composition=dict(opponentHand=[.25,0,.6,.12], opponentDice=[.94,.1,.06,.4], ownDice=[.94,.55,.06,.4]),
                confirmed=dict(sameMatch=True, ownBottomThroughout=True, opponentBottomThroughout=True, layout=True),
                anchors=anchors,
                checks=[dict(own=a, opponent=b, event='independent event') for a,b in ((15,22.5),(25,30),(35,45))])
    media = dict(own=dict(width=1280, height=720, duration=60, audio=True),
                 opponent=dict(width=1280, height=720, duration=90, audio=True))
    return plan, media


class DualViewTests(unittest.TestCase):
    def test_piecewise_speed_and_no_extrapolation(self):
        plan, media = plan_fixture()
        self.assertEqual(merge.validate(plan, media), 30)
        self.assertEqual(merge.mapped_time(plan['anchors'], 15), 22.5)
        self.assertEqual(merge.mapped_time(plan['anchors'], 25), 30)
        self.assertEqual(merge.mapped_time(plan['anchors'], 35), 45)
        for time in (0, 41):
            with self.assertRaises(merge.PlanError):
                merge.mapped_time(plan['anchors'], time)

    def test_final_perspective_alone_is_not_evidence(self):
        plan, media = plan_fixture()
        plan['opponent']['metadata']['confirmedPerspective'] = 'opponent'
        plan['confirmed']['opponentBottomThroughout'] = False
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_unreviewed_or_missing_layout_cannot_render(self):
        plan, media = plan_fixture()
        plan['status'] = 'needsReview'
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)
        plan['status'] = 'reviewed'
        plan['opponentHand'] = None
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_preview_still_requires_match_orientation_and_safe_mapping(self):
        plan, media = plan_fixture()
        plan['status'] = 'needsReview'
        plan['checks'] = []
        self.assertEqual(merge.validate(plan, media, preview=True), 30)
        plan['confirmed']['opponentBottomThroughout'] = False
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media, preview=True)
        plan['confirmed']['opponentBottomThroughout'] = True
        plan['anchors'][-1]['own'] = 50
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media, preview=True)

    def test_wrong_match_lineup_view_or_same_file_rejected(self):
        for path, value in ((('metadata','date'), 'other'), (('metadata','mode'), 'other'),
                            (('metadata','left'), ['wrong','B','C']),
                            (('metadata','recordingPerspective'), 'own'), (('sha256',), 'a')):
            plan, media = plan_fixture()
            target = plan['opponent']
            for component in path[:-1]:
                target = target[component]
            target[path[-1]] = value
            with self.assertRaises(merge.PlanError):
                merge.validate(plan, media)

    def test_unknown_character_does_not_invent_identity(self):
        plan, media = plan_fixture()
        plan['opponent']['metadata']['left'] = ['未识别','B','C']
        self.assertEqual(merge.validate(plan, media), 30)
        plan['confirmed']['sameMatch'] = False
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_independent_checks_are_required_in_every_interval(self):
        plan, media = plan_fixture()
        plan['checks'].pop(1)
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)
        plan, media = plan_fixture()
        plan['checks'][1]['opponent'] += .25
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_invalid_or_sparse_anchors_rejected(self):
        for value in (float('nan'), float('inf'), True, -1, 60, 100):
            plan, media = plan_fixture()
            plan['anchors'][1]['own'] = value
            with self.assertRaises(merge.PlanError):
                merge.validate(plan, media)
        plan, media = plan_fixture()
        plan['anchors'][2]['opponent'] = plan['anchors'][1]['opponent']
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_one_offset_is_not_a_reviewed_plan(self):
        plan, media = plan_fixture()
        plan['anchors'] = plan['anchors'][:2]
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_crops_bounded_even_and_preserve_edges(self):
        self.assertEqual(merge.pixel_rect([0,0,1,1], 1324, 940), (0,0,1324,940))
        self.assertEqual(merge.pixel_rect([0,.131914893617,1,.8], 1324, 940), (0,124,1324,752))
        self.assertEqual(merge.pixel_rect([.01,.01,.98,.98], 100, 100), (0,0,100,100))
        for box in ([0,0,2,1], [0,0,0,1], [-.1,0,1,1], [0,0,float('nan'),1], [False,0,1,1]):
            with self.assertRaises(merge.PlanError):
                merge.pixel_rect(box, 100, 100)

    def test_graph_uses_only_own_audio_and_one_board(self):
        plan, media = plan_fixture()
        graph, size = merge.filter_graph(plan, media, 'preview.txt')
        self.assertIn('[0:a:0]atrim', graph)
        self.assertNotIn('[1:a', graph)
        self.assertEqual(graph.count('overlay='), 3)
        self.assertNotIn('pad=', graph)
        self.assertIn('scale=1280:720,setsar=1[base]', graph)
        self.assertIn('split=2', graph)
        self.assertIn('setpts=\'if(', graph)
        self.assertIn('expansion=none', graph)
        self.assertEqual(size, (1280,720))
        media['own']['audio'] = False
        graph, _ = merge.filter_graph(plan, media)
        self.assertNotIn('[audio]', graph)
        self.assertNotIn('drawtext=', graph)

    def test_overwide_dice_crop_rejected(self):
        plan, media = plan_fixture()
        plan['opponentDice'] = [0,0,1,1]
        with self.assertRaises(merge.PlanError):
            merge.filter_graph(plan, media)

    def test_old_layout_requires_explicit_destination_review(self):
        plan, media = plan_fixture()
        del plan['composition']
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)
        plan, media = plan_fixture()
        del plan['ownDice']
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)

    def test_in_place_layout_rejects_board_occlusion_or_dice_overlap(self):
        for key, box in (('opponentHand', [.2,.1,.6,.12]),
                         ('opponentDice', [.8,.1,.06,.4]),
                         ('ownDice', [.94,.45,.06,.4]),
                         ('ownDice', [.92,.55,.08,.4]),
                         ('opponentHand', [.4,0,.6,.12])):
            plan, media = plan_fixture()
            plan['composition'][key] = box
            with self.subTest(key=key, box=box), self.assertRaises(merge.PlanError):
                merge.validate(plan, media)

    def test_in_place_layout_rejects_stretched_cards(self):
        plan, media = plan_fixture()
        plan['composition']['opponentHand'] = [.25,0,.6,.05]
        with self.assertRaises(merge.PlanError):
            merge.filter_graph(plan, media)

    def test_small_reviewed_background_edge_can_sit_under_upper_dice(self):
        plan, media = plan_fixture()
        plan['composition']['opponentHand'] = [.35,0,.6,.13]
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)
        plan['composition']['rightEdgeBackgroundOverlap'] = True
        self.assertEqual(merge.validate(plan, media), 30)
        plan['composition']['opponentHand'] = [.38,0,.6,.13]
        with self.assertRaises(merge.PlanError):
            merge.validate(plan, media)


if __name__ == '__main__':
    unittest.main()
