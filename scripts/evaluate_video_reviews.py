#!/usr/bin/env python3
"""Private evaluation manifests stay outside Git; report conservative coverage."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'worker'))
from video_review import review_video
from update_assets import atomic_json


def metrics(cases):
    total = len(cases)*6
    correct = sum(c['correct'] for c in cases)
    wrong = sum(c['wrong'] for c in cases)
    unknown = total-correct-wrong
    return dict(matches=len(cases), sixCorrect=sum(c['correct'] == 6 for c in cases),
                sixCorrectRate=sum(c['correct'] == 6 for c in cases)/len(cases) if cases else 0,
                wrong=wrong, wrongRate=wrong/total if total else 0,
                unconfirmed=unknown, unconfirmedRate=unknown/total if total else 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--extra-assets', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--start-case', type=int, default=1)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = []
    for index, item in enumerate(json.loads(args.manifest.read_text())['items']):
        if index+1 < args.start_case:
            continue
        video = Path(item['source'])
        report = review_video(video, video.with_suffix('.json'), args.output / f'case-{index+1}', args.assets, args.extra_assets)
        expected = item['own'] + item['opponent']
        # Alias spelling must be explicitly supplied in the private manifest.
        aliases = item.get('aliases', {})
        confirmed = [(s['state'] == 'confirmed' and not s['manual'], aliases.get(s['value'],s['value'])) for s in report['slots']]
        case = dict(case=index+1, videoSHA256=report['videoSHA256'],
                    correct=sum(ok and value == name for (ok,value),name in zip(confirmed, expected)),
                    wrong=sum(ok and value != name for (ok,value),name in zip(confirmed, expected)),
                    stableFrames=len(report['frames']))
        cases.append(case)
        atomic_json(args.output / 'metrics.json', dict(cases=cases, metrics=metrics(cases)))
        print(json.dumps(case), flush=True)
    print(json.dumps(metrics(cases)), flush=True)


if __name__ == '__main__':
    main()
