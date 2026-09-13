part of 'package:zcodec/src/deflate.dart';

/// Decodes one canonical Huffman alphabet with a two-level lookup table.
///
/// The root table is indexed by the next [_rootLength] bits of the stream,
/// read least significant bit first. Longer codes continue in a subtable
/// selected by the root entry, as in zlib, so building a table touches about
/// `2^rootLength` entries instead of `2^15` while almost every symbol still
/// decodes with a single array read.
///
/// Every entry is one of:
/// * zero, where no code matches;
/// * a leaf `symbol << 4 | codeLength`, with a code length from 1 to 15;
/// * a link `offset << 8 | subtableLength << 4`, whose low four bits are zero.
final class _HuffmanTable {
  /// Longest code accepted by this table.
  final int _maximumLength;

  /// Number of bits indexing the root table.
  final int _rootLength;

  /// Root table followed by every subtable.
  final Uint32List _entries;

  /// Builds a canonical Huffman lookup from per-symbol [lengths].
  ///
  /// Root tables are capped at [rootLength] bits, which trades build time for
  /// the share of symbols needing a subtable.
  factory _HuffmanTable(List<int> lengths, {required String name, int rootLength = 10, bool allowEmpty = false}) {
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
        return _HuffmanTable._(0, 0, Uint32List(1));
      }
      throw ZCodecException('Empty $name Huffman tree');
    }
    final Uint16List counts = Uint16List(maximumLength + 1);
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
    final Uint16List nextCode = Uint16List(maximumLength + 1);
    int code = 0;
    for (int bits = 1; bits <= maximumLength; bits++) {
      code = (code + counts[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    final int root = maximumLength < rootLength ? maximumLength : rootLength;
    final int rootSize = 1 << root;
    final int rootMask = rootSize - 1;
    final Uint16List codes = Uint16List(lengths.length);
    // Each subtable is as deep as the longest code sharing its root prefix.
    final Uint8List subtableLengths = Uint8List(rootSize);
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      final int length = lengths[symbol];
      if (length == 0) {
        continue;
      }
      final int reversed = _reverseBits(nextCode[length]++, length);
      codes[symbol] = reversed;
      final int prefix = reversed & rootMask;
      if (length - root > subtableLengths[prefix]) {
        subtableLengths[prefix] = length - root;
      }
    }
    int size = rootSize;
    for (int prefix = 0; prefix < rootSize; prefix++) {
      size += subtableLengths[prefix] == 0 ? 0 : 1 << subtableLengths[prefix];
    }
    final Uint32List entries = Uint32List(size);
    int offset = rootSize;
    for (int prefix = 0; prefix < rootSize; prefix++) {
      final int subtableLength = subtableLengths[prefix];
      if (subtableLength != 0) {
        entries[prefix] = (offset << 8) | (subtableLength << 4);
        offset += 1 << subtableLength;
      }
    }
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      final int length = lengths[symbol];
      if (length == 0) {
        continue;
      }
      final int entry = (symbol << 4) | length;
      final int reversed = codes[symbol];
      if (length <= root) {
        for (int index = reversed; index < rootSize; index += 1 << length) {
          entries[index] = entry;
        }
      } else {
        final int link = entries[reversed & rootMask];
        final int start = link >>> 8;
        final int end = start + (1 << ((link >>> 4) & 0xf));
        for (int index = start + (reversed >>> root); index < end; index += 1 << (length - root)) {
          entries[index] = entry;
        }
      }
    }
    return _HuffmanTable._(maximumLength, root, entries);
  }

  /// Creates a table from its precomputed lookup entries.
  const _HuffmanTable._(this._maximumLength, this._rootLength, this._entries);

  /// Whether the alphabet contains no symbols.
  bool get isEmpty => _maximumLength == 0;

  /// Reads and returns one symbol from [input].
  int read(BitReader input) {
    int entry = _entries[input.peekBits(_rootLength)];
    if ((entry & 0xf) == 0 && entry != 0) {
      final int subtableIndex = input.peekBits(_rootLength + ((entry >>> 4) & 0xf)) >>> _rootLength;
      entry = _entries[(entry >>> 8) + subtableIndex];
    }
    if (entry == 0) {
      input.requireBits(_maximumLength);
      throw const ZCodecException('Invalid Huffman code');
    }
    input.dropBits(entry & 0xf);
    return entry >>> 4;
  }
}
