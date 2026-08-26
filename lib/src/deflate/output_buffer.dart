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
    int source = length - distance;
    if (distance >= count) {
      _bytes.setRange(length, length + count, _bytes, source);
      length += count;
      return;
    }
    // Overlapping runs must be expanded byte by byte because each copied byte
    // can be part of the source of a later one.
    for (int index = 0; index < count; index++) {
      _bytes[length++] = _bytes[source++];
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
  Uint8List takeBytes() => Uint8List.sublistView(_bytes, 0, length);
}
