@TestOn('vm')
library;

import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  test('Dart native zlib and ZCodec decode each other', () {
    final Random random = Random(42);
    final Uint8List input = Uint8List.fromList(<int>[for (int index = 0; index < 100000; index++) random.nextInt(256)]);
    const ZlibCodec codec = ZlibCodec();
    expect(io.zlib.decode(codec.encode(input)), orderedEquals(input));
    expect(codec.decode(io.zlib.encode(input)), orderedEquals(input));
  });

  test('Dart native raw DEFLATE and ZCodec decode each other', () {
    final Uint8List input = Uint8List.fromList(<int>[for (int index = 0; index < 10000; index++) index % 17]);
    const DeflateCodec codec = DeflateCodec();
    final io.ZLibCodec native = io.ZLibCodec(raw: true);
    expect(native.decode(codec.encode(input)), orderedEquals(input));
    expect(codec.decode(native.encode(input)), orderedEquals(input));
  });

  test('Dart native GZIP and ZCodec decode each other', () {
    final Uint8List input = Uint8List.fromList(<int>[for (int index = 0; index < 100000; index++) (index * 97 + index ~/ 31) & 0xff]);
    const GzipCodec codec = GzipCodec();
    expect(io.gzip.decode(codec.encode(input)), orderedEquals(input));
    expect(codec.decode(io.gzip.encode(input)), orderedEquals(input));
  });

  test('incremental codecs interoperate at dictionary and block boundaries', () async {
    final List<({ByteCodec codec, Codec<List<int>, List<int>> native})> codecs = <({ByteCodec codec, Codec<List<int>, List<int>> native})>[
      (codec: const DeflateCodec(), native: io.ZLibCodec(raw: true)),
      (codec: const ZlibCodec(), native: io.ZLibCodec()),
      (codec: const GzipCodec(), native: io.gzip),
    ];
    for (final int size in <int>[0, 1, 257, 258, 259, 32767, 32768, 32769, 65534, 65535, 65536, 131073]) {
      final Random random = Random(size);
      final Uint8List input = Uint8List.fromList(<int>[for (int index = 0; index < size; index++) random.nextInt(index < size ~/ 2 ? 256 : 8)]);
      for (final configuration in codecs) {
        final ByteCodec codec = configuration.codec;
        final Codec<List<int>, List<int>> native = configuration.native;
        final BytesBuilder compressed = BytesBuilder();
        await Stream<List<int>>.fromIterable(_chunks(input, 997)).transform(codec.encoder).forEach(compressed.add);
        final Uint8List compressedBytes = compressed.takeBytes();
        expect(() => native.decode(compressedBytes), returnsNormally, reason: '${codec.runtimeType}, $size bytes, ${compressedBytes.length} compressed bytes');
        expect(native.decode(compressedBytes), orderedEquals(input), reason: '${codec.runtimeType}, $size bytes');
        final Uint8List nativeBytes = Uint8List.fromList(native.encode(input));
        final BytesBuilder decoded = BytesBuilder();
        await expectLater(
          Stream<List<int>>.fromIterable(_chunks(nativeBytes, size < 1000 ? 1 : 113)).transform(codec.decoder).forEach(decoded.add),
          completes,
          reason: '${codec.runtimeType}, native stream of $size bytes',
        );
        expect(decoded.takeBytes(), orderedEquals(input), reason: '${codec.runtimeType}, native stream of $size bytes');
      }
    }
  });

  test('native inflater validates randomized Huffman alphabets and match distributions', () {
    final io.ZLibCodec native = io.ZLibCodec(raw: true);
    for (int seed = 0; seed < 80; seed++) {
      final Random random = Random(seed);
      final int size = (seed * 7919) % 100001;
      final int alphabet = <int>[1, 2, 7, 16, 256][seed % 5];
      final Uint8List input = Uint8List(size);
      for (int index = 0; index < size; index++) {
        input[index] = index >= 512 && seed % 3 == 0 ? input[index - 512] : random.nextInt(alphabet);
      }
      for (final int level in <int>[1, 6, 9]) {
        final Uint8List compressed = DeflateCodec(level: level).encode(input);
        expect(native.decode(compressed), orderedEquals(input), reason: 'seed=$seed, level=$level, alphabet=$alphabet');
      }
    }
  });
}

/// Splits a fixture across arbitrary byte boundaries without copying it.
Iterable<Uint8List> _chunks(Uint8List bytes, int size) sync* {
  for (int offset = 0; offset < bytes.length; offset += size) {
    yield Uint8List.sublistView(bytes, offset, min(offset + size, bytes.length));
  }
}
