part of 'package:zcodec/src/zstd.dart';

/// Owns decoded bytes and validates every append before storage grows.
final class _ZstdOutput {
  /// Aggregate decoded byte ceiling.
  final int maximum;

  /// Initialized output length.
  int length = 0;

  /// Growable backing storage, independent of advertised frame sizes.
  Uint8List bytes = Uint8List(0);

  /// Creates an initially empty bounded output.
  _ZstdOutput({required this.maximum});

  /// Reserves only storage that will actually be written.
  void reserve(int count) {
    if (count < 0 || count > maximum - length) {
      throw const ZCodecException('Zstandard output exceeds the byte limit');
    }
    final int needed = length + count;
    if (needed > bytes.length) {
      final int grown = bytes.length * 2 < 8192 ? 8192 : bytes.length * 2;
      final int capacity = grown < needed ? needed : grown;
      bytes = Uint8List(capacity > maximum ? maximum : capacity)..setRange(0, length, bytes);
    }
  }

  /// Appends an exact literal range.
  void add(Uint8List data) {
    reserve(data.length);
    bytes.setRange(length, length + data.length, data);
    length += data.length;
  }

  /// Returns only initialized bytes.
  Uint8List finish() => Uint8List.sublistView(bytes, 0, length);
}

/// Frame-local entropy tables, repeat offsets and optional dictionary history.
final class _ZstdFrame {
  /// Bound on each frame's advertised history window.
  final int maxWindowBytes;

  /// Owned complete dictionary, supplied explicitly rather than resolved by ID.
  final Uint8List? dictionary;

  /// Most recent literal tree.
  _ZstdHuffmanTable? huffman;

  /// Most recent literal-length entropy table.
  _ZstdEntropyTable? literalTable;

  /// Most recent offset entropy table.
  _ZstdEntropyTable? offsetTable;

  /// Most recent match-length entropy table.
  _ZstdEntropyTable? matchTable;

  /// Three recent match distances, in recency order.
  final List<int> repeatOffsets = [1, 4, 8];

  /// Dictionary history excluding its entropy header.
  Uint8List history = Uint8List(0);

  /// Byte position where this frame starts in aggregate output.
  late int start;

  /// Maximum back-reference distance into decoded frame data.
  late int window;

  /// Maximum encoded or decoded bytes in one block.
  late int blockLimit;

  /// Creates a fresh state for one independently decodable frame.
  _ZstdFrame({required this.maxWindowBytes, required this.dictionary});

  /// Reads dictionary tables in the order defined by RFC 8878 section 5.
  void _loadDictionary(int identifier) {
    final Uint8List? data = dictionary;
    if (data == null) {
      if (identifier != 0) {
        throw const ZCodecException('Zstandard frame requires a dictionary');
      }
      return;
    }
    if (data.length < 8 || data.length > maxWindowBytes) {
      throw const ZCodecException('Invalid or excessive Zstandard dictionary size');
    }
    final ByteReader reader = ByteReader(data);
    if (reader.readUint32() != 0xec30a437) {
      if (identifier != 0) {
        throw const ZCodecException('Zstandard raw dictionary has no dictionary ID');
      }
      history = data;
      return;
    }
    final int actual = reader.readUint32();
    if (actual == 0 || identifier != 0 && actual != identifier) {
      throw const ZCodecException('Zstandard dictionary ID mismatch');
    }
    huffman = _ZstdHuffmanTable.read(reader: reader);
    offsetTable = _ZstdEntropyTable.read(reader: reader, maxAccuracy: 8, maxSymbol: 31);
    matchTable = _ZstdEntropyTable.read(reader: reader, maxAccuracy: 9, maxSymbol: 52);
    literalTable = _ZstdEntropyTable.read(reader: reader, maxAccuracy: 9, maxSymbol: 35);
    for (int index = 0; index < 3; index++) {
      repeatOffsets[index] = reader.readUint32();
    }
    history = reader.readBytes(reader.remaining);
    if (repeatOffsets.any((offset) => offset == 0 || offset > history.length)) {
      throw const ZCodecException('Invalid Zstandard dictionary repeat offsets');
    }
  }

