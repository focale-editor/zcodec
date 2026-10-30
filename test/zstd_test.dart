import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

/// Tests portable framing, limits, corruption handling and converter reuse.
void main() {
  final Uint8List sample = utf8.encode(List.generate(500, (index) => 'Layer ${index % 9}: courbe Bézier\n').join());

  test('encodes useful matches and round-trips all compression efforts', () {
    for (int level = 0; level <= 9; level++) {
      final ZstdCodec codec = ZstdCodec(level: level, maxOutputBytes: sample.length);
      final Uint8List encoded = codec.encode(sample);
      expect(codec.decode(encoded), sample);
      if (level > 0) {
        expect(encoded.length, lessThan(sample.length ~/ 3));
      }
    }
  });

  test('decodes reference Huffman and FSE blocks on every platform', () {
    final Uint8List expected = utf8.encode(List.generate(4000, (index) => 'Illustrator layer ${index % 131}: courbe, couleur, transparence.\n').join());
    // Generated with the independent zstd 1.5.7 command-line encoder, level 19.
    final Uint8List reference = base64.decode(
      'KLUv/QRo/AcAkg0jFpCrDRgaiSUsK9dVednd3b37iO9/cAJ1bWxramloZ2a3sj5/r8/j7/a/3sW1pZWFdWX1qjevJp69unk18ezFzauJZ69tXk08e2nzauLZK5tXE89e2LyaePa65tXEs5c1ryae/c2riWcHhgRZkmQ0zmKkJxASlChCciSIQQKigpREhhIk5jHS40CKUgSAhaghsNz+swbQlaY1EkAQ+EcQ+E8QePz9M8nkN9tSCEIIIQkhhEgIIQQhhBCEEEIQOZvyIJmYTA6IZEQkBohERCQGRCIiEgNEIiISAyIREYkBIhERiQGRiIiEAZGIiLDgTQwQEAgILL/s7qlKAKkCVQAAAAEAiT6r6bkGAnvhDbo=',
    );
    expect(ZstdDecoder(maxOutputBytes: expected.length).convert(reference), expected);
  });

  test('concatenates frames and skips bounded metadata', () {
    final Uint8List first = const ZstdCodec().encode([1, 2, 3]);
    final Uint8List second = const ZstdCodec().encode([4, 5]);
    final List<int> joined = [...first, 0x50, 0x2a, 0x4d, 0x18, 2, 0, 0, 0, 99, 98, ...second];
    expect(ZstdDecoder(maxOutputBytes: 5).convert(joined), [1, 2, 3, 4, 5]);
    expect(() => ZstdDecoder(maxOutputBytes: 4).convert(joined), throwsA(isA<ZCodecException>()));
    expect(() => ZstdDecoder().convert([...joined, 0]), throwsA(isA<ZCodecException>()));
  });

  test('rejects every truncated suffix of a checksum-bearing compressed frame', () {
    final Uint8List encoded = const ZstdCodec().encode(sample);
    for (int length = 0; length < encoded.length; length++) {
      expect(() => ZstdDecoder().convert(encoded.sublist(0, length)), throwsA(isA<ZCodecException>()), reason: 'length=$length');
    }
    encoded[encoded.length - 1] ^= 1;
    expect(() => ZstdDecoder().convert(encoded), throwsA(isA<ZCodecException>()));
  });

  test('enforces input, decoded size and advertised window limits', () {
    final Uint8List encoded = const ZstdCodec().encode(sample);
    expect(() => ZstdDecoder(maxInputBytes: encoded.length - 1).convert(encoded), throwsA(isA<ZCodecException>()));
    expect(() => ZstdDecoder(maxOutputBytes: sample.length - 1).convert(encoded), throwsA(isA<ZCodecException>()));
    expect(() => ZstdDecoder(maxWindowBytes: 1024).convert(encoded), throwsA(isA<ZCodecException>()));
    expect(() => ZstdDecoder(maxOutputBytes: -1).convert(encoded), throwsArgumentError);
    expect(() => const ZstdEncoder(level: 10).convert(sample), throwsArgumentError);
    expect(ZstdDecoder(maxOutputBytes: 0).convert(const ZstdCodec().encode([])), isEmpty);
  });

  test('supports byte-at-a-time chunked decoding and base64 composition', () {
    final List<int> output = [];
    final ByteConversionSink sink = ZstdDecoder().startChunkedConversion(ByteConversionSink.withCallback(output.addAll));
    for (final int byte in const ZstdCodec().encode(sample)) {
      sink.add([byte]);
    }
    sink.close();
    expect(output, sample);
    final Codec<List<int>, String> codec = const ZstdCodec().fuse(base64);
    expect(codec.decode(codec.encode(sample)), sample);
  });

  test('bounds chunk storage before close and never emits an invalid frame', () {
    final List<int> output = [];
    final ByteConversionSink sink = ZstdDecoder(maxInputBytes: 4).startChunkedConversion(ByteConversionSink.withCallback(output.addAll));
    sink.add([0x28, 0xb5, 0x2f, 0xfd]);
    expect(() => sink.add([0]), throwsA(isA<ZCodecException>()));
    sink.close();
    expect(output, isEmpty);
    expect(() => sink.add([]), throwsStateError);
    final ByteConversionSink corrupt = ZstdDecoder().startChunkedConversion(ByteConversionSink.withCallback(output.addAll));
    corrupt.add([0x28, 0xb5, 0x2f, 0xfd]);
    expect(corrupt.close, throwsA(isA<ZCodecException>()));
    expect(output, isEmpty);
  });

  test('handles bounded malformed frames without leaking implementation errors', () {
    final Random random = Random(8878);
    final ZstdDecoder decoder = ZstdDecoder(maxOutputBytes: 262144, maxWindowBytes: 262144);
    final Uint8List valid = const ZstdCodec().encode(sample);
    for (int index = 0; index < 400; index++) {
      final Uint8List malformed = index.isEven ? Uint8List.fromList([...valid]) : Uint8List.fromList([0x28, 0xb5, 0x2f, 0xfd, ...List.generate(64, (_) => random.nextInt(256))]);
      malformed[random.nextInt(malformed.length)] ^= 1 << random.nextInt(8);
      try {
        expect(decoder.convert(malformed).length, lessThanOrEqualTo(262144));
      } on ZCodecException {
        // Malformed data is a format failure, never an indexing/state exception.
      }
    }
  });
}
