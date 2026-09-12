part of 'package:zcodec/src/gzip.dart';

/// Emits one GZIP member incrementally, including its final CRC and size.
final class _GzipEncodingSink extends ByteConversionSink {
  /// CRC of every uncompressed chunk.
  final Crc32Accumulator _checksum = Crc32Accumulator();

  /// Raw compression session.
  late final ByteConversionSink _inner;

  /// Input size modulo the GZIP trailer's 32-bit field.
  int _size = 0;

  /// Whether the final trailer has been emitted.
  bool _closed = false;

  /// Prepares metadata without emitting before conversion starts.
  _GzipEncodingSink(Sink<List<int>> sink, int level, GzipHeader header) {
    final ByteWriter bytes = ByteWriter();
    _writeGzipHeader(bytes, header, level);
    final Uint8List headerBytes = bytes.takeBytes();
    bool started = false;
    _inner = DeflateEncoder(level: level).startChunkedConversion(
      CallbackByteSink(
        (chunk) {
          if (!started) {
            started = true;
            sink.add(headerBytes);
          }
          sink.add(chunk);
        },
        onDone: () {
          sink.add(
            (ByteWriter()
                  ..writeUint32(_checksum.value)
                  ..writeUint32(_size))
                .takeBytes(),
          );
          sink.close();
        },
      ),
    );
  }

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed GZIP encoder');
    }
    _checksum.add(chunk);
    _size = (_size + chunk.length) & 0xffffffff;
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

/// Stages of a member header, its raw payload, and its trailer.
enum _GzipPhase { header, extraLength, extra, name, comment, headerChecksum, payload, trailer }

/// Decodes concatenated GZIP members without retaining optional metadata.
final class _GzipDecodingSink extends ByteConversionSink {
  /// Destination of uncompressed chunks.
  final Sink<List<int>> _sink;

  /// Optional cumulative expansion ceiling.
  final int? _maximum;

  /// Maximum number of members in the complete input.
  final int _maxMembers;

  /// Header, short integer fields, or member trailer under construction.
  final Uint8List _frame = Uint8List(10);

  /// Current frame phase.
  _GzipPhase _phase = _GzipPhase.header;

  /// Initialized bytes in the current fixed-size field.
  int _filled = 0;

  /// Optional header fields not yet consumed.
  int _flags = 0;

  /// Number of extra-field bytes still expected.
  int _extraRemaining = 0;

  /// Whether the member carries a header CRC.
  bool _checkHeader = false;

  /// Header CRC accumulated without retaining long text fields.
  Crc32Accumulator _headerCrc = Crc32Accumulator();

  /// Data CRC of the current member.
  Crc32Accumulator _dataCrc = Crc32Accumulator();

  /// Current raw inflater.
  DeflateDecodingSession? _inner;

  /// Number of decoded members started so far.
  int _members = 0;

  /// Bytes emitted across all members.
  int _total = 0;

  /// Bytes emitted by this member, modulo 2^32.
  int _memberSize = 0;

  /// Whether the caller has closed this conversion.
  bool _closed = false;

