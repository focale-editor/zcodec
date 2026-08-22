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
}