  /// Decodes one frame following its already consumed magic number.
  void decode({required ByteReader reader, required _ZstdOutput output}) {
    start = output.length;
    final int descriptor = reader.readByte();
    if (descriptor & 8 != 0) {
      throw const ZCodecException('Reserved Zstandard frame bit is set');
    }
    final bool single = descriptor & 32 != 0;
    final int sizeFlag = descriptor >> 6;
    int declaredWindow = 0;
    if (!single) {
      final int description = reader.readByte();
      final int exponent = 10 + (description >> 3);
      if (exponent > 30) {
        throw const ZCodecException('Zstandard frame exceeds the supported window size');
      }
      final int base = 1 << exponent;
      declaredWindow = base + (base ~/ 8) * (description & 7);
    }
    final int identifier = _zstdInteger(reader, [0, 1, 2, 4][descriptor & 3]);
    final int sizeBytes = sizeFlag == 0 ? (single ? 1 : 0) : [0, 2, 4, 8][sizeFlag];
    final int? contentBytes = sizeBytes == 0 ? null : _zstdInteger(reader, sizeBytes) + (sizeBytes == 2 ? 256 : 0);
    window = single ? contentBytes! : declaredWindow;
    if (window < 0 || window > maxWindowBytes) {
      throw const ZCodecException('Zstandard frame exceeds the window limit');
    }
    if (contentBytes != null && contentBytes > output.maximum - output.length) {
      throw const ZCodecException('Zstandard frame exceeds the output limit');
    }
    blockLimit = window < _zstdBlockBytes ? window : _zstdBlockBytes;
    _loadDictionary(identifier);
    bool last = false;
    while (!last) {
      final int header = _zstdInteger(reader, 3);
      last = header & 1 != 0;
      final int type = (header >> 1) & 3;
      final int size = header >> 3;
      if (size > blockLimit) {
        throw const ZCodecException('Zstandard block exceeds its size limit');
      }
      final int before = output.length;
      switch (type) {
        case 0:
          output.add(reader.readBytes(size));
        case 1:
          final int value = reader.readByte();
          output.reserve(size);
          output.bytes.fillRange(output.length, output.length + size, value);
          output.length += size;
        case 2:
          _compressed(reader: ByteReader(reader.readBytes(size)), output: output);
        default:
          throw const ZCodecException('Reserved Zstandard block type');
      }
      if (output.length - before > blockLimit || contentBytes != null && output.length - start > contentBytes) {
        throw const ZCodecException('Zstandard decoded size disagrees with its header');
      }
    }
    if (contentBytes != null && output.length - start != contentBytes) {
      throw const ZCodecException('Zstandard frame content size mismatch');
    }
    if (descriptor & 4 != 0) {
      final int stored = reader.readUint32();
      if (stored != _zstdChecksum(Uint8List.sublistView(output.bytes, start, output.length))) {
        throw const ZCodecException('Zstandard content checksum mismatch');
      }
    }
  }

  /// Regenerates literals and retains trees for subsequent treeless blocks.
  Uint8List _literals(ByteReader reader) {
    final int first = reader.readByte();
    final int type = first & 3;
    final int format = (first >> 2) & 3;
    if (type < 2) {
      final int count = switch (format) {
        0 || 2 => first >> 3,
        1 => (first >> 4) + reader.readByte() * 16,
        _ => (first >> 4) + reader.readByte() * 16 + reader.readByte() * 4096,
      };
      if (count > blockLimit) {
        throw const ZCodecException('Zstandard literals exceed the block limit');
      }
      return type == 0 ? reader.readBytes(count) : (Uint8List(count)..fillRange(0, count, reader.readByte()));
    }
    final int headerBytes = format < 2 ? 3 : format + 2;
    final int width = format < 2
        ? 10
        : format == 2
        ? 14
        : 18;
    final int fields = first + _zstdInteger(reader, headerBytes - 1) * 256;
    // Integer division keeps these 40-bit header fields exact on JavaScript.
    final int count = (fields ~/ 16) % (1 << width);
    final int compressed = fields ~/ (1 << (width + 4));
    if (count > blockLimit) {
      throw const ZCodecException('Zstandard compressed literals exceed the block limit');
    }
    final ByteReader content = ByteReader(reader.readBytes(compressed));
    if (type == 2) {
      huffman = _ZstdHuffmanTable.read(reader: content);
    }
    final _ZstdHuffmanTable table = huffman ?? (throw const ZCodecException('Missing Zstandard literal tree'));
    if (format == 0) {
      return table.decode(input: content.readBytes(content.remaining), count: count);
    }
    final List<int> lengths = [content.readUint16(), content.readUint16(), content.readUint16()];
    lengths.add(content.remaining - lengths.fold(0, (sum, length) => sum + length));
    final int share = (count + 3) ~/ 4;
    if (lengths.any((length) => length <= 0) || count - share * 3 < 0) {
      throw const ZCodecException('Invalid Zstandard literal jump table');
    }
    final BytesBuilder output = BytesBuilder(copy: false);
    for (int index = 0; index < 4; index++) {
      output.add(table.decode(input: content.readBytes(lengths[index]), count: index == 3 ? count - share * 3 : share));
    }
    return output.takeBytes();
  }

