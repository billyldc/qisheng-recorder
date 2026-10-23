#!/usr/bin/env python3
"""Render a reviewed, multi-anchor dual-view plan without changing either source.

This is an offline prototype, not an automatic synchronization detector. A plan
must be checked against real board events before rendering. No network access.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile


class PlanError(ValueError):
    pass


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024*1024), b''):
            result.update(block)
    return result.hexdigest()


def cjk_font():
    candidates = ('/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/STHeiti Medium.ttc',
                  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
                  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
    return next((Path(path) for path in candidates if Path(path).is_file()), None)


def executable(name):
    found = shutil.which(name)
    if not found:
        found = next((str(p) for p in (Path('/opt/homebrew/bin') / name, Path('/usr/local/bin') / name)
                      if p.is_file()), None)
    if not found:
        raise PlanError(f"Missing {name}. Install FFmpeg before merging.")
    return found


def probe(path):
    result = subprocess.run([executable('ffprobe'), '-v', 'error', '-show_format', '-show_streams',
                             '-of', 'json', str(path)], check=True, capture_output=True, text=True)
    data = json.loads(result.stdout)
    videos = [s for s in data['streams'] if s['codec_type'] == 'video']
    if len(videos) != 1:
        raise PlanError('Exactly one video stream is required in each recording.')
    video = videos[0]
    if any(abs(float(d.get('rotation', 0))) > .01 for d in video.get('side_data_list', [])):
        raise PlanError('Rotated video needs a separately reviewed layout.')
    duration = float(video.get('duration') or data['format']['duration'])
    if not math.isfinite(duration) or duration <= 0:
        raise PlanError('Invalid video duration.')
    return dict(width=int(video['width']), height=int(video['height']), duration=duration,
                audio=any(s['codec_type'] == 'audio' for s in data['streams']))


def check_pair(own, opponent):
    if not own.get('date') or not own.get('mode'):
        raise PlanError('Missing match date or mode.')
    if any(own.get(key) != opponent.get(key) for key in ('date', 'mode')):
        raise PlanError('Recordings belong to different matches.')
    for side in ('left', 'right'):
        a, b = own.get(side, []), opponent.get(side, [])
        if len(a) != 3 or len(b) != 3:
            raise PlanError('Both lineups must contain three slots.')
        for first, second in zip(a, b):
            if first not in ('', '未识别') and second not in ('', '未识别') and first != second:
                raise PlanError('Conflicting lineups need review before pairing.')
    # Filenames and final perspective metadata alone cannot prove a whole clip.
    if own.get('recordingPerspective') != 'own' or opponent.get('recordingPerspective') != 'opponent':
        raise PlanError('Expected an own-view recording and an opponent-view recording.')


def rect(value):
    if not isinstance(value, list) or len(value) != 4 or not all(number(v) for v in value):
        raise PlanError('Crop must be [x, y, width, height] in normalized coordinates.')
    x, y, w, h = value
    if min(x, y) < 0 or min(w, h) <= 0 or x+w > 1.000001 or y+h > 1.000001:
        raise PlanError('Crop lies outside the image.')
    return value


def pixel_rect(value, width, height):
    x, y, w, h = rect(value)
    left, top = math.floor(x*width/2+1e-7)*2, math.floor(y*height/2+1e-7)*2
    right = min(width//2*2, math.ceil((x+w)*width/2-1e-7)*2)
    bottom = min(height//2*2, math.ceil((y+h)*height/2-1e-7)*2)
    if right-left < 2 or bottom-top < 2:
        raise PlanError('Crop is too small.')
    return left, top, right-left, bottom-top


def composition_rects(plan, width, height):
    layout = plan.get('composition')
    if not isinstance(layout, dict):
        raise PlanError('Review in-place hand and dice destinations before merging an older plan.')
    boxes = {key: rect(layout.get(key)) for key in ('opponentHand', 'opponentDice', 'ownDice')}
    hand, top, bottom = (boxes[k] for k in ('opponentHand', 'opponentDice', 'ownDice'))
    if hand[1]+hand[3] > .15 or hand[2] < .3:
        raise PlanError('Opponent hand must replace the top card-back strip, not the central board.')
    if any(box[0] < .9 or box[2] > .1 for box in (top, bottom)):
        raise PlanError('Dice must stay in the existing narrow right edge.')
    if abs(top[0]-bottom[0]) > .002 or abs(top[2]-bottom[2]) > .002:
        raise PlanError('Both dice groups must share the same right-edge column.')
    if top[1]+top[3] > bottom[1] or top[1]+top[3] > .54 or bottom[1] < .5:
        raise PlanError('Place opponent dice above own dice without overlap.')
    for dice in (top, bottom):
        if (hand[0] < dice[0]+dice[2] and hand[0]+hand[2] > dice[0] and
                hand[1] < dice[1]+dice[3] and hand[1]+hand[3] > dice[1]):
            # A reviewed strip of background beyond the hand may sit under
            # the upper dice column; never allow an unreviewed card overlap.
            background_only = (dice is top and layout.get('rightEdgeBackgroundOverlap') is True
                               and hand[0]+hand[2]-dice[0] <= .02)
            if not background_only:
                raise PlanError('Hand and dice destinations overlap.')
    return {key: pixel_rect(box, width, height) for key, box in boxes.items()}


def validate(plan, media, preview=False):
    if plan.get('schemaVersion') != 1 or (plan.get('status') != 'reviewed' and not preview):
        raise PlanError('Plan is not reviewed. Check match, views, layout and synchronization first.')
    check_pair(plan['own']['metadata'], plan['opponent']['metadata'])
    if plan['own']['sha256'] == plan['opponent']['sha256']:
        raise PlanError('The two sources must not be the same recording.')
    for key in ('own', 'opponent'):
        rect(plan[key]['viewport'])
    for key in ('opponentHand', 'opponentDice', 'ownDice'):
        rect(plan.get(key))
    composition_rects(plan, 1280, 720)
    confirmations = plan.get('confirmed', {})
    for key in ('sameMatch', 'ownBottomThroughout', 'opponentBottomThroughout', 'layout'):
        if confirmations.get(key) is not True:
            raise PlanError(f'Missing visual confirmation: {key}.')
    anchors = plan.get('anchors', [])
    if not 4 <= len(anchors) <= 128:
        raise PlanError('At least four distinct board-event anchors are required (maximum 128).')
    for anchor in anchors:
        for key in ('own', 'opponent'):
            if not number(anchor.get(key)) or not 0 <= anchor[key] < media[key]['duration']:
                raise PlanError('Anchor is outside its source recording.')
        if not str(anchor.get('event', '')).strip():
            raise PlanError('Each anchor needs a board-event description.')
    checks = plan.get('checks', [])
    used_checks = set()
    for first, last in zip(anchors, anchors[1:]):
        da, db = last['own']-first['own'], last['opponent']-first['opponent']
        if min(da, db) < .2 or max(da, db) > 30 or not .25 <= da/db <= 4:
            raise PlanError('Non-monotonic, sparse or extreme time mapping. Split at pauses/speed changes.')
        accepted = []
        for index, check in enumerate(checks):
            if not all(number(check.get(k)) for k in ('own', 'opponent')):
                raise PlanError('Invalid independent checkpoint.')
            if first['own'] < check['own'] < last['own']:
                predicted = first['opponent'] + (check['own']-first['own'])*db/da
                if abs(predicted-check['opponent']) > .2 or not str(check.get('event', '')).strip():
                    raise PlanError('Independent board-event checkpoint disagrees with the time map.')
                accepted.append(index)
        if not accepted and not preview:
            raise PlanError('Each interval needs an independent interior board-event checkpoint.')
        used_checks.update(accepted)
    if len(used_checks) != len(checks):
        raise PlanError('A checkpoint is outside the reviewed interval.')
    duration = anchors[-1]['own'] - anchors[0]['own']
    if preview and duration > 30:
        raise PlanError('Unverified layout previews are limited to 30 seconds.')
    return duration


def mapped_time(anchors, own_time):
    for first, last in zip(anchors, anchors[1:]):
        if first['own'] <= own_time <= last['own']:
            return first['opponent'] + (own_time-first['own'])*(last['opponent']-first['opponent'])/(last['own']-first['own'])
    raise PlanError('Cannot extrapolate unrecorded or unreviewed footage.')


def time_expression(anchors):
    """Inverse piecewise map, with actual source PTS preserved by trim."""
    expressions = []
    origin = anchors[0]['own']
    for first, last in zip(anchors, anchors[1:]):
        factor = (last['own']-first['own'])/(last['opponent']-first['opponent'])
        expressions.append(f"((PTS*TB-{first['opponent']:.9f})*{factor:.12f}+{first['own']-origin:.9f})/TB")
    result = expressions[-1]
    for index in range(len(expressions)-2, -1, -1):
        result = f"if(lt(PTS*TB,{anchors[index+1]['opponent']:.9f}),{expressions[index]},{result})"
    return result


def crop_filter(box):
    x, y, w, h = box
    return f'crop={w}:{h}:{x}:{y}'


def filter_graph(plan, media, preview_label=None):
    anchors = plan['anchors']
    first, last = anchors[0], anchors[-1]
    crops = {key: pixel_rect(plan[key]['viewport'], media[key]['width'], media[key]['height'])
             for key in ('own', 'opponent')}
    own, opponent = crops['own'], crops['opponent']
    hand = pixel_rect(plan['opponentHand'], opponent[2], opponent[3])
    dice = pixel_rect(plan['opponentDice'], opponent[2], opponent[3])
    own_dice = pixel_rect(plan['ownDice'], own[2], own[3])
    width = 1280
    height = round(width*own[3]/own[2]/2)*2
    if not 500 <= height <= 1000:
        raise PlanError('Unsupported game viewport aspect ratio.')
    targets = composition_rects(plan, width, height)
    # Replacing existing UI regions keeps the original board size. Refuse a
    # layout that stretches the cards or dice into a different shape.
    for key, source in (('opponentHand', hand), ('opponentDice', dice), ('ownDice', own_dice)):
        target = targets[key]
        distortion = (target[2]/target[3])/(source[2]/source[3])
        if not .8 <= distortion <= 1.25:
            raise PlanError(f'{key} destination distorts its source; review both crop rectangles.')
    graph = [
        f"[0:v]trim=start={first['own']}:end={last['own']},setpts=PTS-STARTPTS,{crop_filter(own)},"
        f"setsar=1,fps=30,split=2[ownBoard][ownDice]",
        f"[ownBoard]scale={width}:{height},setsar=1[base]",
        f"[1:v]trim=start={first['opponent']}:end={last['opponent']},setpts='{time_expression(anchors)}',"
        f"{crop_filter(opponent)},setsar=1,fps=30,split=2[otherHand][otherDice]",
    ]
    base = 'base'
    for key, source_label, source in (('opponentHand', 'otherHand', hand),
                                       ('opponentDice', 'otherDice', dice), ('ownDice', 'ownDice', own_dice)):
        x, y, w, h = targets[key]
        layer, output = key+'Layer', key+'Composite'
        graph += [f"[{source_label}]{crop_filter(source)},scale={w}:{h},setsar=1[{layer}]",
                  f"[{base}][{layer}]overlay={x}:{y}:eof_action=endall:shortest=1[{output}]"]
        base = output
    # The filter runs in the private staging directory. Text files avoid treating
    # labels or source paths as filter syntax, and no shell command is evaluated.
    font = cjk_font()
    font_option = f"fontfile='{font}':" if font else ''
    if preview_label:
        graph.append(f"[{base}]drawtext={font_option}textfile={preview_label}:expansion=none:fontcolor=white:"
                     f"fontsize=14:box=1:boxcolor=black@0.55:boxborderw=4:x=12:y=h-100[video]")
    else:
        graph.append(f"[{base}]null[video]")
    if media['own']['audio']:
        graph.append(f"[0:a:0]atrim=start={first['own']}:end={last['own']},asetpts=PTS-STARTPTS[audio]")
    return ';\n'.join(graph), (width, height)


def create_plan(own, opponent, own_metadata, opponent_metadata, output):
    sources = {}
    for key, path, metadata in (('own', own, own_metadata), ('opponent', opponent, opponent_metadata)):
        path = Path(path).resolve(strict=True)
        sources[key] = dict(path=str(path), sha256=digest(path), media=probe(path),
                            metadata=json.loads(Path(metadata).read_text()), viewport=None)
    check_pair(sources['own']['metadata'], sources['opponent']['metadata'])
    plan = dict(schemaVersion=1, status='needsReview', **sources, opponentHand=None, opponentDice=None, ownDice=None,
                composition=dict(opponentHand=None, opponentDice=None, ownDice=None),
                confirmed=dict(sameMatch=False, ownBottomThroughout=False, opponentBottomThroughout=False, layout=False),
                anchors=[], checks=[])
    with Path(output).open('x') as handle:
        json.dump(plan, handle, ensure_ascii=False, indent=2)


def render(plan, output, preview=False):
    output = Path(output).absolute()
    receipt = output.with_suffix('.merge.json')
    if output.suffix.lower() != '.mp4' or output.exists() or receipt.exists():
        raise PlanError('Choose a new .mp4 output; existing files are never overwritten.')
    paths = {key: Path(plan[key]['path']).resolve(strict=True) for key in ('own', 'opponent')}
    if paths['own'] == paths['opponent'] or output.resolve() in paths.values():
        raise PlanError('Source and output paths must be distinct.')
    media = {key: probe(path) for key, path in paths.items()}
    duration = validate(plan, media, preview=preview)
    for key, path in paths.items():
        if digest(path) != plan[key]['sha256']:
            raise PlanError('Source changed since the plan was reviewed.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.dual-view-', dir=output.parent) as directory:
        staging = Path(directory)
        title = '布局预览 · 同步待核对'
        if not cjk_font():
            title = 'Preview | Sync unverified'
        (staging/'preview.txt').write_text(title, encoding='utf-8')
        graph, dimensions = filter_graph(plan, media, 'preview.txt' if preview else None)
        (staging/'filter.txt').write_text(graph, encoding='utf-8')
        command = [executable('ffmpeg'), '-hide_banner', '-nostdin', '-loglevel', 'warning', '-n',
                   '-i', str(paths['own']), '-i', str(paths['opponent']), '-filter_complex_threads', '2',
                   '-filter_complex_script', 'filter.txt', '-map', '[video]']
        if media['own']['audio']:
            command += ['-map', '[audio]', '-c:a', 'aac', '-b:a', '192k']
        command += ['-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p',
                    '-threads', '2', '-t', str(duration), '-movflags', '+faststart', 'merged.mp4']
        subprocess.run(command, cwd=staging, check=True)
        result = probe(staging/'merged.mp4')
        if abs(result['duration']-duration) > .12 or (result['width'], result['height']) != dimensions:
            raise PlanError('Rendered duration or dimensions disagree with the reviewed plan.')
        subprocess.run([executable('ffmpeg'), '-v', 'error', '-xerror', '-i', str(staging/'merged.mp4'),
                        '-f', 'null', '-'], check=True, capture_output=True)
        # Recheck sources, then publish without clobbering another writer's file.
        for key, path in paths.items():
            if digest(path) != plan[key]['sha256']:
                raise PlanError('Source changed during rendering.')
        audit = dict(schemaVersion=1, synchronization='unverified-preview' if preview else 'human-reviewed-multiple-events',
                     sourceHashes={k: plan[k]['sha256'] for k in paths},
                     anchors=plan['anchors'], checks=plan['checks'],
                     layout={k: plan[k] for k in ('opponentHand', 'opponentDice', 'ownDice', 'composition')},
                     viewports={k: plan[k]['viewport'] for k in paths},
                     sourceRanges={k: [plan['anchors'][0][k], plan['anchors'][-1][k]] for k in paths},
                     omittedPrefix={k: plan['anchors'][0][k] for k in paths},
                     omittedSuffix={k: media[k]['duration']-plan['anchors'][-1][k] for k in paths},
                     audio='own' if media['own']['audio'] else 'none', media=result,
                     outputSHA256=digest(staging/'merged.mp4'), fullMatch=False)
        (staging/'receipt.json').write_text(json.dumps(audit, ensure_ascii=False, indent=2))
        # Same-filesystem hardlinks provide exclusive creation without replacing
        # an existing path, including a symlink created while FFmpeg was running.
        output.hardlink_to(staging/'merged.mp4')
        receipt.hardlink_to(staging/'receipt.json')
    return audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('prepare', help='Create an unreviewed plan; never guesses synchronization.')
    for option in ('own', 'opponent', 'own-metadata', 'opponent-metadata', 'output'):
        prepare.add_argument('--'+option, required=True)
    for name, help_text in (('render', 'Render only the reviewed interval into a new video.'),
                            ('preview', 'Create a watermarked layout preview (30 seconds maximum), not a verified merge.')):
        encode = commands.add_parser(name, help=help_text)
        encode.add_argument('--plan', required=True)
        encode.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            create_plan(args.own, args.opponent, args.own_metadata, args.opponent_metadata, args.output)
        else:
            print(json.dumps(render(json.loads(Path(args.plan).read_text()), args.output, preview=args.command == 'preview'), ensure_ascii=False))
    except (PlanError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(2, f'Cannot merge: {error}\n')


if __name__ == '__main__':
    main()
