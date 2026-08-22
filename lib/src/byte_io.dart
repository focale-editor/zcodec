import 'dart:typed_data';

/// Builds a byte buffer with integer helpers.
final class ByteWriter {
  /// Accumulates chunks without copying them until completion.
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Creates an empty byte writer.
  ByteWriter();

  /// Number of bytes written so far.
  int get length => _bytes.length;

  /// Appends one byte.
  void writeByte(int value) => _bytes.addByte(value & 0xff);

  /// Appends [bytes].
  void writeBytes(List<int> bytes) => _bytes.add(bytes);

  /// Appends a little-endian 16-bit integer.
  void writeUint16(int value) {
    _bytes
      ..addByte(value & 0xff)
      ..addByte((value >>> 8) & 0xff);
  }

  /// Appends a little-endian 32-bit integer.
  void writeUint32(int value) {
    _bytes
      ..addByte(value & 0xff)
      ..addByte((value >>> 8) & 0xff)
      ..addByte((value >>> 16) & 0xff)
      ..addByte((value >>> 24) & 0xff);
  }

  /// Appends a big-endian 32-bit integer.
  void writeUint32BigEndian(int value) {
    _bytes
      ..addByte((value >>> 24) & 0xff)
      ..addByte((value >>> 16) & 0xff)
      ..addByte((value >>> 8) & 0xff)
      ..addByte(value & 0xff);
  }

  /// Returns all written bytes.
  Uint8List takeBytes() => _bytes.takeBytes();
}

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
      throw const FormatException('Unexpected end of input');
    }
  }
}
