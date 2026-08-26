import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/zcodec.dart';

/// Demonstrates zlib, TAR/GZIP, and ZIP round trips.
void main() {
  const ZlibCodec zlib = ZlibCodec();
  final List<int> message = utf8.encode('Hello ZCodec');
  final List<int> compressed = zlib.encode(message);
  print(utf8.decode(zlib.decode(compressed)));

  // TAR carries no compression of its own, so `.tar.gz` is TAR fused with GZIP.
  final Codec<TarArchive, List<int>> tarGzip = const TarCodec().fuse(const GzipCodec(header: GzipHeader(name: 'hello.tar')));
  final List<int> archiveBytes = tarGzip.encode(
    TarArchive(
      entries: <TarEntry>[TarEntry(name: 'hello.txt', data: message)],
    ),
  );
  print(utf8.decode(tarGzip.decode(archiveBytes).find('hello.txt')!.data));

  const ZipCodec zip = ZipCodec();
  final Uint8List zipBytes = zip.encode(
    ZipArchive(
      entries: <ZipEntry>[ZipEntry(name: 'hello.txt', data: message)],
    ),
  );
  print(utf8.decode(zip.decode(zipBytes).find('hello.txt')!.data));
}
