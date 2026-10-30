part of 'package:zcodec/src/zstd.dart';

/// One finite-state entropy transition: output symbol, bit count and next base.
typedef _ZstdTransition = ({int symbol, int bits, int base});

/// Immutable decoding table built from a normalized probability distribution.
final class _ZstdEntropyTable {
  /// Number of bits used to initialize the entropy state.
  final int accuracy;

  /// Indexed state transitions shared by all consumers of this table.
  final List<_ZstdTransition> states;

  /// Distributes symbols and assigns transitions according to RFC 8878 section 4.1.
  factory _ZstdEntropyTable({required int accuracy, required List<int> probabilities}) {
    final int size = 1 << accuracy;
    if (probabilities.fold(0, (sum, count) => sum + count.abs()) != size || probabilities.any((count) => count < -1)) {
      throw const ZCodecException('Invalid Zstandard entropy probabilities');
    }
    final List<int> symbols = List.filled(size, 0);
    final List<int> next = probabilities.map((count) => count.abs()).toList();
    int upper = size - 1;
    for (int symbol = 0; symbol < probabilities.length; symbol++) {
      if (probabilities[symbol] == -1) {
        symbols[upper--] = symbol;
      }
    }
    int position = 0;
    final int step = (size >> 1) + (size >> 3) + 3;
    for (int symbol = 0; symbol < probabilities.length; symbol++) {
      for (int occurrence = 0; occurrence < probabilities[symbol]; occurrence++) {
        symbols[position] = symbol;
        do {
          position = (position + step) & (size - 1);
        } while (position > upper);
      }
    }
    final List<_ZstdTransition> states = [];
    for (final int symbol in symbols) {
      final int state = next[symbol]++;
      final int bits = accuracy - (state.bitLength - 1);
      states.add((symbol: symbol, bits: bits, base: (state << bits) - size));
    }
    return _ZstdEntropyTable._(accuracy: accuracy, states: List.unmodifiable(states));
  }

  /// Creates a complete immutable table.
  const _ZstdEntropyTable._({required this.accuracy, required this.states});

  /// Creates a constant-symbol table requiring no state or transition bits.
  factory _ZstdEntropyTable.repeated({required int symbol}) => _ZstdEntropyTable._(accuracy: 0, states: [(symbol: symbol, bits: 0, base: 0)]);

  /// Reads a forward normalized-count header and leaves the reader byte-aligned.
  factory _ZstdEntropyTable.read({required ByteReader reader, required int maxAccuracy, required int maxSymbol}) {
    final BitReader bits = BitReader(Uint8List.sublistView(reader.bytes, reader.offset));
    final int accuracy = bits.readBits(4) + 5;
    if (accuracy > maxAccuracy) {
      throw const ZCodecException('Excessive Zstandard entropy table accuracy');
    }
    final List<int> probabilities = [];
    int remaining = 1 << accuracy;
    while (remaining > 0) {
      final int bound = remaining + 1;
      final int width = bound.bitLength;
      final int shortValues = (1 << width) - 1 - bound;
      final int low = bits.peekBits(width - 1);
      int value;
      if (low < shortValues) {
        value = bits.readBits(width - 1);
      } else {
        value = bits.readBits(width);
        if (value >= 1 << (width - 1)) {
          value -= shortValues;
        }
      }
      final int probability = value - 1;
      remaining -= probability.abs();
      probabilities.add(probability);
      if (probability == 0) {
        int repeat;
        do {
          repeat = bits.readBits(2);
          probabilities.addAll(List<int>.filled(repeat, 0));
          if (probabilities.length > maxSymbol + 1) {
            throw const ZCodecException('Excessive Zstandard entropy symbol count');
          }
        } while (repeat == 3);
      }
      if (remaining < 0 || probabilities.length > maxSymbol + 1) {
        throw const ZCodecException('Invalid Zstandard entropy distribution');
      }
    }
    reader.skip((bits.bitOffset + 7) ~/ 8);
    if (probabilities.where((count) => count != 0).length < 2) {
      throw const ZCodecException('Zstandard entropy table needs two symbols');
    }
    return _ZstdEntropyTable(accuracy: accuracy, probabilities: probabilities);
  }
}

