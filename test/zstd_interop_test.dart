@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

/// Verifies both directions against the independent system Zstandard codec.
void main() {
  test('reads reference entropy modes and writes independently decodable frames', () async {
    final Directory directory = Directory.systemTemp.createTempSync('zcodec-zstd-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final Random random = Random(8878);
    final List<Uint8List> samples = [
      Uint8List(0),
      Uint8List.fromList([42]),
      Uint8List(180000),
      Uint8List.fromList(List.generate(200003, (_) => random.nextInt(256))),
      Uint8List.fromList(List.generate(400009, (index) => (index ~/ 259) & 255)),
      utf8.encode(List.generate(4000, (index) => 'Illustrator layer ${index % 131}: courbe, couleur, transparence.\n').join()),
    ];
    for (final Uint8List sample in samples) {
      final File original = File('${directory.path}/input')..writeAsBytesSync(sample);
      for (final String level in ['--fast=3', '-3', '-9', '-19']) {
        final ProcessResult reference = await Process.run('zstd', [level, '-q', '-c', original.path], stdoutEncoding: null);
        expect(reference.exitCode, 0, reason: reference.stderr.toString());
        expect(ZstdDecoder(maxOutputBytes: sample.length).convert(reference.stdout as List<int>), sample, reason: '$level / ${sample.length}');
      }
      for (final int level in [0, 1, 6, 9]) {
        final Uint8List encoded = ZstdCodec(level: level).encode(sample);
        final File compressed = File('${directory.path}/ours.zst')..writeAsBytesSync(encoded);
        final ProcessResult reference = await Process.run('zstd', ['-q', '-d', '-c', compressed.path], stdoutEncoding: null);
        expect(reference.exitCode, 0, reason: '$level / ${sample.length}: ${reference.stderr}');
        expect(reference.stdout, sample);
        expect(ZstdDecoder(maxOutputBytes: sample.length).convert(encoded), sample);
      }
    }
  }, skip: !_available() ? 'Requires the zstd reference codec' : false);

  test('decodes raw and trained dictionaries with isolated caller storage', () async {
    final Directory directory = Directory.systemTemp.createTempSync('zcodec-dictionary-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final List<String> training = [];
    for (int index = 0; index < 100; index++) {
      final File sample = File('${directory.path}/sample-$index');
      sample.writeAsStringSync(List.generate(20, (line) => 'Illustrator layer ${index % 11}, point $line: red green blue curve transform ${index * line}.\n').join());
      training.add(sample.path);
    }
    final File trained = File('${directory.path}/trained');
    final ProcessResult trainer = await Process.run('zstd', ['--train', '--maxdict=4096', '-q', '-o', trained.path, ...training]);
    expect(trainer.exitCode, 0, reason: trainer.stderr.toString());
    final File raw = File('${directory.path}/raw')..writeAsBytesSync(File(training.first).readAsBytesSync());
    final Uint8List source = utf8.encode(List.generate(30, (line) => 'Illustrator layer 0, point $line: red green blue curve transform 0.\n').join());
    final File original = File('${directory.path}/input')..writeAsBytesSync(source);
    for (final File dictionary in [raw, trained]) {
      final ProcessResult compressed = await Process.run('zstd', ['-q', '-19', '-D', dictionary.path, '-c', original.path], stdoutEncoding: null);
      expect(compressed.exitCode, 0, reason: compressed.stderr.toString());
      final List<int> encoded = compressed.stdout as List<int>;
      final Uint8List callerBytes = dictionary.readAsBytesSync();
      final ZstdDecoder decoder = ZstdDecoder(dictionary: callerBytes, maxOutputBytes: source.length);
      callerBytes.fillRange(0, callerBytes.length, 0);
      expect(decoder.convert(encoded), source);
      expect(() => ZstdDecoder().convert(encoded), throwsA(isA<ZCodecException>()));
      if (dictionary == trained) {
        final Uint8List wrongIdentifier = dictionary.readAsBytesSync();
        wrongIdentifier[4] ^= 1;
        expect(() => ZstdDecoder(dictionary: wrongIdentifier).convert(encoded), throwsA(isA<ZCodecException>()));
        expect(() => ZstdDecoder(dictionary: wrongIdentifier.sublist(0, 8)).convert(encoded), throwsA(isA<ZCodecException>()));
      }
    }
  }, skip: !_available() ? 'Requires the zstd reference codec' : false);
}

/// Checks availability without treating a skipped interoperability test as proof.
bool _available() {
  try {
    return Process.runSync('zstd', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
