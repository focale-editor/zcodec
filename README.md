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

Encrypt individual entries with traditional ZipCrypto or WinZip AES AE-2:

```dart
final encrypted = const ZipEncoder().encode(
  ZipArchive(
    entries: [
      ZipEntry(
        name: 'private.bin',
        data: privateBytes,
        encryption: ZipEncryption.aes256,
      ),
    ],
  ),
  passwordProvider: (name) => passwords[name],
);

final decrypted = ZipDecoder(
  passwordProvider: (name) => passwords[name],
).decode(encrypted);
```

Create and decode split ZIP archives:

```dart
final volumes = const ZipEncoder().encodeVolumes(
  archive,
  volumeSize: 4 * 1024 * 1024,
);

// Persist all but the last volume as .z01, .z02, ... and the last as .zip.
final decoded = const ZipDecoder().decodeVolumes(volumes);
```

ZIP64 records are selected automatically when a count, size, offset, or disk
number reaches its classic ZIP limit. Pass `forceZip64: true` to either
`ZipEncoder.encode`, `ZipEncoder.encodeVolumes`, or `ZipStreamWriter` to emit
ZIP64 records for a small archive, which is useful for testing integrations.

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
- ZIP supports stored and DEFLATE entries, UTF-8 names, comments, DOS timestamps, CRC-32 validation, classic and ZIP64 data descriptors, ZIP64 end records, and lazy extraction.
- Per-entry encryption supports traditional ZipCrypto and WinZip AES AE-1/AE-2 with 128-, 192-, and 256-bit keys. New AES entries use AE-2. ZipCrypto is retained for interoperability but is cryptographically weak.
- `encodeVolumes` writes split archives with the standard split marker and keeps headers within one volume. `decodeVolumes` reads split and spanned archives supplied in disk order.
- `maxOutputBytes` and `ZipLimits` bound expansion of untrusted inputs.
- `ZipEntry.hasSafePath` must be checked before extracting an entry to disk.
- Proprietary PKWARE Strong Encryption is detected and rejected explicitly; it is distinct from WinZip AES and requires separately licensed PKWARE technology.

All compression, checksums, ZipCrypto, AES, SHA-1, HMAC, and PBKDF2 code is implemented in Dart. ZCodec uses only Dart SDK libraries and has no runtime package dependencies.
