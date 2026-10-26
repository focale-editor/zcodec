@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  test('XZ independently reads and writes system liblzma streams', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zcodec-xz-');
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
    for (final XzCheck check in XzCheck.values) {
      for (final Uint8List sample in samples) {
        final File file = File('${dir.path}/input')..writeAsBytesSync(sample);
        for (final List<String> filters in [
          <String>[],
          ['--delta=dist=3', '--lzma2=dict=64KiB'],
          ['--lzma2=dict=64KiB,lc=0,lp=2,pb=4'],
          ['--x86=start=4294967295', '--lzma2=dict=64KiB'],
          ['--powerpc', '--lzma2=dict=64KiB'],
          ['--arm64=start=4294963200', '--lzma2=dict=64KiB'],
        ]) {
          final ProcessResult encoded = await Process.run('xz', ['--check=${check.name}', '--block-size=150000', ...filters, '-c', file.path], stdoutEncoding: null);
          expect(encoded.exitCode, 0, reason: encoded.stderr.toString());
          expect(const XzCodec().decode(encoded.stdout as List<int>), sample, reason: '${check.name}, ${sample.length}, $filters');
        }
        final Uint8List ours = XzCodec(check: check, blockSize: 150000).encode(sample);
        File('${dir.path}/ours.xz').writeAsBytesSync(ours);
        final ProcessResult decoded = await Process.run('xz', ['-d', '-c', '${dir.path}/ours.xz'], stdoutEncoding: null);
        expect(decoded.exitCode, 0, reason: decoded.stderr.toString());
        expect(decoded.stdout, sample);
        expect(const XzCodec().decode(ours), sample);
      }
    }
  }, skip: !_available('xz') ? 'Requires the xz command-line reference codec' : false);
}

/// Whether the independent system codec is installed.
bool _available(String command) {
  try {
    return Process.runSync(command, ['--version'], stdoutEncoding: null, stderrEncoding: null).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
