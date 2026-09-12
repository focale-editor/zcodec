# ZCodec

ZCodec provides dependency-free, synchronous codecs for DEFLATE, zlib, GZIP, TAR, and ZIP data. Its compression engine and archive parsers are implemented entirely in Dart: they do not import `dart:io`, call a native zlib backend, or use FFI. The core API therefore works on the Dart VM and the Web.

## Usage

Encode and decode a zlib stream:

```dart
import 'dart:convert';

import 'package:zcodec/zcodec.dart';

const codec = ZlibCodec();
final compressed = codec.encode(utf8.encode('Hello ZCodec'));
final text = utf8.decode(codec.decode(compressed));
```

Conversion options belong to the codec, so a configured codec is a value you can store and reuse:

```dart
const fast = DeflateCodec(level: 1);
const bounded = ZlibCodec(maxOutputBytes: 64 * 1024 * 1024);
```

Decode a `.tar.gz` file such as a source release:

```dart
final tar = const TarCodec()
    .fuse(const GzipCodec(maxOutputBytes: 512 * 1024 * 1024))
    .decode(tarGzipBytes);

for (final entry in tar.entries) {
  if (!entry.hasSafePath || !entry.hasSafeLinkTarget) {
    throw StateError('Unsafe TAR path: ${entry.name}');
  }
  // The application decides whether and where to materialize the entry.
}
```

Create a compressed TAR archive:

```dart
final tarGzipBytes = const TarCodec()
    .fuse(const GzipCodec(header: GzipHeader(name: 'sources.tar')))
    .encode(
      TarArchive(
        entries: [
          TarEntry(name: 'src/', type: TarEntryType.directory),
          TarEntry(name: 'src/main.dart', data: sourceBytes),
        ],
      ),
    );
```

Build and read a ZIP archive:

```dart
const zip = ZipCodec();
final bytes = zip.encode(
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

final archive = zip.decode(bytes);
final manifest = archive.find('manifest.json')?.data;
```

Encrypt individual entries with traditional ZipCrypto or WinZip AES AE-2:

```dart
final codec = ZipCodec(passwordProvider: (name) => passwords[name]);
final encrypted = codec.encode(
  ZipArchive(
    entries: [
      ZipEntry(
        name: 'private.bin',
        data: privateBytes,
        encryption: ZipEncryption.aes256,
      ),
    ],
  ),
);

final decrypted = codec.decode(encrypted);
```

Create and decode split ZIP archives:

```dart
final volumes = const ZipCodec().encodeVolumes(
  archive,
  volumeSize: 4 * 1024 * 1024,
);

// Persist all but the last volume as .z01, .z02, ... and the last as .zip.
final decoded = const ZipCodec().decodeVolumes(volumes);
```

ZIP64 records are selected automatically when a count, size, offset, or disk
number reaches its classic ZIP limit. Pass `forceZip64: true` to `ZipCodec`,
`ZipEncoder`, or `ZipStreamWriter` to emit ZIP64 records for a small archive,
which is useful for testing integrations.

Keep GZIP member metadata by decoding with `GzipMemberCodec`, which maps a
GZIP file to and from its list of members:

```dart
final members = const GzipMemberCodec().decode(gzipBytes);
print(members.first.name);
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

For `addStoredStream`, destinations that also implement `StreamConsumer<List<int>>`, including `IOSink`, regulate input through `addStream`. A custom asynchronous sink should expose completion through `ZipStreamWriter(outputSink, flush: outputSink.flush)`; the writer then awaits that callback after each input chunk. A plain sink without either contract cannot signal backpressure. Always await `addStoredStream` before adding another entry or closing the writer. A failed streamed entry prevents finalization of the archive.

ZIP entries decoded from an archive are inflated lazily. Call `ZipEntry.release()` after consuming a large entry, or `ZipArchive.release()` for all entries, to allow the decoded buffers to be reclaimed while retaining the original archive bytes.

## Codec structure

| Codec             | Decoded form       | Encoded form        |
|-------------------|--------------------|---------------------|
| `DeflateCodec`    | `List<int>`        | raw RFC 1951 stream |
| `ZlibCodec`       | `List<int>`        | RFC 1950 stream     |
| `GzipCodec`       | `List<int>`        | RFC 1952 file       |
| `GzipMemberCodec` | `List<GzipMember>` | RFC 1952 file       |
| `TarCodec`        | `TarArchive`       | TAR archive         |
| `ZipCodec`        | `ZipArchive`       | ZIP archive         |

All of them extend `BinaryCodec<S>`, a `Codec<S, List<int>>` whose encoded side is always bytes. The byte-to-byte compressors additionally share `ByteCodec`. Their reusable `codec.encoder` and `codec.decoder` converters can be passed to `Stream.transform`.

DEFLATE, zlib, and GZIP byte converters work incrementally: they emit multiple output chunks and preserve their dictionary across input chunks. Compression buffers at most one 65,535-byte input block and 32 KiB of history; decompression keeps bounded history and pending parser state. They do not retain the complete input or previously emitted output. For example:

```dart
await destination.addStream(source.transform(const GzipCodec().encoder));
```

Output boundaries need not match input boundaries. Decoders can emit bytes before a later checksum, truncation, or output-limit error is discovered: treat output as provisional until the stream completes successfully. `maxOutputBytes` applies cumulatively, including across GZIP members. The single-buffer `encode`/`decode` methods remain synchronous. `GzipMemberCodec`, `TarCodec`, and `ZipCodec` decoders still buffer chunked input to return complete structured values.

## Safety and format support

- DEFLATE encoding and decoding support stored, fixed-Huffman, and dynamic-Huffman blocks. The encoder chooses the smallest estimated block representation and uses a bounded match dictionary at every compression level.
- zlib validates its header and Adler-32 trailer.
- GZIP supports optional name, comment, extra, timestamp, text, OS, and header-checksum fields; concatenated members; CRC-32 and ISIZE validation; and output/member limits.
- TAR decoding supports V7-compatible and POSIX ustar headers, GNU base-256 numbers, GNU long names and links, global and local PAX headers, links, devices, directories, FIFOs, and unknown vendor typeflags. TAR encoding emits ustar with automatic PAX extensions.
- Legacy GNU sparse and GNU sparse PAX entries are detected and rejected explicitly because reconstructing sparse file holes requires a distinct extraction contract.
- ZIP supports stored and DEFLATE entries, UTF-8 names, comments, DOS timestamps, CRC-32 validation, classic and ZIP64 data descriptors, ZIP64 end records, and lazy extraction.
- Per-entry encryption supports traditional ZipCrypto and WinZip AES AE-1/AE-2 with 128-, 192-, and 256-bit keys. New AES entries use AE-2. ZipCrypto is retained for interoperability but is cryptographically weak.
- `encodeVolumes` writes split archives with the standard split marker and keeps headers within one volume. `decodeVolumes` reads split and spanned archives supplied in disk order.
- `maxOutputBytes`, `TarLimits`, and `ZipLimits` bound expansion of untrusted inputs.
- `TarEntry.hasSafePath`, `TarEntry.hasSafeLinkTarget`, and `ZipEntry.hasSafePath` must be checked before extracting an entry to disk.
- Proprietary PKWARE Strong Encryption is detected and rejected explicitly; it is distinct from WinZip AES and requires separately licensed PKWARE technology.

All compression, archive parsing, checksums, ZipCrypto, AES, SHA-1, HMAC, and PBKDF2 code is implemented in Dart. ZCodec uses only Dart SDK libraries and has no runtime package dependencies.
