/// Dependency-free pure Dart codecs for DEFLATE, zlib, GZIP, TAR, and ZIP data.
///
/// Every format is exposed as a `dart:convert` [Codec], so the same value can
/// be used with [Codec.encode], [Codec.decode], [Codec.fuse], and
/// `Stream.transform`.
library;

export 'dart:convert' show Codec, Converter;

export 'src/codecs.dart' show BinaryCodec, BinaryDecoder, BinaryEncoder, ByteCodec, ByteDecoder, ByteEncoder, defaultCompressionLevel;
export 'src/deflate.dart' show DeflateCodec, DeflateDecodeResult, DeflateDecoder, DeflateEncoder;
export 'src/exception.dart';
export 'src/gzip.dart';
export 'src/tar.dart';
export 'src/zip.dart';
export 'src/zlib.dart';
