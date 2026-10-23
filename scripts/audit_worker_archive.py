#!/usr/bin/env python3
"""Inspect frozen Python code without importing or executing the worker."""
import argparse
import json
import marshal
from pathlib import Path
import types
import zipfile

from PyInstaller.archive.readers import CArchiveReader
from privacy_audit import dependency_reviews, findings_for_data


def inspect_code(value, location, findings, reviewed=()):
    if isinstance(value, types.CodeType):
        inspect_code(value.co_filename, location + ':filename', findings)
        for item in value.co_consts:
            inspect_code(item, location, findings, reviewed)
    elif isinstance(value, (str, bytes)):
        data = value.encode() if isinstance(value, str) else value
        for category in findings_for_data(data, artifact=True, reviewed=reviewed):
            findings.add((location, category))
    elif isinstance(value, (tuple, list, frozenset)):
        for item in value:
            inspect_code(item, location, findings, reviewed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('worker')
    args = parser.parse_args()
    archive = CArchiveReader(args.worker)
    findings, modules = set(), 0
    reviews = dependency_reviews()
    for name, entry in archive.toc.items():
        kind = entry[-1]
        if kind == 'z':
            embedded = archive.open_embedded_archive(name)
            for module in embedded.toc:
                inspect_code(embedded.extract(module), module, findings, reviews.get(module, ()))
                modules += 1
        elif kind in ('s', 'm', 'M'):
            inspect_code(marshal.loads(archive.extract(name)), name, findings)
            modules += 1
    library = Path(args.worker).parent / '_internal' / 'base_library.zip'
    if not library.is_file():
        raise RuntimeError('Missing bundled Python base library')
    with zipfile.ZipFile(library) as base:
        for name in base.namelist():
            if name.endswith('.pyc'):
                inspect_code(marshal.loads(base.read(name)[16:]), 'base_library/' + name, findings)
                modules += 1
    if not modules:
        raise RuntimeError('No Python modules were inspected')
    print(json.dumps(dict(modules=modules, findings=[dict(location=k, category=v) for k,v in sorted(findings)]), indent=2))
    return bool(findings)


if __name__ == '__main__':
    raise SystemExit(main())
