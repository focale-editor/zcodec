part of 'package:zcodec/src/deflate.dart';

/// Huffman trees and run-length encoded header for one dynamic block.
final class _DynamicBlock {
  /// Literal/length code lengths.
  final Uint8List literalLengths;

  /// Distance code lengths.
  final Uint8List distanceLengths;

  /// Reversed canonical literal/length codes.
  late final Uint16List literalCodes = _canonicalCodes(literalLengths);

  /// Reversed canonical distance codes.
  late final Uint16List distanceCodes = _canonicalCodes(distanceLengths);

  /// Packed header symbols: low five bits are the symbol, high bits its value.
  final List<int> _header = <int>[];

  /// Code lengths for the header alphabet.
  late final Uint8List _headerLengths;

  /// Canonical codes for the header alphabet.
  late final Uint16List _headerCodes;

  /// Number of literal/length lengths transmitted.
  late final int _literalCount;

  /// Number of distance lengths transmitted.
  late final int _distanceCount;

  /// Number of header code lengths transmitted in RFC order.
  late final int _headerCount;

  /// Complete block cost, including the three block header bits.
  late final int bitLength;

  /// Builds bounded Huffman alphabets and computes their complete cost.
  _DynamicBlock(_DeflateTokens tokens) : literalLengths = buildDeflateHuffmanLengths(tokens.literals, 15), distanceLengths = buildDeflateHuffmanLengths(tokens.distances, 15) {
    if (tokens.matchCount == 0) {
      distanceLengths[0] = 1;
    }
    _literalCount = _usedLengths(literalLengths, 257);
    _distanceCount = _usedLengths(distanceLengths, 1);
    final Uint8List lengths = Uint8List(_literalCount + _distanceCount)
      ..setRange(0, _literalCount, literalLengths)
      ..setRange(_literalCount, _literalCount + _distanceCount, distanceLengths);
    final Uint32List frequencies = Uint32List(19);
    int headerExtraBits = 0;
    void append(int symbol, int value, int extraBits) {
      _header.add((value << 5) | symbol);
      frequencies[symbol]++;
      headerExtraBits += extraBits;
    }

    int offset = 0;
    while (offset < lengths.length) {
      final int value = lengths[offset];
      int end = offset + 1;
      while (end < lengths.length && lengths[end] == value) {
        end++;
      }
      int run = end - offset;
      if (value == 0) {
        while (run >= 11) {
          final int count = run < 138 ? run : 138;
          append(18, count - 11, 7);
          run -= count;
        }
        if (run >= 3) {
          append(17, run - 3, 3);
          run = 0;
        }
      } else {
        append(value, 0, 0);
        run--;
        while (run >= 3) {
          final int count = run < 6 ? run : 6;
          append(16, count - 3, 2);
          run -= count;
        }
      }
      while (run-- > 0) {
        append(value, 0, 0);
      }
      offset = end;
    }
    _headerLengths = buildDeflateHuffmanLengths(frequencies, 7);
    _headerCodes = _canonicalCodes(_headerLengths);
    int count = _codeLengthOrder.length;
    while (count > 4 && _headerLengths[_codeLengthOrder[count - 1]] == 0) {
      count--;
    }
    _headerCount = count;
    bitLength =
        17 +
        count * 3 +
        headerExtraBits +
        _weightedBits(frequencies, _headerLengths) +
        tokens.extraBits +
        _weightedBits(tokens.literals, literalLengths) +
        _weightedBits(tokens.distances, distanceLengths);
  }

  /// Serializes the three alphabets before the block's actual tokens.
  void writeHeader(BitWriter output) {
    output
      ..writeBits(_literalCount - 257, 5)
      ..writeBits(_distanceCount - 1, 5)
      ..writeBits(_headerCount - 4, 4);
    for (int index = 0; index < _headerCount; index++) {
      output.writeBits(_headerLengths[_codeLengthOrder[index]], 3);
    }
    for (final int token in _header) {
      final int symbol = token & 31;
      output.writeBits(_headerCodes[symbol], _headerLengths[symbol]);
      if (symbol >= 16) {
        output.writeBits(token >>> 5, symbol == 16 ? 2 : (symbol == 17 ? 3 : 7));
      }
    }
  }
}

/// Trims trailing unused alphabet entries while preserving [minimum].
int _usedLengths(Uint8List lengths, int minimum) {
  int count = lengths.length;
  while (count > minimum && lengths[count - 1] == 0) {
    count--;
  }
  return count;
}

/// Weighted leaf or pair used to build bounded prefix codes.
final class _HuffmanNode {
  /// Combined symbol frequency.
  final int weight;

