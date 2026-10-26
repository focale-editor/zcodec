import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/src/io.dart';
import 'package:zcodec/zcodec.dart';

/// Generates deterministic mixed literals and long repeated sections.
Uint8List _sample(int size) => Uint8List.fromList(List.generate(size, (i) => i % 1000 < 700 ? (i ~/ 1000) & 255 : (i * 43) & 255));

void main() {
  final List<ByteCodec> codecs = [const Bzip2Codec(blockSize: 1), const XzCodec(blockSize: 8192), const XzCodec(check: XzCheck.sha256, blockSize: 8192)];
  for (final ByteCodec codec in codecs) {
    final String name = '${codec.runtimeType}${codec is XzCodec ? '/${codec.check.name}' : ''}';
    group(name, () {
      test('empty, short, repetitive, random and block boundaries', () {
        final Random random = Random(329);
        for (final Uint8List raw in [
          Uint8List(0),
          Uint8List.fromList([0]),
          _sample(8193),
          _sample(160001),
          Uint8List.fromList(List.generate(8192, (_) => random.nextInt(256))),
        ]) {
          final Uint8List encoded = codec.encode(raw);
          expect(codec.decode(encoded), raw);
        }
        final Uint8List repeated = Uint8List(100000);
        expect(codec.encode(repeated).length, lessThan(repeated.length ~/ 40));
      });
      test('fragmented encoding/decoding owns caller buffers and emits before close', () {
        final Uint8List raw = _sample(200001);
        final BytesBuilder compressed = BytesBuilder();
        final ByteConversionSink encoder = codec.encoder.startChunkedConversion(CallbackByteSink(compressed.add));
        final Uint8List reusable = Uint8List(997);
        for (int i = 0; i < raw.length; i += reusable.length) {
          final int size = (raw.length - i).clamp(0, reusable.length);
          reusable.setRange(0, size, raw, i);
          encoder.addSlice(reusable, 0, size, false);
          reusable.fillRange(0, reusable.length, 255);
        }
        expect(compressed.length, greaterThan(32));
        encoder.close();
        encoder.close();
        expect(() => encoder.add(const [1]), throwsStateError);
        final Uint8List encoded = compressed.takeBytes();
        final BytesBuilder decoded = BytesBuilder();
        final ByteConversionSink decoder = codec.decoder.startChunkedConversion(CallbackByteSink(decoded.add));
        for (int i = 0; i < encoded.length; i++) {
          decoder.add([encoded[i]]);
        }
        expect(decoded.length, greaterThan(0));
        decoder.close();
        decoder.close();
        expect(decoded.takeBytes(), raw);
        expect(() => decoder.add(const [1]), throwsStateError);
      });
      test('concatenated members and streams retain cumulative output', () {
        final Uint8List raw = _sample(302);
        final Uint8List bytes = codec.encode(raw);
        expect(codec.decode([...bytes, ...bytes]), [...raw, ...raw]);
      });
      test('every truncated prefix is rejected', () {
        final Uint8List encoded = codec.encode(_sample(191));
        for (int end = 0; end < encoded.length; end++) {
          expect(() => codec.decode(Uint8List.sublistView(encoded, 0, end)), throwsA(isA<ZCodecException>()), reason: 'prefix $end/${encoded.length}');
        }
      });
      test('deterministic mutations never leak parser exceptions', () {
        final Uint8List encoded = codec.encode(_sample(601));
        for (int i = 0; i < encoded.length; i++) {
          final Uint8List mutation = Uint8List.fromList(encoded);
          mutation[i] ^= 1 << (i & 7);
          try {
            codec.decode(mutation);
          } on ZCodecException {
            // Malformed streams must use the codec's documented error type.
          }
        }
      });
      test('stream transform agrees with one-shot conversion', () async {
        final Uint8List raw = _sample(37001);
        final List<int> encoded = await Stream<List<int>>.fromIterable([raw.sublist(0, 123), raw.sublist(123)]).transform(codec.encoder).expand((chunk) => chunk).toList();
        final List<int> decoded = await Stream.value(encoded).transform(codec.decoder).expand((chunk) => chunk).toList();
        expect(decoded, raw);
      });
    });
  }
  test('input, output, dictionary, member and block limits are enforced', () {
    final Uint8List raw = _sample(10001);
    final Uint8List bzip = const Bzip2Codec().encode(raw);
    final Uint8List xz = const XzCodec(blockSize: 5000).encode(raw);
    for (final ByteDecoder decoder in [
      const Bzip2Decoder(maxOutputBytes: 10000),
      const Bzip2Decoder(maxInputBytes: 2),
      const XzDecoder(maxOutputBytes: 10000),
      const XzDecoder(maxInputBytes: 2),
      const XzDecoder(maxDictionaryBytes: 65535),
      const XzDecoder(maxBlocks: 2),
    ]) {
      expect(() => decoder.convert(decoder is Bzip2Decoder ? bzip : xz), throwsA(isA<ZCodecException>()));
    }
    expect(() => const Bzip2Decoder(maxMembers: 1).convert([...bzip, ...bzip]), throwsA(isA<ZCodecException>()));
    expect(() => const XzDecoder(maxStreams: 1).convert([...xz, ...xz]), throwsA(isA<ZCodecException>()));
    expect(() => const Bzip2Decoder(maxOutputBytes: -1).convert(bzip), throwsRangeError);
    expect(() => const XzDecoder(maxDictionaryBytes: -1).convert(xz), throwsArgumentError);
    expect(() => const Bzip2Encoder(blockSize: 0).convert(raw), throwsRangeError);
    expect(() => const XzEncoder(blockSize: 0).convert(raw), throwsRangeError);
    expect(() => const XzEncoder(blockSize: 100, maxBlocks: 1).convert(raw), throwsA(isA<ZCodecException>()));
    final ByteConversionSink failed = const XzDecoder(maxOutputBytes: 0).startChunkedConversion(CallbackByteSink((_) {}));
    expect(() => failed.add(xz), throwsA(isA<ZCodecException>()));
    expect(() => failed.add(xz), throwsStateError);
    failed.close();
  });
  test('BZIP2 ignores trailing garbage only when explicitly requested', () {
    final Uint8List bytes = const Bzip2Codec().encode([1, 2, 3]);
    for (final List<int> tail in [
      [0],
      [88, 89],
      [0, 1, 2, 3, 4],
    ]) {
      expect(() => const Bzip2Codec().decode([...bytes, ...tail]), throwsA(isA<ZCodecException>()));
      expect(const Bzip2Codec(allowTrailingBytes: true).decode([...bytes, ...tail]), [1, 2, 3]);
    }
    expect(() => const Bzip2Codec(allowTrailingBytes: true).decode([...bytes, 66, 90, 104]), throwsA(isA<ZCodecException>()));
  });
  test('SHA-256 known vectors and arbitrary fragmentation', () {
    final Map<String, String> vectors = {
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq': '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    };
    for (final MapEntry<String, String> entry in vectors.entries) {
      final Sha256 hash = Sha256();
      for (final int byte in utf8.encode(entry.key)) {
        hash.add([byte]);
      }
      expect(hash.close().map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(), entry.value);
      expect(() => hash.add([]), throwsStateError);
    }
  });
}
