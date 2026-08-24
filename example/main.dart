import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/zcodec.dart';

/// Demonstrates zlib, TAR/GZIP, and ZIP round trips.
void main() {
  const ZlibCodec zlib = ZlibCodec();
  final List<int> message = utf8.encode('Hello ZCodec');
  final List<int> compressed = zlib.encode(message);
  print(utf8.decode(zlib.decode(compressed)));

  final Uint8List tarGzip = const GzipCodec().encode(
    const TarEncoder().encode(
      TarArchive(
        entries: <TarEntry>[TarEntry(name: 'hello.txt', data: message)],
      ),
    ),
    name: 'hello.tar',
  );
  final TarArchive tar = const TarDecoder().decode(
    const GzipCodec().decode(tarGzip),
  );
  print(utf8.decode(tar.find('hello.txt')!.data));

  final List<int> zip = const ZipEncoder().encode(
    ZipArchive(
      entries: <ZipEntry>[ZipEntry(name: 'hello.txt', data: message)],
    ),
  );
  print(utf8.decode(const ZipDecoder().decode(zip).find('hello.txt')!.data));
}