  /// Leaf symbol, or -1 for an internal node.
  final int symbol;

  /// First child of a pair.
  final _HuffmanNode? left;

  /// Second child of a pair.
  final _HuffmanNode? right;

  /// Creates a weighted leaf.
  const _HuffmanNode.leaf(this.weight, this.symbol) : left = null, right = null;

  /// Creates a pair of weighted nodes.
  _HuffmanNode.pair(_HuffmanNode first, _HuffmanNode second) : weight = first.weight + second.weight, symbol = -1, left = first, right = second;
}

/// Builds length-limited Huffman alphabets for the internal DEFLATE encoder.
///
/// Uses package-merge when the ordinary tree exceeds [maximumBits]. This helper
/// belongs to the internal source library, not the exported codec API.
Uint8List buildDeflateHuffmanLengths(Uint32List frequencies, int maximumBits) {
  RangeError.checkValueInInterval(maximumBits, 1, 15, 'maximumBits');
  final Uint8List lengths = Uint8List(frequencies.length);
  final List<_HuffmanNode> leaves =
      <_HuffmanNode>[
        for (int index = 0; index < frequencies.length; index++)
          if (frequencies[index] != 0) _HuffmanNode.leaf(frequencies[index], index),
      ]..sort((first, second) {
        final int order = first.weight.compareTo(second.weight);
        return order != 0 ? order : first.symbol.compareTo(second.symbol);
      });
  if (leaves.length > 1 << maximumBits) {
    throw ArgumentError('Too many symbols for the requested Huffman length limit');
  }
  if (leaves.length < 2) {
    if (leaves.isNotEmpty) {
      lengths[leaves.single.symbol] = 1;
    }
    return lengths;
  }
  final List<_HuffmanNode> parents = <_HuffmanNode>[];
  int leafIndex = 0;
  int parentIndex = 0;
  _HuffmanNode next() {
    if (leafIndex < leaves.length && (parentIndex == parents.length || leaves[leafIndex].weight <= parents[parentIndex].weight)) {
      return leaves[leafIndex++];
    }
    return parents[parentIndex++];
  }

  for (int index = 1; index < leaves.length; index++) {
    parents.add(_HuffmanNode.pair(next(), next()));
  }
  int deepest = 0;
  void assign(_HuffmanNode node, int depth) {
    if (node.symbol >= 0) {
      lengths[node.symbol] = depth;
      if (depth > deepest) {
        deepest = depth;
      }
    } else {
      assign(node.left!, depth + 1);
      assign(node.right!, depth + 1);
    }
  }

  assign(parents.last, 0);
  if (deepest <= maximumBits) {
    return lengths;
  }
  // Binary package-merge selects the 2*n-2 cheapest items in the final list.
  // Each selected occurrence of a leaf contributes one bit to its code length.
  List<_HuffmanNode> items = leaves;
  final int needed = leaves.length * 2 - 2;
  for (int depth = 1; depth < maximumBits; depth++) {
    final List<_HuffmanNode> pairs = <_HuffmanNode>[
      for (int index = 0; index + 1 < items.length; index += 2) _HuffmanNode.pair(items[index], items[index + 1]),
    ];
    final List<_HuffmanNode> merged = <_HuffmanNode>[];
    int leaf = 0;
    int pair = 0;
    while (merged.length < needed && (leaf < leaves.length || pair < pairs.length)) {
      if (leaf < leaves.length && (pair == pairs.length || leaves[leaf].weight <= pairs[pair].weight)) {
        merged.add(leaves[leaf++]);
      } else {
        merged.add(pairs[pair++]);
      }
    }
    items = merged;
  }
  lengths.fillRange(0, lengths.length, 0);
  void count(_HuffmanNode node) {
    if (node.symbol >= 0) {
      lengths[node.symbol]++;
    } else {
      count(node.left!);
      count(node.right!);
    }
  }

  for (int index = 0; index < needed; index++) {
    count(items[index]);
  }
  return lengths;
}

/// Constructs reversed canonical codes for a bounded Huffman alphabet.
Uint16List _canonicalCodes(Uint8List lengths) {
  final Uint16List counts = Uint16List(16);
  final Uint16List next = Uint16List(16);
  for (final int length in lengths) {
    if (length != 0) {
      counts[length]++;
    }
  }
  int code = 0;
  for (int bits = 1; bits <= 15; bits++) {
    code = (code + counts[bits - 1]) << 1;
    next[bits] = code;
  }
  return Uint16List.fromList(<int>[
    for (final int length in lengths)
      if (length == 0) 0 else _reverseBits(next[length]++, length),
  ]);
}
