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
