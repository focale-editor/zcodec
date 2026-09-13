part of 'package:zcodec/src/io.dart';

/// Writes a least-significant-bit-first bit stream to memory.
final class BitWriter {
  /// Output storage whose first [length] bytes are complete.
  Uint8List _bytes;

  /// Number of complete bytes in [_bytes].
  int _length = 0;

  /// Pending bits not yet emitted as complete bytes.
  int _bits = 0;

  /// Number of meaningful pending bits, always below 16 between writes.
  int _bitCount = 0;

  /// Creates an empty bit writer.
  ///
  /// Output that is known to fit [initialCapacity] bytes is never copied.
  BitWriter({int initialCapacity = 1024}) : _bytes = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  /// Number of complete bytes emitted so far.
  int get length => _length;

  /// Number of bits pending beyond the last complete byte.
  int get pendingBits => _bitCount & 7;

  /// Returns complete bytes without inserting padding into the bit stream.
  Uint8List takeCompleteBytes() {
    while (_bitCount >= 8) {
      _writePendingByte();
    }
    final Uint8List result = _bytes.sublist(0, _length);
    _length = 0;
    return result;
  }

  /// Writes the [count] least significant bits of [value], at most 16.
  ///
  /// Whole bytes are flushed only once 16 bits are pending, which halves the
  /// flushes of short codes while keeping every shift within 32 bits.
  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 16, 'At most 16 bits can be written at once');
    _bits |= (value & ((1 << count) - 1)) << _bitCount;
    _bitCount += count;
    if (_bitCount >= 16) {
      if (_length + 2 > _bytes.length) {
        _grow(2);
      }
      _bytes[_length] = _bits & 0xff;
      _bytes[_length + 1] = (_bits >>> 8) & 0xff;
      _length += 2;
      _bits >>>= 16;
      _bitCount -= 16;
    }
  }

  /// Removes and returns the pending bits, leaving the writer byte-aligned.
  ///
  /// Bulk writers accumulate bits in local variables starting from these, then
  /// append their complete bytes with [writeBytes] and the remainder with
  /// [writeBits].
  ({int bits, int count}) takePendingBits() {
    final ({int bits, int count}) pending = (bits: _bits, count: _bitCount);
    _bits = 0;
    _bitCount = 0;
    return pending;
  }

  /// Pads with zero bits through the next byte boundary.
  void alignToByte() {
    while (_bitCount > 0) {
      _writePendingByte();
    }
    _bits = 0;
    _bitCount = 0;
  }

  /// Writes one byte, which requires byte alignment.
  void writeByte(int value) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    if (_length == _bytes.length) {
      _grow(1);
    }
    _bytes[_length++] = value & 0xff;
  }

  /// Writes [bytes], which requires byte alignment.
  void writeBytes(List<int> bytes) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    if (_length + bytes.length > _bytes.length) {
      _grow(bytes.length);
    }
    _bytes.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
  }

  /// Aligns and returns all completed bytes, leaving the writer empty.
  ///
  /// The result is a view of the storage, which avoids a final copy at the
  /// cost of retaining up to one doubling of unused capacity.
  Uint8List takeBytes() {
    alignToByte();
    final Uint8List result = Uint8List.sublistView(_bytes, 0, _length);
    _bytes = Uint8List(1024);
    _length = 0;
    return result;
  }

  /// Moves the lowest pending byte, possibly partial, into storage.
  void _writePendingByte() {
    if (_length == _bytes.length) {
      _grow(1);
    }
    _bytes[_length++] = _bits & 0xff;
    _bits >>>= 8;
    _bitCount = _bitCount > 8 ? _bitCount - 8 : 0;
  }

  /// Doubles storage until [additional] more bytes fit.
  void _grow(int additional) {
    int capacity = _bytes.length * 2;
    while (capacity < _length + additional) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }
}
