part of 'package:zcodec/src/deflate.dart';

/// Buffers at most one block and its dictionary, emitting completed blocks.
final class _DeflateEncodingSink extends ByteConversionSink {
  /// Destination of complete output bytes.
  final Sink<List<int>> _sink;

  /// Dictionary and bit state shared across input chunks.
  _DeflateBlockWriter? _writer;

  /// Compression effort used when the first block is ready.
  final int _level;

  /// Input storage, including the preceding dictionary window.
  final Uint8List _input = Uint8List(_windowSize + _maximumStoredBlock);

  /// Bytes of history preceding the current block.
  int _history = 0;

  /// Number of initialized bytes in input storage.
  int _length = 0;

  /// Whether the final block has been emitted.
  bool _closed = false;

  /// Creates a bounded incremental encoder.
  _DeflateEncodingSink(this._sink, this._level);

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('Cannot add to a closed DEFLATE encoder');
    }
    RangeError.checkValidRange(start, end, chunk.length);
    int offset = start;
    while (offset < end) {
      if (_length - _history == _maximumStoredBlock) {
        _emit(false);
      }
      final int available = _maximumStoredBlock - (_length - _history);
      final int count = end - offset < available ? end - offset : available;
      _input.setRange(_length, _length + count, chunk, offset);
      _length += count;
      offset += count;
    }
    if (isLast) {
      close();
    }
  }

  /// Writes a block and preserves the history required by the next block.
  void _emit(bool isFinal) {
    final _DeflateBlockWriter writer = _writer ??= _DeflateBlockWriter(_level, inputLength: isFinal ? _length : null);
    writer.writeBlock(_input, _history, _length, isFinal: isFinal);
    final Uint8List bytes = isFinal ? writer.output.takeBytes() : writer.output.takeCompleteBytes();
    if (bytes.isNotEmpty) {
      _sink.add(bytes);
    }
    if (!isFinal) {
      final int keep = _length < _windowSize ? _length : _windowSize;
      _input.setRange(0, keep, _input, _length - keep);
      _history = keep;
      _length = keep;
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _emit(true);
    _sink.close();
  }
}

/// Internal signal for an incomplete input token, distinct from malformed data.
final class _NeedDeflateInput implements Exception {
  /// Creates a suspension signal without a stack trace allocation.
  const _NeedDeflateInput();
}

/// Bit reader that suspends without consuming a partial token.
final class _IncrementalBitReader extends BitReader {
  /// Creates an incremental reader over the available bytes.
  _IncrementalBitReader(super.bytes);

  @override
  void requireBits(int count) {
    if (remainingBits < count) {
      throw const _NeedDeflateInput();
    }
    super.requireBits(count);
  }
}

/// Resumable decoder states at token boundaries.
enum _InflateState { header, storedHeader, storedData, dynamicHeader, huffman, done }

/// Largest output chunk emitted by an incremental inflater.
const int _outputChunkSize = 1 << 16;

/// Largest prefix of a new input chunk copied behind an incomplete token.
///
/// Once that token completes, decoding continues on a view of the new chunk.
const int _pendingJoinSize = 1024;

/// Incremental raw inflater used by the byte codecs and their container frames.
///
/// This implementation detail is exported only by the internal source library.
/// Output chunks are independent copies of about 64 KiB, ending at the first
/// token boundary past that size; the retained history is at most 32 KiB plus
/// one chunk.
final class DeflateDecodingSession {
  /// Receives decoded chunks without being closed by the session.
  final Sink<List<int>> _sink;

  /// Total expansion limit across every emitted chunk.
  final int _maximum;

  /// Dictionary plus at most one pending output chunk and one match.
  final _OutputBuffer _output = _OutputBuffer(_windowSize + _outputChunkSize + _maximumMatch);

  /// Compressed bytes belonging to an incomplete token or header.
  Uint8List _pending = Uint8List(0);

  /// Bits already consumed in the first pending byte.
  int _skipBits = 0;

  /// Current decoding phase.
  _InflateState _state = _InflateState.header;

  /// Whether the current block is final.
  bool _finalBlock = false;

  /// Stored bytes still expected in the current block.
  int _storedRemaining = 0;

  /// Current literal alphabet.
  _HuffmanTable? _literals;

