part of 'package:zcodec/src/codecs.dart';

/// Compresses and decompresses a byte stream.
///
/// This is the shape shared by [BinaryCodec]s whose decoded form is also a
/// byte sequence, such as DEFLATE, zlib, and GZIP.
abstract base class ByteCodec extends BinaryCodec<List<int>> {
  /// Creates a byte codec.
  const ByteCodec();

  @override
  ByteEncoder get encoder;

  @override
  ByteDecoder get decoder;

  @override
  Uint8List decode(List<int> encoded) => decoder.convert(encoded);
}

/// Compresses a byte sequence.
abstract base class ByteEncoder extends BinaryEncoder<List<int>> {
  /// Creates a byte encoder.
  const ByteEncoder();

  /// Buffers every chunk and compresses them as one input on close.
  ///
  /// This fallback preserves one logical stream across all input chunks.
  /// DEFLATE, zlib, and GZIP encoders override it with bounded incremental
  /// compression that retains the dictionary between chunks.
  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _BufferingByteSink<List<int>>(sink, convert);
}

/// Decompresses a byte sequence.
abstract base class ByteDecoder extends BinaryDecoder<List<int>> {
  /// Creates a byte decoder.
  const ByteDecoder();

  @override
  Uint8List convert(List<int> input);
}
