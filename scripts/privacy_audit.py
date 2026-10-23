#!/usr/bin/env python3
"""Read-only release checks; report categories and locations, never secret values."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess

PATTERNS = {
    "credential": rb"(?:\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bsk-(?!(?:ecdsa|ssh)-)[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{40,})",
    "local-home": rb"/(?:Users|home)/(?!runner(?:/|\b))[A-Za-z0-9_.-]+",
    "private-network": rb"\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b",
    "account-receipt": rb"(?:\bBV1[1-9A-HJ-NP-Za-km-z]{9}\b|\b(?:UID|uid|mid|SESSDATA|bili_jct)\s*[\"':= ]+\d{5,})",
    "local-account-description": rb"for user [`\"][A-Za-z0-9_.-]+[`\"]",
}
EMAIL = re.compile(rb'[A-Za-z0-9_.+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')
SKIP = {'.git', '.build', '.build-tools', '.venv', '__pycache__', 'dist', '.audit', '.incoming'}
PRIVATE_DIRS = {'.private', 'recordings', 'test-captures', 'Signing', 'Keychains'}
PRIVATE_NAMES = {'AGENTS.md', '.DS_Store', 'settings.json', 'identity.json', 'credentials', 'cookies.json'}
PRIVATE_SUFFIXES = {'.mp4', '.mov', '.mkv', '.p12', '.pfx', '.key', '.pem', '.keychain-db', '.log'}


def dependency_reviews():
    entries = json.loads(Path(__file__).with_name('dependency_privacy_reviews.json').read_text())
    return {location: {(item['category'], digest) for digest in item['match_sha256']}
            for location, item in entries.items()}


def findings_for_data(data, artifact=False, deny=(), reviewed=()):
    result = [kind for kind, pattern in PATTERNS.items()
              if any((kind, hashlib.sha256(match.group()).hexdigest()) not in reviewed
                     for match in re.finditer(pattern, data))]
    if any(value and value in data for value in deny):
        result.append('private-marker')
    if not artifact and b'\0' not in data[:8192]:
        domains = [match.group(1).lower() for match in EMAIL.finditer(data)]
        if any(domain not in (b'users.noreply.github.com', b'example.com', b'example.org', b'example.invalid') for domain in domains):
            result.append('personal-email')
    return result


def png_metadata(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return []
    offset, result = 8, []
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]
        if offset + length + 12 > len(data):
            return ['invalid-png']
        if kind in (b'tEXt', b'iTXt', b'zTXt', b'eXIf'):
            result.append('image-metadata')
        offset += length + 12
        if kind == b'IEND':
            break
    return sorted(set(result))


def private_path(path, artifact=False):
    public_ca = artifact and path.as_posix().endswith('/certifi/cacert.pem')
    return (any(part in PRIVATE_DIRS or part.endswith('.review') for part in path.parts)
            or path.name in PRIVATE_NAMES or path.name.startswith(('.env', '._'))
            or (path.suffix.lower() in PRIVATE_SUFFIXES and not public_ca))


def scan_tree(root, artifact=False, deny=(), reviews=None):
    root = Path(root).resolve(strict=True)
    findings, count = [], 0
    paths = []
    for directory, children, files in os.walk(root, followlinks=False):
        if not artifact:
            children[:] = [name for name in children if name not in SKIP]
        paths.extend(Path(directory)/name for name in files)
        paths.extend(Path(directory)/name for name in children if (Path(directory)/name).is_symlink())
    for path in sorted(paths):
        relative = path.relative_to(root)
        if not artifact and any(part in SKIP for part in relative.parts):
            continue
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (ValueError, FileNotFoundError, RuntimeError):
                findings.append(dict(path=relative.as_posix(), category='external-or-broken-symlink'))
            continue
        if not path.is_file():
            continue
        count += 1
        if private_path(relative, artifact):
            findings.append(dict(path=relative.as_posix(), category='private-file'))
        data = path.read_bytes()
        reviewed = (reviews or {}).get(relative.as_posix(), ()) if artifact else ()
        for category in findings_for_data(data, artifact, deny, reviewed) + png_metadata(data):
            findings.append(dict(path=relative.as_posix(), category=category))
    return dict(files=count, findings=findings)


def scan_history(repo, deny=()):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args])
    objects = git('rev-list', '--objects', '--all').decode().splitlines()
    findings, blobs = [], 0
    for line in objects:
        oid, _, path = line.partition(' ')
        if not path or git('cat-file', '-t', oid).strip() != b'blob':
            continue
        data = git('cat-file', 'blob', oid)
        blobs += 1
        categories = findings_for_data(data, deny=deny) + png_metadata(data)
        if private_path(Path(path)):
            categories.append('private-file')
        for category in categories:
            findings.append(dict(blob=oid, path=path, category=category))
    commits = git('log', '--all', '--format=%ae%n%ce%n%B').strip()
    for category in findings_for_data(commits, deny=deny):
        findings.append(dict(path='commit-metadata', category=category))
    return dict(blobs=blobs, findings=findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', nargs='?', type=Path)
    parser.add_argument('--tree', type=Path)
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--deny-file', type=Path, help='Local JSON list of private strings; never committed')
    parser.add_argument('--review-dependencies', action='store_true', help='Apply exact, documented upstream matches to artifact files only')
    args = parser.parse_args()
    if sum(value is not None for value in (args.repository, args.tree, args.artifact)) != 1:
        parser.error('Choose a repository history, --tree, or --artifact')
    deny = [value.encode() for value in json.loads(args.deny_file.read_text())] if args.deny_file else []
    if args.review_dependencies and not args.artifact:
        parser.error('Dependency reviews apply only to --artifact')
    reviews = dependency_reviews() if args.review_dependencies else None
    report = scan_history(args.repository, deny) if args.repository else scan_tree(args.tree or args.artifact, artifact=args.artifact is not None, deny=deny, reviews=reviews)
    report['limits'] = 'Pattern checks are not a guarantee. Review image pixels, archives and hosted content separately.'
    print(json.dumps(report, indent=2))
    return bool(report['findings'])


if __name__ == '__main__':
    raise SystemExit(main())
