import 'dart:typed_data';

import 'package:zcodec/src/exception.dart';

/// Contains one decoded DEFLATE stream and its compressed byte length.
final class DeflateDecodeResult {
  /// Uncompressed bytes produced by the stream.
  final Uint8List data;

  /// Number of input bytes consumed through the final block boundary.
  final int bytesRead;

  /// Creates a decoded stream result.
  const DeflateDecodeResult({required this.data, required this.bytesRead});
}

/// Encodes and decodes raw RFC 1951 DEFLATE streams in pure Dart.
final class DeflateCodec {
  /// Creates a stateless DEFLATE codec.
  const DeflateCodec();

  /// Compresses [input] with a level from 0 through 9.
  ///
  /// Level 0 writes stored blocks. Other levels use LZ77 matching and fixed
  /// Huffman blocks, with progressively deeper match searches.
  Uint8List encode(List<int> input, {int level = 6}) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    final Uint8List bytes = _asBytes(input);
    if (level == 0) {
      return _encodeStored(bytes);
    }
    final Uint8List compressed = _DeflateEncoder(bytes, level).encode();
    final Uint8List stored = _encodeStored(bytes);
    return compressed.length < stored.length ? compressed : stored;
  }

  /// Decompresses [input], optionally enforcing an allocation ceiling.
  ///
  /// A [ZCodecException] is thrown for malformed input or when the output
  /// would exceed [maxOutputBytes].
  Uint8List decode(List<int> input, {int? maxOutputBytes}) {
    final Uint8List bytes = _asBytes(input);
    final DeflateDecodeResult result = decodePrefix(bytes, maxOutputBytes: maxOutputBytes);
    if (result.bytesRead != bytes.length) {
      throw const ZCodecException('Unexpected bytes after the final DEFLATE block');
    }
    return result.data;
  }

  /// Decompresses the first stream in [input] and reports its consumed length.
  ///
  /// Unlike [decode], this method permits trailing bytes. It is intended for
  /// container formats such as GZIP, whose trailer follows a raw DEFLATE
  /// stream without storing the compressed stream length separately.
  DeflateDecodeResult decodePrefix(List<int> input, {int? maxOutputBytes}) {
    if (maxOutputBytes != null && maxOutputBytes < 0) {
      throw RangeError.value(maxOutputBytes, 'maxOutputBytes', 'Must not be negative');
    }
    final Uint8List bytes = _asBytes(input);
    try {
      final _BitReader reader = _BitReader(bytes);
      final Uint8List result = _DeflateDecoder(reader, maxOutputBytes ?? 0x7fffffff).decode();
      reader.alignToByte();
      return DeflateDecodeResult(data: result, bytesRead: reader.byteOffset);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid DEFLATE stream: $error');
    }
  }
}

/// Returns [input] as an unsigned byte buffer.
Uint8List _asBytes(List<int> input) {
  if (input is Uint8List) {
    return input;
  }
  return Uint8List.fromList(input);
}

/// Encodes [input] as one or more uncompressed DEFLATE blocks.
Uint8List _encodeStored(Uint8List input) {
  final _BitWriter output = _BitWriter();
  int offset = 0;
  do {
    final int length = (input.length - offset).clamp(0, 65535);
    final bool isFinal = offset + length == input.length;
    output
      ..writeBits(isFinal ? 1 : 0, 1)
      ..writeBits(0, 2)
      ..alignToByte()
      ..writeByte(length & 0xff)
      ..writeByte((length >>> 8) & 0xff)
      ..writeByte((~length) & 0xff)
      ..writeByte(((~length) >>> 8) & 0xff)
      ..writeBytes(Uint8List.sublistView(input, offset, offset + length));
    offset += length;
  } while (offset < input.length);
  return output.takeBytes();
}

/// Compresses one buffer with LZ77 matching and the fixed Huffman alphabet.
final class _DeflateEncoder {
  /// Maximum backward distance permitted by RFC 1951.
  static const int _windowSize = 32768;

  /// Maximum byte count represented by one length symbol.
  static const int _maximumMatch = 258;

