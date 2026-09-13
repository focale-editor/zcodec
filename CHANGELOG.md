# 📰 ZCodec changelog

## v0.2.1
Released on September 13, 2026.

* **DOCS**: Added contributing guide, package screenshot, and pubspec metadata. ([#7135b22](https://github.com/focale-editor/zcodec/commit/7135b22))
* **FEAT**: Added incremental streaming codecs and dynamic Huffman DEFLATE encoding. ([#d5fb84c](https://github.com/focale-editor/zcodec/commit/d5fb84c))
* **CHORE**: Optimized DEFLATE decoding and checksum calculations. ([#36396ae](https://github.com/focale-editor/zcodec/commit/36396ae))

## Unreleased

* Add bounded-window DEFLATE encoding with per-block stored, fixed, or length-limited dynamic Huffman selection and the dedicated length-258 code.
* Make DEFLATE, zlib, and GZIP byte stream conversions incremental. Output may now arrive before close and before final integrity validation; expansion limits remain cumulative.
* Prepare split ZIP entries once, avoiding duplicate compression, encryption, and password/salt callbacks. Honor asynchronous backpressure for stored ZIP streams and reject overlapping writes or finalization after a failed entry.
* Reduce decompression copy overhead, Huffman table memory, and retained capacity in small decoded buffers. Avoid unnecessary ZIP checksums when verification is disabled and process GZIP members sequentially.
* Make long TAR path handling linear and reuse encoded path fields.
* Add reproducible VM/Web benchmarks and regression tests for block boundaries, native interoperability, fragmented streams, output limits, and slow destinations.

## v0.2.0
Released on August 27, 2026.

* **BREAKING REFACTOR**: Standardized codecs around `dart:convert` and restructured codebase. ([#9ab9071](https://github.com/focale-editor/zcodec/commit/9ab9071))

## v0.1.3
Released on August 25, 2026.

* **CHORE**: Renamed example main file. ([#6fe9fab](https://github.com/focale-editor/zcodec/commit/6fe9fab))

## v0.1.2
Released on August 24, 2026.

* **FEAT**: Added support for TAR and GZIP formats. ([#96314a7](https://github.com/focale-editor/zcodec/commit/96314a7))
* **CHORE**: Now ignoring some files for pub.dev. ([#9ee84d6](https://github.com/focale-editor/zcodec/commit/9ee84d6))

## v0.1.1
Released on August 22, 2026.

* **FEAT**: Added support for TAR and GZIP formats. ([#11bb58b](https://github.com/focale-editor/zcodec/commit/11bb58b))

## v0.1.0
Released on August 22, 2026.

* **Initial release**.
