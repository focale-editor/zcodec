part of 'package:zcodec/src/io.dart';

/// Reads fixed-width integers from a byte buffer.
final class ByteReader {
  /// Bytes being read.
  final Uint8List bytes;

  /// Current byte offset.
  int offset;

  /// Creates a reader positioned at [offset].
  ByteReader(this.bytes, {this.offset = 0});

  /// Number of unread bytes.
  int get remaining => bytes.length - offset;

  /// Reads an unsigned byte.
  int readByte() {
    _require(1);
    return bytes[offset++];
  }

  /// Reads a little-endian 16-bit integer.
  int readUint16() {
    _require(2);
    final int value = bytes[offset] | (bytes[offset + 1] << 8);
    offset += 2;
    return value;
  }

  /// Reads a little-endian 32-bit integer.
  int readUint32() {
    _require(4);
    final int value = bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
    offset += 4;
    return value & 0xffffffff;
  }

  /// Reads a little-endian 64-bit integer.
  int readUint64() {
    _require(8);
    int value = 0;
    for (int index = 7; index >= 0; index--) {
      value = value * 256 + bytes[offset + index];
    }
    offset += 8;
    return value;
  }

  /// Reads [length] bytes without copying them.
  Uint8List readBytes(int length) {
    _require(length);
    final Uint8List value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  /// Skips [length] bytes.
  void skip(int length) {
    _require(length);
    offset += length;
  }

  /// Ensures that [length] bytes remain available.
  void _require(int length) {
    if (length < 0 || length > remaining) {
      throw const ZCodecException('Unexpected end of input');
    }
  }
}