  /// Uncompressed bytes being encoded.
  final Uint8List input;

  /// Requested compression effort from 1 through 9.
  final int level;

  /// Creates a fixed-Huffman encoder for [input].
  _DeflateEncoder(this.input, this.level);

  /// Compresses all input into one final fixed-Huffman block.
  Uint8List encode() {
    final _BitWriter output = _BitWriter()
      ..writeBits(1, 1)
      ..writeBits(1, 2);
    final Int32List heads = Int32List(32768);
    final Int32List previous = Int32List(input.length);
    final int maximumChain = <int>[0, 4, 8, 16, 32, 64, 128, 256, 512, 1024][level];
    final int goodEnough = <int>[0, 16, 24, 32, 48, 64, 96, 128, 192, 258][level];
    int position = 0;
    while (position < input.length) {
      int bestLength = 0;
      int bestDistance = 0;
      if (position + 2 < input.length) {
        final int hash = _hash(position);
        int candidate = heads[hash] - 1;
        previous[position] = heads[hash];
        heads[hash] = position + 1;
        int chain = maximumChain;
        final int oldest = position - _windowSize;
        final int limit = (input.length - position).clamp(0, _maximumMatch);
        while (candidate >= 0 && candidate >= oldest && chain-- > 0) {
          if (input[candidate] == input[position] && input[candidate + bestLength.clamp(0, limit - 1)] == input[position + bestLength.clamp(0, limit - 1)]) {
            int length = 1;
            while (length < limit && input[candidate + length] == input[position + length]) {
              length++;
            }
            if (length >= 3 && length > bestLength) {
              bestLength = length;
              bestDistance = position - candidate;
              if (length >= goodEnough) {
                break;
              }
            }
          }
          candidate = previous[candidate] - 1;
        }
      }

      if (bestLength >= 3) {
        _writeLength(output, bestLength);
        _writeDistance(output, bestDistance);
        final int end = position + bestLength;
        position++;
        while (position < end) {
          if (position + 2 < input.length) {
            final int hash = _hash(position);
            previous[position] = heads[hash];
            heads[hash] = position + 1;
          }
          position++;
        }
      } else {
        _writeFixedSymbol(output, input[position]);
        position++;
      }
    }
    _writeFixedSymbol(output, 256);
    return output.takeBytes();
  }

  /// Hashes three bytes at [position] into the match-chain table.
  int _hash(int position) => ((input[position] * 251 + input[position + 1]) * 251 + input[position + 2]) & 0x7fff;
}

/// Writes the RFC 1951 symbol and extra bits for [length].
void _writeLength(_BitWriter output, int length) {
  for (int index = 0; index < _lengthBases.length; index++) {
    final int extraBits = _lengthExtraBits[index];
    final int maximum = _lengthBases[index] + ((1 << extraBits) - 1);
    if (length <= maximum) {
      _writeFixedSymbol(output, 257 + index);
      output.writeBits(length - _lengthBases[index], extraBits);
      return;
    }
  }
  throw StateError('Invalid match length $length');
}

/// Writes the RFC 1951 symbol and extra bits for [distance].
void _writeDistance(_BitWriter output, int distance) {
  for (int index = 0; index < _distanceBases.length; index++) {
    final int extraBits = _distanceExtraBits[index];
    final int maximum = _distanceBases[index] + ((1 << extraBits) - 1);
    if (distance <= maximum) {
      output
        ..writeBits(_reverseBits(index, 5), 5)
        ..writeBits(distance - _distanceBases[index], extraBits);
      return;
    }
  }
  throw StateError('Invalid match distance $distance');
}

/// Writes one literal or length symbol using the fixed Huffman alphabet.
void _writeFixedSymbol(_BitWriter output, int symbol) {
  if (symbol <= 143) {
    output.writeBits(_reverseBits(0x30 + symbol, 8), 8);
  } else if (symbol <= 255) {
    output.writeBits(_reverseBits(0x190 + symbol - 144, 9), 9);
  } else if (symbol <= 279) {
    output.writeBits(_reverseBits(symbol - 256, 7), 7);
  } else {
    output.writeBits(_reverseBits(0xc0 + symbol - 280, 8), 8);
  }
}

