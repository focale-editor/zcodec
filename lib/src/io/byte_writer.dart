part of 'package:zcodec/src/io.dart';

/// Builds a byte buffer with integer helpers.
final class ByteWriter {
  /// Accumulates every written byte.
  ///
  /// A copying builder is used deliberately: the non-copying variant allocates
  /// a one-element list for every `addByte`, and record headers are written
  /// field by field.
  final BytesBuilder _bytes = BytesBuilder();

  /// Creates an empty byte writer.
  ByteWriter();

  /// Number of bytes written so far.
  int get length => _bytes.length;

  /// Appends one byte.
  void writeByte(int value) => _bytes.addByte(value & 0xff);

  /// Appends [bytes].
  void writeBytes(List<int> bytes) => _bytes.add(bytes);

  /// Appends [count] zero bytes.
  void writeZeroes(int count) {
    if (count > 0) {
      _bytes.add(Uint8List(count));
    }
  }

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

  /// Appends a little-endian 64-bit integer.
  void writeUint64(int value) {
    if (value < 0) {
      throw RangeError.value(value, 'value', 'Must not be negative');
    }
    int remaining = value;
    for (int index = 0; index < 8; index++) {
      _bytes.addByte(remaining & 0xff);
      remaining ~/= 256;
    }
  }

  /// Appends a big-endian 32-bit integer.
  void writeUint32BigEndian(int value) {
    _bytes
      ..addByte((value >>> 24) & 0xff)
      ..addByte((value >>> 16) & 0xff)
      ..addByte((value >>> 8) & 0xff)
      ..addByte(value & 0xff);
  }

  /// Returns all written bytes and empties the writer.
  Uint8List takeBytes() => _bytes.takeBytes();
}
