import 'dart:convert';

import 'package:zcodec/zcodec.dart';

/// Demonstrates a zlib and ZIP round trip.
void main() {
  const ZlibCodec zlib = ZlibCodec();
  final List<int> message = utf8.encode('Hello ZCodec');
  final List<int> compressed = zlib.encode(message);
  print(utf8.decode(zlib.decode(compressed)));

  final List<int> zip = const ZipEncoder().encode(
    ZipArchive(
      entries: <ZipEntry>[ZipEntry(name: 'hello.txt', data: message)],
    ),
  );
  print(utf8.decode(const ZipDecoder().decode(zip).find('hello.txt')!.data));
}
