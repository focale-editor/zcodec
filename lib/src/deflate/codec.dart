part of 'package:zcodec/src/deflate.dart';

/// Encodes and decodes raw RFC 1951 DEFLATE streams in pure Dart.
///
/// ```dart
/// final compressed = const DeflateCodec(level: 9).encode(bytes);
/// final restored = const DeflateCodec().decode(compressed);
/// ```
final class DeflateCodec extends ByteCodec {
  /// Compression effort from 0 through 9.
  final int level;

  /// Optional ceiling on the number of decoded bytes.
  final int? maxOutputBytes;

  /// Creates a DEFLATE codec.
  const DeflateCodec({this.level = defaultCompressionLevel, this.maxOutputBytes});

  @override
  DeflateEncoder get encoder => DeflateEncoder(level: level);

  @override
  DeflateDecoder get decoder => DeflateDecoder(maxOutputBytes: maxOutputBytes);
}

/// Compresses bytes into a raw DEFLATE stream.
///
/// Level 0 writes stored blocks. Other levels select stored, fixed-Huffman,
/// or dynamic-Huffman blocks by bit cost, with deeper searches at higher levels.
final class DeflateEncoder extends ByteEncoder {
  /// Compression effort from 0 through 9.
  final int level;

  /// Creates a DEFLATE encoder.
  const DeflateEncoder({this.level = defaultCompressionLevel});

  @override
  Uint8List convert(List<int> input) {
    validateCompressionLevel(level);
    final Uint8List bytes = asBytes(input);
    return _DeflateEncoder(bytes, level).encode();
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    validateCompressionLevel(level);
    return _DeflateEncodingSink(sink, level);
  }
}

/// Decompresses a raw DEFLATE stream.
final class DeflateDecoder extends ByteDecoder {
  /// Optional ceiling on the number of decoded bytes.
  final int? maxOutputBytes;

  /// Creates a DEFLATE decoder.
  const DeflateDecoder({this.maxOutputBytes});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _DeflateDecodingSink(sink, maxOutputBytes);

  /// Decompresses [input], which must contain exactly one complete stream.
  ///
  /// A [ZCodecException] is thrown for malformed input, for trailing bytes,
  /// and when the output would exceed [maxOutputBytes].
  @override
  Uint8List convert(List<int> input) {
    final Uint8List bytes = asBytes(input);
    final DeflateDecodeResult result = convertPrefix(bytes);
    if (result.bytesRead != bytes.length) {
      throw const ZCodecException('Unexpected bytes after the final DEFLATE block');
    }
    return result.data;
  }

  /// Decompresses the first stream in [input] and reports its consumed length.
  ///
  /// Unlike [convert], this method permits trailing bytes. It is intended for
  /// container formats such as GZIP, whose trailer follows a raw DEFLATE
  /// stream without storing the compressed stream length separately.
  DeflateDecodeResult convertPrefix(List<int> input) {
    final int? maximum = maxOutputBytes;
    if (maximum != null && maximum < 0) {
      throw RangeError.value(maximum, 'maxOutputBytes', 'Must not be negative');
    }
    try {
      final BitReader reader = BitReader(asBytes(input));
      final Uint8List result = _DeflateDecoder(reader, maximum ?? _unboundedOutput).decode();
      reader.alignToByte();
      return DeflateDecodeResult(data: result, bytesRead: reader.byteOffset);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid DEFLATE stream: $error');
    }
  }
}

/// Contains one decoded DEFLATE stream and its compressed byte length.
final class DeflateDecodeResult {
  /// Uncompressed bytes produced by the stream.
  final Uint8List data;

  /// Number of input bytes consumed through the final block boundary.
  final int bytesRead;

  /// Creates a decoded stream result.
  const DeflateDecodeResult({required this.data, required this.bytesRead});
}

/// Output ceiling applied when a caller does not request one.
const int _unboundedOutput = 0x7fffffff;
