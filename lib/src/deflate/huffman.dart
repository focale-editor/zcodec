part of 'package:zcodec/src/deflate.dart';

/// Decodes one canonical Huffman alphabet with a flat lookup table.
///
/// The table is indexed by the next [_maximumLength] bits of the stream, read
/// least significant bit first, so decoding a symbol costs one peek and one
/// array read instead of one map lookup per bit. Building it touches
/// `2^maximumLength` entries, which stays below 32768 because RFC 1951 caps
/// code lengths at 15 bits.
final class _HuffmanTable {
  /// Longest code accepted by this table.
  final int _maximumLength;

  /// Packed `symbol << 4 | length` entries, or zero where no code matches.
  ///
  /// Zero is unambiguous as a sentinel because every defined code has a length
  /// of at least one bit.
  final Int32List _entries;

  /// Builds a canonical Huffman lookup from per-symbol [lengths].
  factory _HuffmanTable(List<int> lengths, {required String name, bool allowEmpty = false}) {
    int maximumLength = 0;
    for (int index = 0; index < lengths.length; index++) {
      final int length = lengths[index];
      if (length < 0 || length > 15) {
        throw ZCodecException('Invalid $name Huffman code length');
      }
      if (length > maximumLength) {
        maximumLength = length;
      }
    }
    if (maximumLength == 0) {
      if (allowEmpty) {
        return _HuffmanTable._(0, Int32List(0));
      }
      throw ZCodecException('Empty $name Huffman tree');
    }
    final List<int> counts = List<int>.filled(maximumLength + 1, 0);
    for (int index = 0; index < lengths.length; index++) {
      if (lengths[index] != 0) {
        counts[lengths[index]]++;
      }
    }
    int available = 1;
    for (int length = 1; length <= maximumLength; length++) {
      available = (available << 1) - counts[length];
      if (available < 0) {
        throw ZCodecException('Oversubscribed $name Huffman tree');
      }
    }
    final List<int> nextCode = List<int>.filled(maximumLength + 1, 0);
    int code = 0;
    for (int bits = 1; bits <= maximumLength; bits++) {
      code = (code + counts[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    final Int32List entries = Int32List(1 << maximumLength);
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      final int length = lengths[symbol];
      if (length == 0) {
        continue;
      }
      final int reversed = _reverseBits(nextCode[length]++, length);
      final int entry = (symbol << 4) | length;
      for (int high = reversed; high < entries.length; high += 1 << length) {
        entries[high] = entry;
      }
    }
    return _HuffmanTable._(maximumLength, entries);
  }

  /// Creates a table from its precomputed lookup entries.
  const _HuffmanTable._(this._maximumLength, this._entries);

  /// Whether the alphabet contains no symbols.
  bool get isEmpty => _maximumLength == 0;

  /// Reads and returns one symbol from [input].
  int read(BitReader input) {
    final int entry = _entries[input.peekBits(_maximumLength)];
    if (entry == 0) {
      throw const ZCodecException('Invalid Huffman code');
    }
    input.dropBits(entry & 0xf);
    return entry >>> 4;
  }
}
