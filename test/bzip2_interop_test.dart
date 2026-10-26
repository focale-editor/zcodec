@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  test('BZIP2 independently reads and writes system bzip2 streams', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zcodec-bzip-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final Random random = Random(171);
    final List<Uint8List> samples = [
      Uint8List(0),
      Uint8List.fromList([42]),
      Uint8List.fromList(List.generate(10000, (i) => i & 255)),
      Uint8List.fromList(List.generate(100003, (_) => random.nextInt(256))),
      Uint8List.fromList(List.generate(2000000, (i) => (i ~/ 259) & 255)),
      Uint8List(500000),
    ];
    for (final int size in [1, 9]) {
      for (final Uint8List sample in samples) {
        final File file = File('${dir.path}/input')..writeAsBytesSync(sample);
        final ProcessResult encoded = await Process.run('bzip2', ['-$size', '-c', file.path], stdoutEncoding: null);
        expect(encoded.exitCode, 0);
        expect(const Bzip2Codec().decode(encoded.stdout as List<int>), sample);
        final Uint8List ours = Bzip2Codec(blockSize: size).encode(sample);
        File('${dir.path}/ours.bz2').writeAsBytesSync(ours);
        final ProcessResult decoded = await Process.run('bzip2', ['-d', '-c', '${dir.path}/ours.bz2'], stdoutEncoding: null);
        expect(decoded.exitCode, 0, reason: decoded.stderr.toString());
        expect(decoded.stdout, sample);
        expect(const Bzip2Codec().decode(ours), sample);
      }
    }
  }, skip: !_available('bzip2') ? 'Requires the bzip2 command-line reference codec' : false);
}

/// Whether the independent system codec is installed.
bool _available(String command) {
  try {
    return Process.runSync(command, ['--version'], stdoutEncoding: null, stderrEncoding: null).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
