#!/usr/bin/env python3
"""Stage a reviewed source snapshot, without history or changes to the release tree."""
import argparse
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile

from privacy_audit import scan_tree

PREFIXES = ('Sources/', 'Tests/', 'Assets/', 'worker/')
FILES = {'Package.swift', 'scripts/merge_dual_view.py', 'scripts/prepare_assets.py',
         'scripts/evaluate_video_reviews.py', 'scripts/probe_video.swift', 'scripts/make_icon.swift'}


def allowed(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or name.startswith('worker/tests/fixtures/'):
        return False
    if path.name in ('AGENTS.md', 'test_portrait_regression.py', 'test_privacy_audit.py', 'test_release_source.py'):
        return False
    return name in FILES or name.startswith(PREFIXES)


def stage(source, output):
    source, output = Path(source).resolve(strict=True), Path(output).absolute()
    if output.exists():
        raise ValueError('Output already exists; choose a new staging directory')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args])
    if git('status', '--porcelain').strip():
        raise ValueError('Commit or set aside source changes before exporting a snapshot')
    archive = git('archive', '--format=tar', 'HEAD')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.source-stage-', dir=output.parent) as directory:
        root = Path(directory)/'candidate'
        root.mkdir()
        files = []
        with tarfile.open(fileobj=io.BytesIO(archive)) as handle:
            for item in handle:
                if not allowed(item.name):
                    continue
                if item.isdir():
                    continue
                if not item.isfile():
                    raise ValueError('Source snapshot contains a non-regular entry')
                target = root/item.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(handle.extractfile(item).read())
                target.chmod(item.mode & 0o755)
                files.append(item.name)
        if not files:
            raise ValueError('No supported source files were found')
        report = scan_tree(root)
        if report['findings']:
            print(json.dumps(report, indent=2))
            raise ValueError('Private data detected; no snapshot was staged')
        root.rename(output)
    return dict(files=len(files), instructions='Review staged differences manually; release configuration, updater and privacy checks must be preserved. No files were applied or committed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(stage(args.source, args.output), indent=2))


if __name__ == '__main__':
    main()