/// Expands stored, fixed-Huffman, and dynamic-Huffman DEFLATE blocks.
final class _DeflateDecoder {
  /// Bit-aligned compressed input.
  final _BitReader input;

  /// Bounded uncompressed output.
  final _OutputBuffer output;

  /// Creates a decoder capped at [maximumOutputBytes].
  _DeflateDecoder(this.input, int maximumOutputBytes) : output = _OutputBuffer(maximumOutputBytes);

  /// Decodes blocks through the final-block marker.
  Uint8List decode() {
    bool isFinal = false;
    while (!isFinal) {
      isFinal = input.readBits(1) == 1;
      final int type = input.readBits(2);
      switch (type) {
        case 0:
          _decodeStored();
        case 1:
          _decodeHuffman(_fixedLiteralTable, _fixedDistanceTable);
        case 2:
          _decodeDynamic();
        default:
          throw const ZCodecException('Reserved DEFLATE block type');
      }
    }
    return output.takeBytes();
  }

  /// Decodes one byte-aligned stored block.
  void _decodeStored() {
    input.alignToByte();
    final int length = input.readBits(16);
    final int complement = input.readBits(16);
    if ((length ^ 0xffff) != complement) {
      throw const ZCodecException('Invalid stored-block length');
    }
    for (int index = 0; index < length; index++) {
      output.add(input.readBits(8));
    }
  }

  /// Builds and decodes the Huffman trees of one dynamic block.
  void _decodeDynamic() {
    final int literalCount = input.readBits(5) + 257;
    final int distanceCount = input.readBits(5) + 1;
    final int codeLengthCount = input.readBits(4) + 4;
    const List<int> order = <int>[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    final List<int> codeLengths = List<int>.filled(19, 0);
    for (int index = 0; index < codeLengthCount; index++) {
      codeLengths[order[index]] = input.readBits(3);
    }
    final _HuffmanTable codeLengthTable = _HuffmanTable(codeLengths, name: 'code-length');
    final int total = literalCount + distanceCount;
    final List<int> lengths = <int>[];
    while (lengths.length < total) {
      final int symbol = codeLengthTable.read(input);
      if (symbol <= 15) {
        lengths.add(symbol);
      } else if (symbol == 16) {
        if (lengths.isEmpty) {
          throw const ZCodecException('A repeated code length has no predecessor');
        }
        final int count = input.readBits(2) + 3;
        _repeatLength(lengths, lengths.last, count, total);
      } else if (symbol == 17) {
        _repeatLength(lengths, 0, input.readBits(3) + 3, total);
      } else if (symbol == 18) {
        _repeatLength(lengths, 0, input.readBits(7) + 11, total);
      } else {
        throw const ZCodecException('Invalid code-length symbol');
      }
    }
    final List<int> literalLengths = lengths.sublist(0, literalCount);
    if (literalLengths.length <= 256 || literalLengths[256] == 0) {
      throw const ZCodecException('DEFLATE block has no end-of-block symbol');
    }
    _decodeHuffman(
      _HuffmanTable(literalLengths, name: 'literal/length'),
      _HuffmanTable(lengths.sublist(literalCount), name: 'distance', allowEmpty: true),
    );
  }

  /// Decodes literals and back-references using the supplied trees.
  void _decodeHuffman(_HuffmanTable literals, _HuffmanTable distances) {
    while (true) {
      final int symbol = literals.read(input);
      if (symbol < 256) {
        output.add(symbol);
      } else if (symbol == 256) {
        return;
      } else if (symbol <= 285) {
        final int index = symbol - 257;
        final int length = _lengthBases[index] + input.readBits(_lengthExtraBits[index]);
        if (distances.isEmpty) {
          throw const ZCodecException('Length encountered without a distance tree');
        }
        final int distanceSymbol = distances.read(input);
        if (distanceSymbol >= _distanceBases.length) {
          throw const ZCodecException('Reserved DEFLATE distance symbol');
        }
        final int distance = _distanceBases[distanceSymbol] + input.readBits(_distanceExtraBits[distanceSymbol]);
        output.copy(distance, length);
      } else {
        throw const ZCodecException('Reserved DEFLATE length symbol');
      }
    }
  }

  /// Appends a repeated code length while enforcing [maximum].
  static void _repeatLength(List<int> target, int value, int count, int maximum) {
    if (target.length + count > maximum) {
      throw const ZCodecException('Repeated code lengths exceed the Huffman alphabet');
    }
    target.addAll(List<int>.filled(count, value));
  }
}

/// Decodes one canonical Huffman alphabet bit by bit.
final class _HuffmanTable {
  /// Maps a bit length and reversed canonical code to its symbol.
  final Map<int, int> _symbols = <int, int>{};

