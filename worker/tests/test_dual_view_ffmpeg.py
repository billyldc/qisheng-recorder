"""Synthetic encode/decode regression; this is not real-game sync acceptance."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('dual_view', Path(__file__).resolve().parents[2]/'scripts/merge_dual_view.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg integration test')
class EncodeTests(unittest.TestCase):
    def test_piecewise_render_layout_audio_and_source_integrity(self):
        with tempfile.TemporaryDirectory(prefix='dual-view-test-') as directory:
            root = Path(directory)
            base = [merge.executable('ffmpeg'), '-v', 'error', '-nostdin', '-f', 'lavfi']
            subprocess.run(base + ['-i', 'color=c=blue:s=320x180:r=30:d=8', '-f', 'lavfi',
                                  '-i', 'sine=frequency=440:duration=8',
                                  '-vf', 'drawbox=x=300:y=18:w=20:h=72:color=white:t=fill',
                                  '-c:v', 'libx264', '-c:a', 'aac',
                                  '-pix_fmt', 'yuv420p', str(root/'own.mp4')], check=True, capture_output=True)
            subprocess.run(base + ['-i', 'color=c=green:s=320x180:r=30:d=8', '-vf',
                                  "drawbox=x=0:y=160:w=320:h=20:color=yellow:t=fill,"
                                  "drawbox=x=0:y=160:w=320:h=20:color=magenta:t=fill:enable='between(t,1,3)',"
                                  "drawbox=x=0:y=160:w=320:h=20:color=cyan:t=fill:enable='gte(t,3)',"
                                  'drawbox=x=300:y=18:w=20:h=140:color=red:t=fill',
                                  '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(root/'opponent.mp4')],
                           check=True, capture_output=True)
            metadata = dict(date='2026-01-01_1200', mode='synthetic', left=['A','B','C'], right=['D','E','F'])
            plan = dict(schemaVersion=1, status='reviewed',
                        opponentHand=[.2,.9,.6,.1], opponentDice=[.94,.1,.06,.4], ownDice=[.94,.1,.06,.4],
                        composition=dict(opponentHand=[.25,0,.6,.1], opponentDice=[.94,.1,.06,.4], ownDice=[.94,.55,.06,.4]),
                        confirmed=dict(sameMatch=True, ownBottomThroughout=True, opponentBottomThroughout=True, layout=True),
                        anchors=[dict(own=a, opponent=b, event='synthetic anchor') for a,b in ((0,0),(2,1),(4,3),(6,7))],
                        checks=[dict(own=a, opponent=b, event='synthetic checkpoint') for a,b in ((1,.5),(3,2),(5,5))])
            for key in ('own', 'opponent'):
                path = root/(key+'.mp4')
                plan[key] = dict(path=str(path), sha256=merge.digest(path), viewport=[0,0,1,1],
                                 metadata=dict(metadata, recordingPerspective=key))
            result = merge.render(plan, root/'merged.mp4')
            self.assertAlmostEqual(result['media']['duration'], 6, delta=.1)
            self.assertEqual(result['audio'], 'own')
            self.assertFalse(result['fullMatch'])
            self.assertEqual(json.loads((root/'merged.merge.json').read_text())['outputSHA256'], merge.digest(root/'merged.mp4'))
            media = {key: merge.probe(root/(key+'.mp4')) for key in ('own','opponent')}
            _, (width, height) = merge.filter_graph(plan, media)
            self.assertEqual((width,height), (1280,720))
            self.assertEqual((result['media']['width'],result['media']['height']), (1280,720))
            def frame(time):
                return subprocess.run([merge.executable('ffmpeg'), '-v', 'error', '-ss', str(time), '-i', str(root/'merged.mp4'),
                                       '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], check=True, capture_output=True).stdout
            raw = frame(1)
            def pixel(x,y):
                offset = (y*width+x)*3
                return tuple(raw[offset:offset+3])
            self.assertGreater(pixel(640,30)[0], 200)  # Upright opponent hand replaces the top strip.
            self.assertGreater(pixel(640,30)[1], 200)
            self.assertGreater(pixel(640,height-100)[2], 200)  # Own board remains blue.
            self.assertGreater(pixel(width-25,200)[0], 200)  # Opponent dice occupy the upper right.
            self.assertLess(pixel(width-25,200)[1], 30)
            self.assertTrue(all(v > 200 for v in pixel(width-25,500)))  # Own dice are below, not duplicated opponent dice.
            raw = frame(3)  # Own 3s maps to opponent 2s, not 3s.
            self.assertGreater(pixel(640,30)[0], 200)
            self.assertLess(pixel(640,30)[1], 30)
            self.assertGreater(pixel(640,30)[2], 200)
            raw = frame(5)  # Own 5s maps to opponent 5s after another speed change.
            self.assertLess(pixel(640,30)[0], 30)
            self.assertGreater(pixel(640,30)[1], 200)
            self.assertGreater(pixel(640,30)[2], 200)
            self.assertEqual(result['sourceHashes'], {k: merge.digest(root/(k+'.mp4')) for k in ('own','opponent')})
            with self.assertRaises(merge.PlanError):
                merge.render(plan, root/'merged.mp4')
            plan['own']['sha256'] = 'changed'
            with self.assertRaises(merge.PlanError):
                merge.render(plan, root/'changed.mp4')
            self.assertFalse((root/'changed.mp4').exists())


if __name__ == '__main__':
    unittest.main()
