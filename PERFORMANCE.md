# Optimization audit follow-up

Measured on September 13, 2026 with Dart 3.13.2, Linux x64, and an AOT executable. Timing cases use two warm-ups followed by the median of seven runs. Tests and builds were not running concurrently with timing measurements. These are local measurements on synthetic, seeded corpora, not performance guarantees for other workloads or platforms.

## Before and after

The text, random-byte, and repeated-byte inputs are the same as in the initial audit. ZIP cases use the same 2 MiB random payload, AES-256, and 64 KiB split volumes. The memory case runs in a separate fresh process with a 64 MiB repeated-byte input.

| Case                                            |                Before |                After |
|-------------------------------------------------|----------------------:|---------------------:|
| DEFLATE level 6, 2 MiB random input             |             74.869 ms |            24.820 ms |
| DEFLATE level 6, semi-compressible text         |            104.135 ms |           102.393 ms |
| Compressed size of that text                    |         695,739 bytes |        532,282 bytes |
| DEFLATE level 6, 2 MiB repeated bytes           |             11.243 ms |            11.136 ms |
| Compressed size of those repeated bytes         |          18,293 bytes |          2,468 bytes |
| Encrypted split ZIP, 2 MiB payload              |            444.348 ms |           174.037 ms |
| Process RSS after compressing 64 MiB            | approximately 329 MiB | approximately 81 MiB |
| Buffers retained by 1,000 one-byte GZIP members |       8,192,000 bytes |          1,000 bytes |
| TAR entry with a 16,388-byte path               |            377.083 ms |             0.202 ms |

The TAR figure is a deliberately extreme path-depth regression case. The portable benchmark can report a lower time after warming the TAR implementation through other archive cases. RSS includes the source buffer, Dart runtime, output, and allocator; it is not a direct measurement of live working storage. The match dictionary itself now contains at most two 32,768-element `Int32List` tables, approximately 256 KiB in total, rather than a predecessor table proportional to input length.

Compression ratio and speed remain a tradeoff. On this text corpus, level 1 takes 35.489 ms versus 32.940 ms before, while its output shrinks from 820,369 to 646,454 bytes. Level 6 and level 9 retain approximately their previous timing on the same corpus. Incompressible data still costs more to examine than an explicit `level: 0` or `ZipCompression.store` choice.

## Streaming behavior

DEFLATE, zlib, and GZIP byte converters now emit incrementally. Encoder storage is bounded by a block, dictionary, and token/header workspaces; emitted output is not retained. Decoder output limits are cumulative, including across concatenated GZIP members. `GzipMemberCodec`, TAR, and ZIP structured decoders still buffer their chunked input.

Decoded bytes are provisional until the stream completes successfully: an integrity check or truncation error can follow earlier output. Consumers must handle stream errors and must not assume one output chunk per conversion.

`ZipStreamWriter.addStoredStream` delegates pacing to destinations implementing `StreamConsumer<List<int>>`, including `IOSink`. Custom asynchronous plain sinks can provide a `flush` callback. A plain sink without either contract cannot expose backpressure. Regression tests verify at most one unconsumed source chunk for a delayed consumer and at most 4,096 pending bytes for a flushing sink receiving 4,096-byte chunks. Callers must await streamed entries before adding entries or finalizing the archive.

## Validation and reproduction

- `dart analyze`: no issues.
- `dart test`: 74 passing tests, including 240 seeded encoder/native-inflater combinations.
- `dart test --platform node`: 69 passing tests.
- `flutter test --no-pub`: 74 passing tests.
- ZIP interoperability with 7-Zip, and TAR/GZIP interoperability with the system tools, pass.
- Regression coverage includes exact distance 32,768, block boundaries, length 258, length-limited Huffman alphabets, empty streams, byte-by-byte fragmentation, reused input buffers, truncated streams, checksums, expansion limits, and slow ZIP destinations.

See [README benchmark commands](README.md#reproducible-benchmarks) and [the portable runner](tool/benchmark.dart). The JavaScript runner measures compiled Dart under Node; it is not a browser or WebAssembly benchmark.