  /// Longest code accepted by this table.
  final int _maximumLength;

  /// Builds a canonical Huffman lookup from per-symbol [lengths].
  _HuffmanTable(List<int> lengths, {required String name, bool allowEmpty = false}) : _maximumLength = lengths.fold<int>(0, (maximum, value) => value > maximum ? value : maximum) {
    if (_maximumLength == 0) {
      if (allowEmpty) {
        return;
      }
      throw ZCodecException('Empty $name Huffman tree');
    }
    if (_maximumLength > 15) {
      throw ZCodecException('Invalid $name Huffman code length');
    }
    final List<int> counts = List<int>.filled(_maximumLength + 1, 0);
    for (final int length in lengths) {
      if (length < 0 || length > _maximumLength) {
        throw ZCodecException('Invalid $name Huffman code length');
      }
      if (length != 0) {
        counts[length]++;
      }
    }
    int available = 1;
    for (int length = 1; length <= _maximumLength; length++) {
      available = (available << 1) - counts[length];
      if (available < 0) {
        throw ZCodecException('Oversubscribed $name Huffman tree');
      }
    }
    final List<int> nextCode = List<int>.filled(_maximumLength + 1, 0);
    int code = 0;
    for (int bits = 1; bits <= _maximumLength; bits++) {
      code = (code + counts[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      final int length = lengths[symbol];
      if (length != 0) {
        final int reversed = _reverseBits(nextCode[length]++, length);
        _symbols[(length << 16) | reversed] = symbol;
      }
    }
  }

  /// Whether the alphabet contains no symbols.
  bool get isEmpty => _maximumLength == 0;

  /// Reads and returns one symbol from [input].
  int read(_BitReader input) {
    int code = 0;
    for (int length = 1; length <= _maximumLength; length++) {
      code |= input.readBits(1) << (length - 1);
      final int? symbol = _symbols[(length << 16) | code];
      if (symbol != null) {
        return symbol;
      }
    }
    throw const ZCodecException('Invalid Huffman code');
  }
}

/// Reads an in-memory least-significant-bit-first bit stream.
final class _BitReader {
  /// Complete compressed input.
  final Uint8List bytes;

  /// Offset of the next byte not loaded into [_bits].
  int byteOffset = 0;

  /// Pending bits, with the next bit in the least significant position.
  int _bits = 0;

  /// Number of meaningful pending bits.
  int _bitCount = 0;

  /// Creates a reader over [bytes].
  _BitReader(this.bytes);

  /// Reads [count] bits in RFC 1951 least-significant-bit order.
  int readBits(int count) {
    while (_bitCount < count) {
      if (byteOffset >= bytes.length) {
        throw const ZCodecException('Truncated DEFLATE stream');
      }
      _bits |= bytes[byteOffset++] << _bitCount;
      _bitCount += 8;
    }
    final int value = count == 0 ? 0 : _bits & ((1 << count) - 1);
    _bits >>>= count;
    _bitCount -= count;
    return value;
  }

  /// Discards padding through the next byte boundary.
  void alignToByte() {
    _bits = 0;
    _bitCount = 0;
  }
}

/// Writes a least-significant-bit-first bit stream to memory.
final class _BitWriter {
  /// Completed byte chunks.
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Pending bits not yet emitted as a complete byte.
  int _bits = 0;

  /// Number of meaningful pending bits.
  int _bitCount = 0;

  /// Creates an empty bit writer.
  _BitWriter();

  /// Writes the [count] least significant bits of [value].
  void writeBits(int value, int count) {
    if (count == 0) {
      return;
    }
    _bits |= (value & ((1 << count) - 1)) << _bitCount;
    _bitCount += count;
    while (_bitCount >= 8) {
      _bytes.addByte(_bits & 0xff);
      _bits >>>= 8;
      _bitCount -= 8;
    }
  }

  /// Pads with zero bits through the next byte boundary.
  void alignToByte() {
    if (_bitCount != 0) {
      _bytes.addByte(_bits & 0xff);
      _bits = 0;
      _bitCount = 0;
    }
  }

  /// Writes one byte while aligned.
  void writeByte(int value) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    _bytes.addByte(value & 0xff);
  }

  /// Writes [bytes] while aligned.
  void writeBytes(List<int> bytes) {
    assert(_bitCount == 0, 'Byte writes must be aligned');
    _bytes.add(bytes);
  }

  /// Aligns and returns all completed bytes.
  Uint8List takeBytes() {
    alignToByte();
    return _bytes.takeBytes();
  }
}

/// Grows decoded output while enforcing an allocation ceiling.
final class _OutputBuffer {
  /// Largest permitted output length.
  final int maximumLength;

