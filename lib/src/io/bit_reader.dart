part of 'package:zcodec/src/io.dart';

/// Reads an in-memory least-significant-bit-first bit stream.
///
/// Bit order follows RFC 1951: within a byte, the least significant bit is
/// consumed first, while multi-bit integer fields are stored least significant
/// bit first as well.
final class BitReader {
  /// Complete input buffer.
  final Uint8List bytes;

  /// Offset of the next byte not yet loaded into [_bits].
  int _byteOffset = 0;

  /// Pending bits, with the next bit in the least significant position.
  int _bits = 0;

  /// Number of meaningful pending bits, always below 32.
  int _bitCount = 0;

  /// Creates a reader over [bytes].
  BitReader(this.bytes);

  /// Number of input bytes consumed, excluding buffered whole bytes.
  int get byteOffset => _byteOffset - (_bitCount >>> 3);

  /// Reads [count] bits, which must not exceed 24.
  int readBits(int count) {
    if (_bitCount < count) {
      _fill(count);
      if (_bitCount < count) {
        throw const ZCodecException('Truncated DEFLATE stream');
      }
    }
    final int value = count == 0 ? 0 : _bits & ((1 << count) - 1);
    _bits >>>= count;
    _bitCount -= count;
    return value;
  }

  /// Returns the next [count] bits without consuming them.
  ///
  /// Bits past the end of the input read as zero; [dropBits] is what rejects a
  /// symbol that would actually need them.
  int peekBits(int count) {
    if (_bitCount < count) {
      _fill(count);
    }
    return count == 0 ? 0 : _bits & ((1 << count) - 1);
  }

  /// Consumes [count] bits previously inspected with [peekBits].
  void dropBits(int count) {
    if (_bitCount < count) {
      throw const ZCodecException('Truncated DEFLATE stream');
    }
    _bits >>>= count;
    _bitCount -= count;
  }

  /// Discards padding bits through the next byte boundary.
  ///
  /// Whole buffered bytes are returned to the input so that [byteOffset] stays
  /// exact, which is what lets a container format resume after the stream.
  void alignToByte() {
    _byteOffset -= _bitCount >>> 3;
    _bits = 0;
    _bitCount = 0;
  }

  /// Reads [length] bytes directly, which requires byte alignment.
  Uint8List readAlignedBytes(int length) {
    assert(_bitCount == 0, 'Aligned reads must follow alignToByte');
    if (length < 0 || length > bytes.length - _byteOffset) {
      throw const ZCodecException('Truncated DEFLATE stream');
    }
    final Uint8List value = Uint8List.sublistView(bytes, _byteOffset, _byteOffset + length);
    _byteOffset += length;
    return value;
  }

  /// Loads whole bytes until at least [count] bits are buffered.
  ///
  /// The buffer is kept below 32 bits so that every shift stays inside the
  /// range where all Dart platforms, including the Web, agree.
  void _fill(int count) {
    while (_bitCount < count && _byteOffset < bytes.length) {
      _bits |= bytes[_byteOffset++] << _bitCount;
      _bitCount += 8;
    }
  }
}
