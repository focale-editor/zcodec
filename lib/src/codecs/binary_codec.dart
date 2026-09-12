part of 'package:zcodec/src/codecs.dart';

/// Converts values of type [S] to and from a byte representation.
///
/// Every ZCodec format extends this class, so the whole package obeys the
/// `dart:convert` contract: [encoder] and [decoder] are reusable [Converter]
/// instances, and [encode] and [decode] are shorthands for a single
/// conversion. Conversion options belong to the codec and its converters
/// rather than to individual calls, which keeps a configured codec usable as a
/// value that can be stored, shared, and passed to `Stream.transform`.
abstract base class BinaryCodec<S> extends Codec<S, List<int>> {
  /// Creates a binary codec.
  const BinaryCodec();

  @override
  BinaryEncoder<S> get encoder;

  @override
  BinaryDecoder<S> get decoder;

  @override
  Uint8List encode(S input) => encoder.convert(input);

  @override
  S decode(List<int> encoded) => decoder.convert(encoded);
}

/// Serializes values of type [S] into bytes.
abstract base class BinaryEncoder<S> extends Converter<S, List<int>> {
  /// Creates a binary encoder.
  const BinaryEncoder();

  @override
  Uint8List convert(S input);

  /// Encodes every value added to the returned sink independently.
  @override
  Sink<S> startChunkedConversion(Sink<List<int>> sink) => _MappingSink<S>(sink, convert);
}

/// Parses bytes back into a value of type [S].
abstract base class BinaryDecoder<S> extends Converter<List<int>, S> {
  /// Creates a binary decoder.
  const BinaryDecoder();

  @override
  S convert(List<int> input);

  /// Buffers every chunk and decodes them as one input when the sink closes.
  ///
  /// Archive and metadata decoders use this default to return a complete value.
  /// DEFLATE, zlib, and GZIP byte decoders override it to emit progressively.
  @override
  ByteConversionSink startChunkedConversion(Sink<S> sink) => _BufferingByteSink<S>(sink, convert);
}
