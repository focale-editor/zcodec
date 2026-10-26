part of 'package:zcodec/src/bzip2.dart';

/// Encodes and decodes BZIP2, including concatenated members.
final class Bzip2Codec extends ByteCodec {
  /// Block size in units of 100,000 bytes, from 1 through 9.
  final int blockSize;

  /// Cumulative decoded byte ceiling, including concatenated members.
  final int? maxOutputBytes;

  /// Cumulative encoded input ceiling.
  final int? maxInputBytes;

  /// Whether non-BZIP2 trailing bytes may follow complete members.
  final bool allowTrailingBytes;

  /// Maximum number of concatenated members.
  final int maxMembers;

  /// Creates a BZIP2 codec.
  const Bzip2Codec({this.blockSize = 9, this.maxOutputBytes, this.maxInputBytes, this.maxMembers = 10000, this.allowTrailingBytes = false});

  @override
  Bzip2Encoder get encoder => Bzip2Encoder(blockSize: blockSize);

  @override
  Bzip2Decoder get decoder => Bzip2Decoder(maxOutputBytes: maxOutputBytes, maxInputBytes: maxInputBytes, maxMembers: maxMembers, allowTrailingBytes: allowTrailingBytes);
}

/// Compresses bytes using BWT, move-to-front, run-length and Huffman coding.
final class Bzip2Encoder extends ByteEncoder {
  /// Block size in units of 100,000 bytes, from 1 through 9.
  final int blockSize;

  /// Creates a BZIP2 encoder.
  const Bzip2Encoder({this.blockSize = 9});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    RangeError.checkValueInInterval(blockSize, 1, 9, 'blockSize');
    return _BzipEncodingSink(sink, blockSize);
  }

  @override
  Uint8List convert(List<int> input) {
    final BytesBuilder result = BytesBuilder(copy: false);
    startChunkedConversion(CallbackByteSink(result.add))
      ..add(input)
      ..close();
    return result.takeBytes();
  }
}

/// Decompresses BZIP2 blocks and verifies both block and member checksums.
final class Bzip2Decoder extends ByteDecoder {
  /// Cumulative decoded byte ceiling, including concatenated members.
  final int? maxOutputBytes;

  /// Cumulative encoded input ceiling.
  final int? maxInputBytes;

  /// Whether non-BZIP2 trailing bytes may follow complete members.
  final bool allowTrailingBytes;

  /// Maximum number of concatenated members.
  final int maxMembers;

  /// Creates a BZIP2 decoder.
  const Bzip2Decoder({this.maxOutputBytes, this.maxInputBytes, this.maxMembers = 10000, this.allowTrailingBytes = false});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _BzipDecodingSink(sink, maxOutputBytes, maxInputBytes, maxMembers, allowTrailingBytes);

  @override
  Uint8List convert(List<int> input) {
    final BytesBuilder result = BytesBuilder(copy: false);
    startChunkedConversion(CallbackByteSink(result.add))
      ..add(input)
      ..close();
    return result.takeBytes();
  }
}
