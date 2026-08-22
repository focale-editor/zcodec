# ZCodec

ZCodec provides dependency-free, synchronous codecs for DEFLATE, zlib, and ZIP data. Its compression engine is implemented entirely in Dart: it does not import `dart:io`, call a native zlib backend, or use FFI. The core API therefore works on the Dart VM and the Web.

## Usage

Encode and decode a zlib stream:

```dart
import 'dart:convert';

import 'package:zcodec/zcodec.dart';

const codec = ZlibCodec();
final compressed = codec.encode(utf8.encode('Hello ZCodec'));
final text = utf8.decode(codec.decode(compressed));
```

Build and read a ZIP archive:

```dart
final bytes = const ZipEncoder().encode(
  ZipArchive(
    entries: [
      ZipEntry(name: 'manifest.json', data: utf8.encode('{}')),
      ZipEntry(
        name: 'preview.png',
        data: pngBytes,
        compression: ZipCompression.store,
      ),
    ],
  ),
);

final archive = const ZipDecoder().decode(bytes);
final manifest = archive.find('manifest.json')?.data;
```

Stream large, already-compressed entries to any Dart byte sink:

```dart
final writer = ZipStreamWriter(outputSink);
writer.add(ZipEntry(name: 'manifest.json', data: manifestBytes));
await writer.addStoredStream(
  name: 'raster/image.png',
  data: pngByteStream,
  size: pngByteLength,
);
writer.close();
```

`ZipStreamWriter` does not import `dart:io` and does not close the caller-owned sink. A VM application can pass an `IOSink`; a Web application can provide any `Sink<List<int>>`.

ZIP entries decoded from an archive are inflated lazily. Call `ZipEntry.release()` after consuming a large entry, or `ZipArchive.release()` for all entries, to allow the decoded buffers to be reclaimed while retaining the original archive bytes.

## Safety and format support

- DEFLATE decoding supports stored, fixed-Huffman, and dynamic-Huffman blocks.
- zlib validates its header and Adler-32 trailer.
- ZIP supports stored and DEFLATE entries, UTF-8 names, comments, DOS timestamps, CRC-32 validation, and data descriptors described by the central directory.
- `maxOutputBytes` and `ZipLimits` bound expansion of untrusted inputs.
- `ZipEntry.hasSafePath` must be checked before extracting an entry to disk.
- Encrypted, multi-disk, and ZIP64 archives are rejected explicitly.

ZCodec uses only `dart:convert` and `dart:typed_data`; it has no runtime package dependencies.

## Intended integrations

- Imcodec can replace `archive`'s `ZLibEncoder` in its PNG encoder with `const ZlibCodec().encode(filtered, level: level)`.
- PsdKit can replace its conditional `dart:io` zlib backend with `ZlibCodec`, passing the expected PSD allocation ceiling as `maxOutputBytes` while decoding.
- Focale can use `ZipEncoder` for in-memory documents or `ZipStreamWriter.addStoredStream` for cached PNG assets, then use lazy `ZipDecoder` entries while loading.