/// Canonical Huffman table for byte literals with at most eleven code bits.
final class _ZstdHuffmanTable {
  /// Maximum number of bits in a codeword.
  final int width;

  /// Symbol and actual code length for every width-bit lookahead.
  final List<({int symbol, int bits})> entries;

  /// Creates a fully checked table from its forward tree description.
  factory _ZstdHuffmanTable.read({required ByteReader reader}) {
    final int header = reader.readByte();
    final List<int> weights = [];
    if (header >= 128) {
      final int count = header - 127;
      for (int index = 0; index < count; index += 2) {
        final int pair = reader.readByte();
        weights.add(pair >> 4);
        if (index + 1 < count) {
          weights.add(pair & 15);
        }
      }
    } else {
      final ByteReader compressed = ByteReader(reader.readBytes(header));
      final _ZstdEntropyTable table = _ZstdEntropyTable.read(reader: compressed, maxAccuracy: 6, maxSymbol: 12);
      final _ZstdReverseBits bits = _ZstdReverseBits(bytes: compressed.readBytes(compressed.remaining));
      final List<int> states = [bits.read(table.accuracy), bits.read(table.accuracy)];
      int current = 0;
      while (true) {
        final _ZstdTransition transition = table.states[states[current]];
        weights.add(transition.symbol);
        if (weights.length > 254) {
          throw const ZCodecException('Too many Zstandard Huffman weights');
        }
        if (transition.bits > bits.remaining) {
          weights.add(table.states[states[1 - current]].symbol);
          break;
        }
        states[current] = transition.base + bits.read(transition.bits);
        current = 1 - current;
      }
    }
    if (weights.isEmpty || weights.any((weight) => weight > 11)) {
      throw const ZCodecException('Invalid Zstandard Huffman weights');
    }
    final int total = weights.fold(0, (sum, weight) => sum + (weight == 0 ? 0 : 1 << (weight - 1)));
    final int width = total.bitLength;
    final int remainder = (1 << width) - total;
    if (width > 11 || total == 0 || remainder & (remainder - 1) != 0) {
      throw const ZCodecException('Incomplete Zstandard Huffman tree');
    }
    weights.add(remainder.bitLength);
    final List<({int symbol, int bits})> entries = List.filled(1 << width, (symbol: 0, bits: 0));
    int cursor = 0;
    for (int weight = 1; weight <= width; weight++) {
      for (int symbol = 0; symbol < weights.length; symbol++) {
        if (weights[symbol] == weight) {
          final int count = 1 << (weight - 1);
          entries.fillRange(cursor, cursor + count, (symbol: symbol, bits: width + 1 - weight));
          cursor += count;
        }
      }
    }
    if (cursor != entries.length) {
      throw const ZCodecException('Invalid Zstandard Huffman tree coverage');
    }
    return _ZstdHuffmanTable._(width: width, entries: List.unmodifiable(entries));
  }

  /// Retains a complete table for treeless blocks in the same frame.
  const _ZstdHuffmanTable._({required this.width, required this.entries});

  /// Decodes an exact number of literals and checks complete stream consumption.
  Uint8List decode({required Uint8List input, required int count}) {
    final _ZstdReverseBits reader = _ZstdReverseBits(bytes: input);
    final Uint8List output = Uint8List(count);
    for (int index = 0; index < count; index++) {
      final ({int symbol, int bits}) entry = entries[reader.peek(width)];
      reader.read(entry.bits);
      output[index] = entry.symbol;
    }
    if (reader.remaining != 0) {
      throw const ZCodecException('Trailing bits in Zstandard Huffman stream');
    }
    return output;
  }
}
