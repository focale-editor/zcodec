part of 'package:zcodec/src/zstd.dart';

/// Buffers a complete logical stream while enforcing the encoded input ceiling.
final class _ZstdDecodingSink extends ByteConversionSink {
  /// Decoder carrying the resource policy and dictionary snapshot.
  final ZstdDecoder decoder;

  /// Destination receiving one fully validated result.
  final Sink<List<int>> output;

  /// Copied input protects against callers reusing mutable chunks.
  final BytesBuilder _input = BytesBuilder();

  /// Whether closing or an input-limit failure has finalized this sink.
  bool _closed = false;

  /// Creates a bounded buffered decoder.
  _ZstdDecodingSink({required this.decoder, required this.output});

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed Zstandard sink');
    }
    if (decoder.maxInputBytes case final int limit when chunk.length > limit - _input.length) {
      _closed = true;
      _input.clear();
      throw const ZCodecException('Zstandard input exceeds the byte limit');
    }
    _input.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(chunk.sublist(start, end));
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
    output
      ..add(decoder.convert(_input.takeBytes()))
      ..close();
  }
}
