part of 'package:zcodec/src/codecs.dart';

/// Converts each added value on its own and forwards the result.
final class _MappingSink<S> implements Sink<S> {
  /// Destination receiving converted values.
  final Sink<List<int>> _output;

  /// Conversion applied to every added value.
  final Uint8List Function(S value) _convert;

  /// Creates a sink that maps values through [_convert].
  _MappingSink(this._output, this._convert);

  @override
  void add(S value) => _output.add(_convert(value));

  @override
  void close() => _output.close();
}

/// Accumulates every byte chunk and converts them once on close.
final class _BufferingByteSink<S> extends ByteConversionSink {
  /// Destination receiving the single converted value.
  final Sink<S> _output;

  /// Conversion applied to the accumulated bytes.
  final S Function(List<int> bytes) _convert;

  /// Chunks received so far.
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Whether [close] has already run.
  bool _closed = false;

  /// Creates a sink buffering into [_convert].
  _BufferingByteSink(this._output, this._convert);

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed conversion sink');
    }
    _buffer.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(start == 0 && end == chunk.length ? chunk : chunk.sublist(start, end));
    if (isLast) {
      close();
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _output
      ..add(_convert(_buffer.takeBytes()))
      ..close();
  }
}
