part of 'package:zcodec/src/xz.dart';

/// Compresses XZ/LZMA2 and decodes concatenated XZ streams.
///
/// Decoding supports LZMA2, Delta and x86/PowerPC/ARM64 BCJ filters. Other filter IDs are
/// rejected explicitly. Encoding uses a bounded 64-KiB match dictionary;
/// [blockSize] controls independently checksummed XZ blocks, not match history.
final class XzCodec extends ByteCodec {
  /// Payload integrity algorithm used for encoding.
  final XzCheck check;

  /// Maximum uncompressed bytes per encoded XZ block.
  final int blockSize;

  /// Cumulative decoded byte ceiling.
  final int? maxOutputBytes;

  /// Cumulative encoded input ceiling.
  final int? maxInputBytes;

  /// Maximum declared LZMA2 dictionary allocation.
  final int maxDictionaryBytes;

  /// Maximum concatenated stream count.
  final int maxStreams;

  /// Maximum cumulative block count, bounding index memory.
  final int maxBlocks;

  /// Creates an XZ codec.
  const XzCodec({
    this.check = XzCheck.crc64,
    this.blockSize = 1024 * 1024,
    this.maxOutputBytes,
    this.maxInputBytes,
    this.maxDictionaryBytes = 64 * 1024 * 1024,
    this.maxStreams = 10000,
    this.maxBlocks = 100000,
  });

  @override
  XzEncoder get encoder => XzEncoder(check: check, blockSize: blockSize, maxBlocks: maxBlocks);

  @override
  XzDecoder get decoder => XzDecoder(maxOutputBytes: maxOutputBytes, maxInputBytes: maxInputBytes, maxDictionaryBytes: maxDictionaryBytes, maxStreams: maxStreams, maxBlocks: maxBlocks);
}

/// Emits compressed LZMA2 chunks, storing incompressible chunks.
final class XzEncoder extends ByteEncoder {
  /// Payload integrity algorithm.
  final XzCheck check;

  /// Maximum uncompressed XZ block size, from 1 byte through 16 MiB.
  final int blockSize;

  /// Maximum block count; bounds retained index entries during streaming.
  final int maxBlocks;

  /// Creates an XZ encoder.
  const XzEncoder({this.check = XzCheck.crc64, this.blockSize = 1024 * 1024, this.maxBlocks = 100000});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    RangeError.checkValueInInterval(blockSize, 1, 16 * 1024 * 1024, 'blockSize');
    if (maxBlocks < 1) {
      throw RangeError.value(maxBlocks, 'maxBlocks');
    }
    return _XzEncodingSink(sink, check, blockSize, maxBlocks);
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

/// Decodes XZ framing, filter chains and LZMA2 with mandatory integrity checks.
final class XzDecoder extends ByteDecoder {
  /// Cumulative decoded byte ceiling.
  final int? maxOutputBytes;

  /// Cumulative encoded input ceiling.
  final int? maxInputBytes;

  /// Maximum declared dictionary allocation.
  final int maxDictionaryBytes;

  /// Maximum concatenated stream count.
  final int maxStreams;

  /// Maximum cumulative block count.
  final int maxBlocks;

  /// Creates an XZ decoder.
  const XzDecoder({this.maxOutputBytes, this.maxInputBytes, this.maxDictionaryBytes = 64 * 1024 * 1024, this.maxStreams = 10000, this.maxBlocks = 100000});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _XzDecodingSink(sink, this);

  @override
  Uint8List convert(List<int> input) {
    final BytesBuilder result = BytesBuilder(copy: false);
    startChunkedConversion(CallbackByteSink(result.add))
      ..add(input)
      ..close();
    return result.takeBytes();
  }
}