  /// Creates a bounded concatenated-member decoder.
  _GzipDecodingSink(this._sink, this._maximum, this._maxMembers) {
    if (_maximum != null && _maximum < 0) {
      throw RangeError.value(_maximum, 'maxOutputBytes', 'Must not be negative');
    }
    if (_maxMembers <= 0) {
      throw RangeError.value(_maxMembers, 'maxMembers', 'Must be positive');
    }
  }

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed GZIP decoder');
    }
    final Uint8List bytes = asBytes(chunk);
    int offset = 0;
    while (offset < bytes.length) {
      switch (_phase) {
        case _GzipPhase.header:
          if (_members >= _maxMembers) {
            throw ZCodecException('GZIP file exceeds the $_maxMembers-member limit');
          }
          _frame[_filled++] = bytes[offset++];
          if (_filled == 10) {
            if (_frame[0] != 0x1f || _frame[1] != 0x8b || _frame[2] != 8 || (_frame[3] & 0xe0) != 0) {
              throw const ZCodecException('Invalid GZIP member header');
            }
            _members++;
            _flags = _frame[3];
            _checkHeader = (_flags & 2) != 0;
            if (_checkHeader) {
              _headerCrc.add(_frame);
            }
            _nextOptional();
          }
        case _GzipPhase.extraLength:
          _frame[_filled++] = bytes[offset++];
          if (_filled == 2) {
            _addHeaderBytes(Uint8List.sublistView(_frame, 0, 2));
            _extraRemaining = _frame[0] | (_frame[1] << 8);
            if (_extraRemaining == 0) {
              _nextOptional();
            } else {
              _phase = _GzipPhase.extra;
            }
          }
        case _GzipPhase.extra:
          final int count = bytes.length - offset < _extraRemaining ? bytes.length - offset : _extraRemaining;
          _addHeaderBytes(Uint8List.sublistView(bytes, offset, offset + count));
          offset += count;
          _extraRemaining -= count;
          if (_extraRemaining == 0) {
            _nextOptional();
          }
        case _GzipPhase.name:
        case _GzipPhase.comment:
          final int start = offset;
          while (offset < bytes.length && bytes[offset] != 0) {
            offset++;
          }
          final bool terminated = offset < bytes.length;
          if (terminated) {
            offset++;
          }
          _addHeaderBytes(Uint8List.sublistView(bytes, start, offset));
          if (terminated) {
            _nextOptional();
          }
        case _GzipPhase.headerChecksum:
          _frame[_filled++] = bytes[offset++];
          if (_filled == 2) {
            if ((_headerCrc.value & 0xffff) != (_frame[0] | (_frame[1] << 8))) {
              throw const ZCodecException('Invalid GZIP header checksum');
            }
            _nextOptional();
          }
        case _GzipPhase.payload:
          final Uint8List tail = _inner!.add(Uint8List.sublistView(bytes, offset));
          offset = bytes.length - tail.length;
          if (_inner!.isDone) {
            _phase = _GzipPhase.trailer;
            _filled = 0;
          }
        case _GzipPhase.trailer:
          _frame[_filled++] = bytes[offset++];
          if (_filled == 8) {
            final ByteReader trailer = ByteReader(_frame);
            if (trailer.readUint32() != _dataCrc.value) {
              throw const ZCodecException('Invalid GZIP data checksum');
            }
            if (trailer.readUint32() != _memberSize) {
              throw const ZCodecException('Invalid GZIP uncompressed size');
            }
            _phase = _GzipPhase.header;
            _filled = 0;
            _inner = null;
            _headerCrc = Crc32Accumulator();
          }
      }
    }
  }

  /// Consumes header bytes only when FHCRC requires them.
  void _addHeaderBytes(List<int> bytes) {
    if (_checkHeader) {
      _headerCrc.add(bytes);
    }
  }

  /// Selects the next optional field or initializes the raw payload decoder.
  void _nextOptional() {
    _filled = 0;
    if ((_flags & 4) != 0) {
      _flags &= ~4;
      _phase = _GzipPhase.extraLength;
    } else if ((_flags & 8) != 0) {
      _flags &= ~8;
      _phase = _GzipPhase.name;
    } else if ((_flags & 16) != 0) {
      _flags &= ~16;
      _phase = _GzipPhase.comment;
    } else if ((_flags & 2) != 0) {
      _flags &= ~2;
      _phase = _GzipPhase.headerChecksum;
    } else {
      _dataCrc = Crc32Accumulator();
      _memberSize = 0;
      _inner = DeflateDecodingSession(
        CallbackByteSink((bytes) {
          _dataCrc.add(bytes);
          _memberSize = (_memberSize + bytes.length) & 0xffffffff;
          _total += bytes.length;
          _sink.add(bytes);
        }),
        maxOutputBytes: _maximum == null ? null : _maximum - _total,
      );
      _phase = _GzipPhase.payload;
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_members == 0 || _phase != _GzipPhase.header || _filled != 0) {
      throw const ZCodecException('Truncated GZIP stream');
    }
    _sink.close();
  }
}
