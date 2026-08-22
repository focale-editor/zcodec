import 'dart:typed_data';

import 'package:zcodec/src/byte_io.dart';
import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/deflate_codec.dart';
import 'package:zcodec/src/exception.dart';

/// Encodes and decodes RFC 1950 zlib streams in pure Dart.
final class ZlibCodec {
  /// Raw DEFLATE implementation shared by every codec instance.
  static const DeflateCodec _deflate = DeflateCodec();

  /// Creates a stateless zlib codec.
  const ZlibCodec();

  /// Compresses [input] with a level from 0 through 9.
  Uint8List encode(List<int> input, {int level = 6}) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    final Uint8List bytes = _asUint8List(input);
    const int compressionAndWindow = 0x78;
    final int levelHint = level <= 1
        ? 0
        : level <= 5
        ? 1
        : level <= 7
        ? 2
        : 3;
    final int flagsWithoutCheck = levelHint << 6;
    final int checkBits = (31 - (((compressionAndWindow << 8) | flagsWithoutCheck) % 31)) % 31;
    final ByteWriter output = ByteWriter()
      ..writeByte(compressionAndWindow)
      ..writeByte(flagsWithoutCheck | checkBits)
      ..writeBytes(_deflate.encode(bytes, level: level))
      ..writeUint32BigEndian(adler32(bytes));
    return output.takeBytes();
  }

  /// Decompresses [input], validates its checksum, and limits its output.
  ///
  /// Set [maxOutputBytes] when decoding untrusted data to avoid unbounded
  /// allocation. A [ZCodecException] is thrown when the stream is malformed.
  Uint8List decode(List<int> input, {int? maxOutputBytes}) {
    if (maxOutputBytes != null && maxOutputBytes < 0) {
      throw RangeError.value(maxOutputBytes, 'maxOutputBytes', 'Must not be negative');
    }
    final Uint8List bytes = _asUint8List(input);
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
    final Uint8List result = _deflate.decode(
      Uint8List.sublistView(bytes, 2, checksumOffset),
      maxOutputBytes: maxOutputBytes,
    );
    final int expected = (bytes[checksumOffset] << 24) | (bytes[checksumOffset + 1] << 16) | (bytes[checksumOffset + 2] << 8) | bytes[checksumOffset + 3];
    final int actual = adler32(result);
    if (actual != expected) {
      throw ZCodecException('Invalid zlib Adler-32 checksum: expected 0x${expected.toRadixString(16).padLeft(8, '0')}, got 0x${actual.toRadixString(16).padLeft(8, '0')}');
    }
    return result;
  }
}

/// Returns [input] as an unsigned byte buffer.
Uint8List _asUint8List(List<int> input) => input is Uint8List ? input : Uint8List.fromList(input);
