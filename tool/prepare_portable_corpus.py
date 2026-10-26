#!/usr/bin/env python3
"""Embed verified corpus inputs/results into an ignored Dart Web test runner."""
import base64
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
report = json.loads((ROOT / 'build/compression-corpus-report.json').read_text())
for entry in report:
    if entry['status'] not in ('pass', 'rejected-invalid', 'output-limit'):
        raise SystemExit(f'Corpus result must pass before Web validation: {entry["file"]}')
    root = ROOT / ('build/corpus/xz-reference/tests/files' if entry['format'] == 'xz'
                   else 'build/corpus/bzip2-reference')
    data = (root / entry['file']).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry['encoded_sha256']:
        raise SystemExit(f'Corpus changed: {entry["file"]}')
    entry['bytes'] = base64.b64encode(data).decode('ascii')
runner = r"""
import 'dart:convert';
import 'package:zcodec/zcodec.dart';
import 'package:zcodec/src/crypto.dart';
void main() {
  final cases = jsonDecode(r'''PAYLOAD''') as List<dynamic>;
  int count = 0;
  for (final dynamic item in cases) {
    final entry = item as Map<String, dynamic>;
    final bool xz = entry['format'] == 'xz';
    final String name = entry['file'] as String;
    final ByteCodec codec = xz
        ? const XzCodec(maxOutputBytes: 134217728)
        : Bzip2Codec(
            maxOutputBytes: name == 'commons-compress/zip64support.tar.bz2'
                ? 8388608 : 134217728,
            allowTrailingBytes: name == 'lbzip2/trash.bz2' || name == 'lbzip2/gap.bz2');
    bool rejected = false;
    try {
      final bytes = codec.decode(base64Decode(entry['bytes'] as String));
      if (entry['status'] != 'pass') throw StateError('Unexpected acceptance: $name');
      final String digest = (Sha256()..add(bytes)).close()
          .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (!(entry['detail'] as String).endsWith(digest)) throw StateError('Mismatch: $name');
    } on ZCodecException catch (error) {
      rejected = true;
      if (entry['status'] == 'output-limit' && error.message != entry['detail']) {
        throw StateError('Wrong output-limit rejection: $name: $error');
      }
    }
    if (rejected && entry['status'] == 'pass') throw StateError('Unexpected rejection: $name');
    count++;
  }
  print('$count portable corpus cases passed');
}
"""
(ROOT / 'build/corpus_portable.dart').write_text(runner.replace('PAYLOAD', json.dumps(report)))
print('Prepared build/corpus_portable.dart')
