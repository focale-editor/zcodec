part of 'package:zcodec/src/codecs.dart';

/// Consumes complete parser units while retaining only an incomplete unit.
abstract base class BlockSink extends ByteConversionSink {
  /// Destination, closed when conversion finishes successfully.
  final Sink<List<int>> output;

  /// Maximum retained encoded or uncompressed parser unit.
  final int bufferLimit;

  /// Optional cumulative input ceiling.
  final int? maxInputBytes;

  /// Owned pending bytes; input chunks may be reused by the caller.
  Uint8List buffer = Uint8List(0);

  /// First unread byte.
  int start = 0;

  /// Exclusive populated boundary.
  int end = 0;

  /// Number of input bytes accepted so far.
  int _received = 0;

  /// Closed or failed sinks cannot accept further input.
  bool _closed = false;

  /// Creates bounded parser storage.
  BlockSink(this.output, this.bufferLimit, {this.maxInputBytes}) {
    if (maxInputBytes != null && maxInputBytes! < 0) {
      throw RangeError.value(maxInputBytes!, 'maxInputBytes');
    }
  }

  /// Number of pending bytes.
  int get available => end - start;

  /// Processes every complete unit, returning with only incomplete input.
  void process();

  /// Validates end of input and emits any final framing bytes.
  void finish();

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('Cannot add to a closed or failed codec sink');
    }
    RangeError.checkValidRange(start, end, chunk.length);
    try {
      final int count = end - start;
      if (maxInputBytes != null && count > maxInputBytes! - _received) {
        throw const ZCodecException('Compressed input exceeds the configured limit');
      }
      _received += count;
      int cursor = start;
      while (cursor < end) {
        final int count = (end - cursor).clamp(0, 65536);
        final int pending = available;
        if (pending + count > bufferLimit) {
          throw const ZCodecException('Compressed parser unit exceeds its format limit');
        }
        if (this.end + count > buffer.length) {
          if (pending + count <= buffer.length) {
            buffer.setRange(0, pending, buffer, this.start);
          } else {
            final Uint8List replacement = Uint8List((pending + count > buffer.length * 2 ? pending + count : buffer.length * 2).clamp(0, bufferLimit));
            replacement.setRange(0, pending, buffer, this.start);
            buffer = replacement;
          }
          this.start = 0;
          this.end = pending;
        }
        buffer.setRange(this.end, this.end + count, chunk, cursor);
        this.end += count;
        cursor += count;
        process();
        if (this.start == this.end) {
          this.start = this.end = 0;
        }
      }
      if (isLast) {
        close();
      }
    } catch (_) {
      _closed = true;
      buffer = Uint8List(0);
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      finish();
      output.close();
    } finally {
      buffer = Uint8List(0);
    }
  }
}