  /// Current distance alphabet.
  _HuffmanTable? _distances;

  /// Already emitted prefix of the output buffer.
  int _emitted = 0;

  /// Total output length, including discarded dictionary prefixes.
  int _produced = 0;

  /// Creates an incremental inflater capped by [maxOutputBytes].
  DeflateDecodingSession(Sink<List<int>> sink, {int? maxOutputBytes}) : _sink = sink, _maximum = maxOutputBytes ?? _unboundedOutput {
    if (_maximum < 0) {
      throw RangeError.value(_maximum, 'maxOutputBytes', 'Must not be negative');
    }
  }

  /// Whether the final block has been completely decoded.
  bool get isDone => _state == _InflateState.done;

  /// Output length at which the next chunk is emitted.
  int get _flushLength => _emitted + _outputChunkSize < _windowSize + _outputChunkSize ? _emitted + _outputChunkSize : _windowSize + _outputChunkSize;

  /// Decodes [bytes], returning only bytes following a completed raw stream.
  Uint8List add(Uint8List bytes) {
    if (isDone) {
      return bytes;
    }
    int offset = 0;
    while (true) {
      final int priorLength = _pending.length;
      final int end = priorLength == 0 || bytes.length - offset <= _pendingJoinSize ? bytes.length : offset + _pendingJoinSize;
      final Uint8List available = priorLength == 0 ? Uint8List.sublistView(bytes, offset) : joinBytes(_pending, Uint8List.sublistView(bytes, offset, end));
      final _IncrementalBitReader input = _IncrementalBitReader(available)..seekBits(_skipBits);
      _process(input);
      if (isDone) {
        input.alignToByte();
        final int consumed = offset + input.byteOffset - priorLength;
        _pending = Uint8List(0);
        _flush();
        return Uint8List.sublistView(bytes, consumed);
      }
      final int bitOffset = input.bitOffset;
      _skipBits = bitOffset & 7;
      if (end < bytes.length && bitOffset >>> 3 >= priorLength) {
        // The pending token is complete, so the rest of the chunk no longer
        // needs to be copied behind it.
        offset += (bitOffset >>> 3) - priorLength;
        _pending = Uint8List(0);
        continue;
      }
      _pending = available.sublist(bitOffset >>> 3);
      if (end == bytes.length) {
        break;
      }
      offset = end;
    }
    _flush();
    return Uint8List(0);
  }

  /// Rejects an incomplete stream once the caller reaches its end.
  void finish() {
    if (!isDone) {
      throw const ZCodecException('Truncated DEFLATE stream');
    }
  }

  /// Reads complete tokens, rolling back only an incomplete token or header.
  void _process(_IncrementalBitReader input) {
    while (!isDone) {
      final int checkpoint = input.bitOffset;
      try {
        switch (_state) {
          case _InflateState.header:
            final int bits = input.readBits(3);
            _finalBlock = (bits & 1) != 0;
            switch (bits >>> 1) {
              case 0:
                input.alignToByte();
                _state = _InflateState.storedHeader;
              case 1:
                _literals = _fixedLiteralTable;
                _distances = _fixedDistanceTable;
                _state = _InflateState.huffman;
              case 2:
                _state = _InflateState.dynamicHeader;
              default:
                throw const ZCodecException('Reserved DEFLATE block type');
            }
          case _InflateState.storedHeader:
            final int length = input.readBits(16);
            final int complement = input.readBits(16);
            if ((length ^ 0xffff) != complement) {
              throw const ZCodecException('Invalid stored-block length');
            }
            _storedRemaining = length;
            _state = _InflateState.storedData;
          case _InflateState.storedData:
            if (_storedRemaining == 0) {
              _endBlock();
              continue;
            }
            final int available = input.remainingBits >>> 3;
            if (available == 0) {
              throw const _NeedDeflateInput();
            }
            final int capacity = _flushLength - _output.length;
            final int wanted = _storedRemaining < available ? _storedRemaining : available;
            final int count = wanted < capacity ? wanted : capacity;
            _checkOutput(count);
            _output.addBytes(input.readAlignedBytes(count));
            _storedRemaining -= count;
          case _InflateState.dynamicHeader:
            final ({_HuffmanTable literals, _HuffmanTable distances}) trees = _readDynamicTrees(input);
            _literals = trees.literals;
            _distances = trees.distances;
            _state = _InflateState.huffman;
          case _InflateState.huffman:
            final int priorLength = _output.length;
            if (_decodeHuffmanRun(input)) {
              _endBlock();
              break;
            }
            if (_output.length != priorLength) {
              // Let the flush below run before any token decoded slowly.
              break;
            }
            final int symbol = _literals!.read(input);
            if (symbol < 256) {
              _checkOutput(1);
              _output.add(symbol);
            } else if (symbol == 256) {
              _endBlock();
            } else if (symbol <= 285) {
              final int index = symbol - 257;
              final int length = _lengthBases[index] + input.readBits(_lengthExtraBits[index]);
              final _HuffmanTable distances = _distances!;
              if (distances.isEmpty) {
                throw const ZCodecException('Length encountered without a distance tree');
              }
              final int distanceSymbol = distances.read(input);
              if (distanceSymbol >= _distanceBases.length) {
                throw const ZCodecException('Reserved DEFLATE distance symbol');
              }
              final int distance = _distanceBases[distanceSymbol] + input.readBits(_distanceExtraBits[distanceSymbol]);
              _checkOutput(length);
              _output.copy(distance, length);
            } else {
              throw const ZCodecException('Reserved DEFLATE length symbol');
            }
          case _InflateState.done:
            return;
        }
      } on _NeedDeflateInput {
        input.seekBits(checkpoint);
        return;
      }
      if (_output.length >= _flushLength) {
        _flush();
      }
    }
  }

