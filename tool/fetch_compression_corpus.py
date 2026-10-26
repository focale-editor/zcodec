#!/usr/bin/env python3
"""Fetch pinned upstream codec fixtures into ignored storage and verify hashes."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / 'tool/compression_corpus_manifest.json').read_text())
for source in manifest['sources']:
    destination = ROOT / source['checkout']
    if not destination.exists():
        destination.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(destination)], check=True)
        subprocess.run(['git', '-C', str(destination), 'fetch', '-q', '--depth=1',
                        source['url'], source['commit']], check=True)
        subprocess.run(['git', '-C', str(destination), 'checkout', '-q', '--detach',
                        'FETCH_HEAD'], check=True)
    actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != source['commit']:
        raise SystemExit(f'Unexpected checkout revision in {destination}: {actual}')
    for entry in manifest['files']:
        if entry['format'] != source['format']:
            continue
        data = (destination / source['fixtures'] / entry['file']).read_bytes()
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise SystemExit(f'Checksum mismatch: {entry["file"]}')
print(f'{len(manifest["files"])} pinned fixtures verified')
