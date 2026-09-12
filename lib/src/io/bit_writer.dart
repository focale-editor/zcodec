part of 'package:zcodec/src/io.dart';

/// Writes a least-significant-bit-first bit stream to memory.
final class BitWriter {
  /// Completed byte chunks.
  ///
  /// A copying builder is used deliberately: the non-copying variant allocates
  /// a one-element list for every `addByte`, and this writer emits its output
  /// one byte at a time.
  final BytesBuilder _bytes = BytesBuilder();

  /// Pending bits not yet emitted as a complete byte.
  int _bits = 0;

  /// Number of meaningful pending bits.
  int _bitCount = 0;

  /// Creates an empty bit writer.
  BitWriter();

  /// Number of complete bytes emitted so far.
  int get length => _bytes.length;

  /// Number of bits pending in the next output byte.
  int get pendingBits => _bitCount;

  /// Returns complete bytes without inserting padding into the bit stream.
  Uint8List takeCompleteBytes() => _bytes.takeBytes();

  /// Writes the [count] least significant bits of [value].
  void writeBits(int value, int count) {
    if (count == 0) {
      return;
    }
    _bits |= (value & ((1 << count) - 1)) << _bitCount;
    _bitCount += count;
    while (_bitCount >= 8) {
      _bytes.addByte(_bits & 0xff);
      _bits >>>= 8;
      _bitCount -= 8;
    }
  }

  /// Pads with zero bits through the next byte boundary.
  void alignToByte() {
    if (_bitCount != 0) {
      _bytes.addByte(_bits & 0xff);
      _bits = 0;
      _bitCount = 0;
    }
  }

  /// Writes one byte, which requires byte alignment.
  void writeByte(int value) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    _bytes.addByte(value & 0xff);
  }

  /// Writes [bytes], which requires byte alignment.
  void writeBytes(List<int> bytes) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    _bytes.add(bytes);
  }

  /// Aligns and returns all completed bytes.
  Uint8List takeBytes() {
    alignToByte();
    return _bytes.takeBytes();
  }
}
