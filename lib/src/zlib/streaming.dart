part of 'package:zcodec/src/zlib.dart';

/// Emits a zlib frame around incremental DEFLATE blocks.
final class _ZlibEncodingSink extends ByteConversionSink {
  /// Running checksum of the uncompressed input.
  final Adler32Accumulator _checksum = Adler32Accumulator();

  /// Raw compression session.
  late final ByteConversionSink _inner;

  /// Whether the trailer has been emitted.
  bool _closed = false;

  /// Prepares framing callbacks without emitting before conversion starts.
  _ZlibEncodingSink(Sink<List<int>> sink, int level) {
    final int hint = level <= 1 ? 0 : (level <= 5 ? 1 : (level <= 7 ? 2 : 3));
    final int flags = hint << 6;
    bool started = false;
    _inner = DeflateEncoder(level: level).startChunkedConversion(
      CallbackByteSink(
        (bytes) {
          if (!started) {
            started = true;
            sink.add(<int>[0x78, flags | ((31 - ((0x7800 | flags) % 31)) % 31)]);
          }
          sink.add(bytes);
        },
        onDone: () {
          sink.add((ByteWriter()..writeUint32BigEndian(_checksum.value)).takeBytes());
          sink.close();
        },
      ),
    );
  }

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed zlib encoder');
    }
    _checksum.add(chunk);
    _inner.add(chunk);
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _inner.close();
    }
  }
}

/// Decodes a zlib frame while retaining only its header, trailer, and history.
final class _ZlibDecodingSink extends ByteConversionSink {
  /// Destination closed after successful checksum validation.
  final Sink<List<int>> _sink;

  /// Checksum over all emitted bytes.
  final Adler32Accumulator _checksum = Adler32Accumulator();

  /// Incremental raw decoder.
  late final DeflateDecodingSession _inner;

  /// Two-byte header followed by the four-byte checksum.
  final Uint8List _frame = Uint8List(6);

  /// Number of framing bytes received.
  int _filled = 0;

  /// Whether the caller has closed this conversion.
  bool _closed = false;

  /// Creates a framed decoder with a cumulative output limit.
  _ZlibDecodingSink(this._sink, int? maximum) {
    _inner = DeflateDecodingSession(
      CallbackByteSink((bytes) {
        _checksum.add(bytes);
        _sink.add(bytes);
      }),
      maxOutputBytes: maximum,
    );
  }

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed zlib decoder');
    }
    final Uint8List bytes = asBytes(chunk);
    int offset = 0;
    while (_filled < 2 && offset < bytes.length) {
      _frame[_filled++] = bytes[offset++];
      if (_filled == 2) {
        final int method = _frame[0];
        final int flags = _frame[1];
        if ((method & 15) != 8 || method >>> 4 > 7 || ((method << 8) | flags) % 31 != 0) {
          throw const ZCodecException('Invalid zlib header');
        }
        if ((flags & 0x20) != 0) {
          throw const ZCodecException('Preset zlib dictionaries are not supported');
        }
      }
    }
    if (_filled < 2) {
      return;
    }
    if (!_inner.isDone) {
      final Uint8List tail = _inner.add(Uint8List.sublistView(bytes, offset));
      if (!_inner.isDone) {
        return;
      }
      offset = bytes.length - tail.length;
    }
    while (_filled < 6 && offset < bytes.length) {
      _frame[_filled++] = bytes[offset++];
      if (_filled == 6) {
        final int expected = ((_frame[2] << 24) | (_frame[3] << 16) | (_frame[4] << 8) | _frame[5]) & 0xffffffff;
        if (_checksum.value != expected) {
          throw const ZCodecException('Invalid zlib Adler-32 checksum');
        }
      }
    }
    if (offset < bytes.length) {
      throw const ZCodecException('Unexpected bytes after the zlib trailer');
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_filled != 6) {
      throw const ZCodecException('Truncated zlib stream');
    }
    _sink.close();
  }
}
