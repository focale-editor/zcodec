part of 'package:zcodec/src/deflate.dart';

/// Grows decoded output while enforcing an allocation ceiling.
final class _OutputBuffer {
  /// Largest permitted output length.
  final int maximumLength;

  /// Growable output storage.
  Uint8List _bytes;

  /// Number of initialized output bytes.
  int length = 0;

  /// Creates an output buffer capped at [maximumLength].
  _OutputBuffer(this.maximumLength) : _bytes = Uint8List(maximumLength < 8192 ? maximumLength : 8192);

  /// Number of bytes that fit before storage must grow.
  int get capacity => _bytes.length;

  /// Appends one literal byte.
  void add(int value) {
    if (length == _bytes.length) {
      _ensure(1);
    }
    _bytes[length++] = value;
  }

  /// Appends every byte of [bytes].
  void addBytes(Uint8List bytes) {
    _ensure(bytes.length);
    _bytes.setRange(length, length + bytes.length, bytes);
    length += bytes.length;
  }

  /// Copies [count] bytes from a preceding [distance].
  void copy(int distance, int count) {
    if (distance <= 0 || distance > length) {
      throw const ZCodecException('Invalid DEFLATE back-reference distance');
    }
    _ensure(count);
    final int source = length - distance;
    if (distance >= count) {
      _bytes.setRange(length, length + count, _bytes, source);
      length += count;
      return;
    }
    if (distance == 1) {
      _bytes.fillRange(length, length + count, _bytes[source]);
      length += count;
      return;
    }
    // Each segment reads only initialized bytes. Doubling the available run
    // also handles overlapping references without a copy call per byte.
    int copied = 0;
    int available = distance;
    while (copied < count) {
      final int remaining = count - copied;
      final int part = remaining < available ? remaining : available;
      _bytes.setRange(length + copied, length + copied + part, _bytes, source);
      copied += part;
      available += part;
    }
    length += count;
  }

  /// Grows storage for [additional] bytes, sized after the final output.
  ///
  /// [expectedLength] estimates the final length and receives a sixteenth of
  /// headroom, while [lengthBound] is a hard upper bound on it. Storage grows
  /// by at least a quarter, so that repeated underestimates stay logarithmic,
  /// and by at most four times, which bounds what an overestimate wastes.
  /// Fitting the final length closely avoids both reallocation copies and the
  /// trimming copy of [takeBytes]. Storage never exceeds [maximumLength], and
  /// this method never throws: a token that does not fit fails when written.
  void reserve(int additional, {required int expectedLength, required int lengthBound}) {
    final int minimum = _bytes.length + (_bytes.length >>> 2);
    final int maximum = _bytes.length * 4;
    final int estimate = expectedLength + (expectedLength >>> 4);
    int capacity = estimate < minimum ? minimum : (estimate > maximum ? maximum : estimate);
    if (capacity > lengthBound) {
      capacity = lengthBound;
    }
    if (capacity < length + additional) {
      capacity = length + additional;
    }
    if (capacity > maximumLength) {
      capacity = maximumLength;
    }
    if (capacity > _bytes.length) {
      _bytes = Uint8List(capacity)..setRange(0, length, _bytes);
    }
  }

  /// Grows storage for [additional] bytes without exceeding the limit.
  void _ensure(int additional) {
    if (additional > maximumLength - length) {
      throw ZCodecException('DEFLATE output exceeds the $maximumLength-byte limit');
    }
    final int required = length + additional;
    if (required <= _bytes.length) {
      return;
    }
    int capacity = _bytes.length < 64 ? 64 : _bytes.length;
    while (capacity < required) {
      capacity *= 2;
    }
    if (capacity > maximumLength) {
      capacity = maximumLength;
    }
    _bytes = Uint8List(capacity)..setRange(0, length, _bytes);
  }

  /// Returns the initialized portion of the output.
  Uint8List takeBytes() {
    if (length == 0) {
      return Uint8List(0);
    }
    if (_bytes.length - length > length ~/ 4) {
      return _bytes.sublist(0, length);
    }
    return Uint8List.sublistView(_bytes, 0, length);
  }
}
