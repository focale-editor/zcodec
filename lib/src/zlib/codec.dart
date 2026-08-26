part of 'package:zcodec/src/zlib.dart';

/// Encodes and decodes RFC 1950 zlib streams in pure Dart.
final class ZlibCodec extends ByteCodec {
  /// Compression effort from 0 through 9.
  final int level;

  /// Optional ceiling on the number of decoded bytes.
  final int? maxOutputBytes;

  /// Creates a zlib codec.
  const ZlibCodec({this.level = defaultCompressionLevel, this.maxOutputBytes});

  @override
  ZlibEncoder get encoder => ZlibEncoder(level: level);

  @override
  ZlibDecoder get decoder => ZlibDecoder(maxOutputBytes: maxOutputBytes);
}

/// Wraps a DEFLATE stream in a zlib header and Adler-32 trailer.
final class ZlibEncoder extends ByteEncoder {
  /// Compression effort from 0 through 9.
  final int level;

  /// Creates a zlib encoder.
  const ZlibEncoder({this.level = defaultCompressionLevel});

  @override
  Uint8List convert(List<int> input) {
    validateCompressionLevel(level);
    final Uint8List bytes = asBytes(input);
    // Method 8 with the maximum 32 KiB window, which is what the encoder uses.
    const int compressionAndWindow = 0x78;
    final int levelHint = switch (level) {
      <= 1 => 0,
      <= 5 => 1,
      <= 7 => 2,
      _ => 3,
    };
    final int flagsWithoutCheck = levelHint << 6;
    final int checkBits = (31 - (((compressionAndWindow << 8) | flagsWithoutCheck) % 31)) % 31;
    final ByteWriter output = ByteWriter()
      ..writeByte(compressionAndWindow)
      ..writeByte(flagsWithoutCheck | checkBits)
      ..writeBytes(DeflateEncoder(level: level).convert(bytes))
      ..writeUint32BigEndian(adler32(bytes));
    return output.takeBytes();
  }
}

/// Validates a zlib header and Adler-32 trailer around a DEFLATE stream.
final class ZlibDecoder extends ByteDecoder {
  /// Optional ceiling on the number of decoded bytes.
  final int? maxOutputBytes;

  /// Creates a zlib decoder.
  ///
  /// Set [maxOutputBytes] when decoding untrusted data to avoid unbounded
  /// allocation.
  const ZlibDecoder({this.maxOutputBytes});

  @override
  Uint8List convert(List<int> input) {
    final Uint8List bytes = asBytes(input);
    if (bytes.length < 6) {
      throw const ZCodecException('Truncated zlib stream');
    }
    final int compressionAndWindow = bytes[0];
    final int flags = bytes[1];
    if ((compressionAndWindow & 0x0f) != 8) {
      throw const ZCodecException('Unsupported zlib compression method');
    }
    if ((compressionAndWindow >>> 4) > 7) {
      throw const ZCodecException('Invalid zlib window size');
    }
    if (((compressionAndWindow << 8) | flags) % 31 != 0) {
      throw const ZCodecException('Invalid zlib header checksum');
    }
    if ((flags & 0x20) != 0) {
      throw const ZCodecException('Preset zlib dictionaries are not supported');
    }
    final int checksumOffset = bytes.length - 4;
    final Uint8List result = DeflateDecoder(maxOutputBytes: maxOutputBytes).convert(Uint8List.sublistView(bytes, 2, checksumOffset));
    final int expected = (bytes[checksumOffset] << 24) | (bytes[checksumOffset + 1] << 16) | (bytes[checksumOffset + 2] << 8) | bytes[checksumOffset + 3];
    final int actual = adler32(result);
    if (actual != expected) {
      throw ZCodecException('Invalid zlib Adler-32 checksum: expected 0x${expected.toRadixString(16).padLeft(8, '0')}, got 0x${actual.toRadixString(16).padLeft(8, '0')}');
    }
    return result;
  }
}