  /// Decodes tokens in bulk up to the next flush and the output limit.
  ///
  /// Returns whether the end-of-block symbol was consumed. The fast loop never
  /// reads within [_fastInputMargin] bytes of the end, so it cannot suspend.
  bool _decodeHuffmanRun(_IncrementalBitReader input) {
    int limit = _flushLength;
    // Tokens start below the limit, so the last one may end a match past it.
    final int allowedLength = _output.length + (_maximum - _produced) - _maximumMatch + 1;
    if (limit > allowedLength) {
      limit = allowedLength;
    }
    final int priorLength = _output.length;
    if (limit <= priorLength) {
      return false;
    }
    _output._ensure(limit + _maximumMatch - priorLength);
    final bool endOfBlock = _decodeHuffmanFast(input, _output, _literals!, _distances!, limit);
    _produced += _output.length - priorLength;
    return endOfBlock;
  }

  /// Checks cumulative output before allocating or emitting a token.
  void _checkOutput(int count) {
    if (count > _maximum - _produced) {
      throw ZCodecException('DEFLATE output exceeds the $_maximum-byte limit');
    }
    _produced += count;
  }

  /// Transitions after a stored block or an end-of-block symbol.
  void _endBlock() => _state = _finalBlock ? _InflateState.done : _InflateState.header;

  /// Emits independent chunks and discards history older than 32 KiB.
  void _flush() {
    if (_output.length > _emitted) {
      final Uint8List bytes = _output._bytes.sublist(_emitted, _output.length);
      _emitted = _output.length;
      _sink.add(bytes);
    }
    if (_output.length >= _windowSize + _outputChunkSize) {
      _output._bytes.setRange(0, _windowSize, _output._bytes, _output.length - _windowSize);
      _output.length = _windowSize;
      _emitted = _windowSize;
    }
  }
}

/// Adapts a prefix inflater to the strict raw-byte conversion contract.
final class _DeflateDecodingSink extends ByteConversionSink {
  /// Output closed after a complete raw stream.
  final Sink<List<int>> _sink;

  /// Stateful raw inflater.
  final DeflateDecodingSession _session;

  /// Whether close has already been called.
  bool _closed = false;

  /// Creates a strict incremental DEFLATE decoder.
  _DeflateDecodingSink(Sink<List<int>> sink, int? maximum) : _sink = sink, _session = DeflateDecodingSession(sink, maxOutputBytes: maximum);

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('Cannot add to a closed DEFLATE decoder');
    }
    if (_session.add(asBytes(chunk)).isNotEmpty) {
      throw const ZCodecException('Unexpected bytes after the final DEFLATE block');
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _session.finish();
    _sink.close();
  }
}