  /// Selects a predefined, repeated, newly decoded or retained entropy table.
  _ZstdEntropyTable _table({required ByteReader reader, required int mode, required _ZstdEntropyTable defaults, required _ZstdEntropyTable? previous, required int maxSymbol, required int accuracy}) {
    switch (mode) {
      case 0:
        return defaults;
      case 1:
        final int symbol = reader.readByte();
        if (symbol > maxSymbol) {
          throw const ZCodecException('Invalid Zstandard repeated sequence code');
        }
        return _ZstdEntropyTable.repeated(symbol: symbol);
      case 2:
        return _ZstdEntropyTable.read(reader: reader, maxAccuracy: accuracy, maxSymbol: maxSymbol);
      default:
        return previous ?? (throw const ZCodecException('Missing Zstandard sequence table'));
    }
  }

  /// Executes interleaved sequence codes within the frame and block boundaries.
  void _compressed({required ByteReader reader, required _ZstdOutput output}) {
    final Uint8List literals = _literals(reader);
    final int first = reader.readByte();
    final int sequences = first < 128
        ? first
        : first < 255
        ? (first - 128) * 256 + reader.readByte()
        : reader.readUint16() + 0x7f00;
    if (sequences == 0) {
      if (reader.remaining != 0) {
        throw const ZCodecException('Unexpected bytes after empty Zstandard sequences');
      }
      output.add(literals);
      return;
    }
    final int modes = reader.readByte();
    if (modes & 3 != 0) {
      throw const ZCodecException('Reserved Zstandard sequence mode bits');
    }
    final _ZstdEntropyTable lengths = literalTable = _table(reader: reader, mode: modes >> 6, defaults: _zstdLiteralTable, previous: literalTable, maxSymbol: 35, accuracy: 9);
    final _ZstdEntropyTable offsets = offsetTable = _table(reader: reader, mode: (modes >> 4) & 3, defaults: _zstdOffsetTable, previous: offsetTable, maxSymbol: 31, accuracy: 8);
    final _ZstdEntropyTable matches = matchTable = _table(reader: reader, mode: (modes >> 2) & 3, defaults: _zstdMatchTable, previous: matchTable, maxSymbol: 52, accuracy: 9);
    final _ZstdReverseBits bits = _ZstdReverseBits(bytes: reader.readBytes(reader.remaining));
    int lengthState = bits.read(lengths.accuracy);
    int offsetState = bits.read(offsets.accuracy);
    int matchState = bits.read(matches.accuracy);
    int literalOffset = 0;
    final int blockStart = output.length;
    for (int index = 0; index < sequences; index++) {
      final _ZstdTransition length = lengths.states[lengthState];
      final _ZstdTransition offset = offsets.states[offsetState];
      final _ZstdTransition match = matches.states[matchState];
      final int offsetValue = (1 << offset.symbol) + bits.read(offset.symbol);
      final int matchLength = _zstdMatchBase[match.symbol] + bits.read(_zstdMatchBits[match.symbol]);
      final int literalLength = _zstdLiteralBase[length.symbol] + bits.read(_zstdLiteralBits[length.symbol]);
      if (literalLength > literals.length - literalOffset || literalLength + matchLength > blockLimit - (output.length - blockStart)) {
        throw const ZCodecException('Zstandard sequence exceeds its literal or block bounds');
      }
      output.add(Uint8List.sublistView(literals, literalOffset, literalOffset + literalLength));
      literalOffset += literalLength;
      final int distance;
      if (offsetValue > 3) {
        distance = offsetValue - 3;
        repeatOffsets.insert(0, distance);
        repeatOffsets.removeLast();
      } else {
        final int repeated = offsetValue - 1 + (literalLength == 0 ? 1 : 0);
        distance = repeated == 3 ? repeatOffsets.first - 1 : repeatOffsets.removeAt(repeated);
        repeatOffsets.insert(0, distance);
        if (repeatOffsets.length > 3) {
          repeatOffsets.removeLast();
        }
      }
      final int produced = output.length - start;
      if (distance <= 0 || distance > produced + history.length || distance > window && (produced > window || distance <= produced)) {
        throw const ZCodecException('Invalid Zstandard match distance');
      }
      output.reserve(matchLength);
      for (int copied = 0; copied < matchLength; copied++) {
        final int from = output.length - distance;
        output.bytes[output.length++] = from < start ? history[history.length + from - start] : output.bytes[from];
      }
      if (index + 1 < sequences) {
        lengthState = length.base + bits.read(length.bits);
        matchState = match.base + bits.read(match.bits);
        offsetState = offset.base + bits.read(offset.bits);
      }
    }
    if (bits.remaining != 0 || literals.length - literalOffset > blockLimit - (output.length - blockStart)) {
      throw const ZCodecException('Invalid Zstandard sequence termination');
    }
    output.add(Uint8List.sublistView(literals, literalOffset));
  }
}