  /// Growable output storage.
  Uint8List _bytes;

  /// Number of initialized output bytes.
  int length = 0;

  /// Creates an output buffer capped at [maximumLength].
  _OutputBuffer(this.maximumLength) : _bytes = Uint8List(maximumLength.clamp(0, 8192));

  /// Appends one literal byte.
  void add(int value) {
    _ensure(1);
    _bytes[length++] = value;
  }

  /// Copies [count] bytes from a preceding [distance].
  void copy(int distance, int count) {
    if (distance <= 0 || distance > length) {
      throw const ZCodecException('Invalid DEFLATE back-reference distance');
    }
    _ensure(count);
    for (int index = 0; index < count; index++) {
      _bytes[length] = _bytes[length - distance];
      length++;
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
    int capacity = _bytes.isEmpty ? 64 : _bytes.length;
    while (capacity < required) {
      capacity = (capacity * 2).clamp(0, maximumLength);
    }
    final Uint8List grown = Uint8List(capacity)..setRange(0, length, _bytes);
    _bytes = grown;
  }

  /// Returns the initialized portion of the output.
  Uint8List takeBytes() => Uint8List.sublistView(_bytes, 0, length);
}

/// Reverses the lowest [length] bits of [value].
int _reverseBits(int value, int length) {
  int remaining = value;
  int reversed = 0;
  for (int index = 0; index < length; index++) {
    reversed = (reversed << 1) | (remaining & 1);
    remaining >>>= 1;
  }
  return reversed;
}

/// Code lengths of the fixed literal/length alphabet.
final List<int> _fixedLiteralLengths = <int>[
  for (int symbol = 0; symbol < 288; symbol++)
    if (symbol <= 143) 8 else if (symbol <= 255) 9 else if (symbol <= 279) 7 else 8,
];

/// Decoder for the fixed literal/length alphabet.
final _HuffmanTable _fixedLiteralTable = _HuffmanTable(_fixedLiteralLengths, name: 'fixed literal/length');

/// Decoder for the fixed distance alphabet.
final _HuffmanTable _fixedDistanceTable = _HuffmanTable(List<int>.filled(32, 5), name: 'fixed distance');

/// Base match length for symbols 257 through 285.
const List<int> _lengthBases = <int>[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];

/// Extra-bit count for each match-length symbol.
const List<int> _lengthExtraBits = <int>[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];

/// Base backward distance for symbols 0 through 29.
const List<int> _distanceBases = <int>[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];

/// Extra-bit count for each backward-distance symbol.
const List<int> _distanceExtraBits = <int>[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
