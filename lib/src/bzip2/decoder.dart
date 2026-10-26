part of 'package:zcodec/src/bzip2.dart';

/// Parses one Huffman/MTF block without mutating the enclosing stream state.
(Uint8List, int, bool) _readBzipBlock(_BzipReader reader, int limit) {
  final bool randomized = reader.read(1) != 0;
  final int origin = reader.read(24);
  final List<int> groups = List.generate(16, (_) => reader.read(1));
  final List<int> alphabet = [];
  for (int group = 0; group < 16; group++) {
    if (groups[group] != 0) {
      for (int j = 0; j < 16; j++) {
        if (reader.read(1) != 0) {
          alphabet.add(group * 16 + j);
        }
      }
    }
  }
  final int alphaSize = alphabet.length + 2;
  final int tableCount = reader.read(3);
  final int selectorCount = reader.read(15);
  if (alphabet.isEmpty || tableCount < 2 || tableCount > 6 || selectorCount == 0) {
    throw const ZCodecException('Invalid BZIP2 alphabet or selectors');
  }
  final List<int> tableOrder = List.generate(tableCount, (index) => index);
  final Uint8List selectors = Uint8List(selectorCount);
  for (int i = 0; i < selectorCount; i++) {
    int index = 0;
    while (reader.read(1) != 0) {
      if (++index >= tableCount) {
        throw const ZCodecException('Invalid BZIP2 table selector');
      }
    }
    final int value = tableOrder.removeAt(index);
    tableOrder.insert(0, value);
    selectors[i] = value;
  }
  final List<_BzipHuffman> tables = [];
  for (int table = 0; table < tableCount; table++) {
    int length = reader.read(5);
    final List<int> lengths = [];
    for (int symbol = 0; symbol < alphaSize; symbol++) {
      while (true) {
        if (length < 1 || length > 20) {
          throw const ZCodecException('Invalid BZIP2 Huffman length');
        }
        if (reader.read(1) == 0) {
          break;
        }
        length += reader.read(1) == 0 ? 1 : -1;
      }
      lengths.add(length);
    }
    tables.add(_BzipHuffman(lengths));
  }
  int symbolIndex = 0;
  int symbol() {
    if (symbolIndex ~/ 50 >= selectors.length) {
      throw const ZCodecException('BZIP2 selector list is exhausted');
    }
    return tables[selectors[symbolIndex++ ~/ 50]].read(reader);
  }

  final Uint8List mtf = Uint8List.fromList(alphabet);
  final Uint8List result = Uint8List(limit);
  int size = 0;
  int next = symbol();
  while (next != alphaSize - 1) {
    if (next < 2) {
      int run = 0;
      int scale = 1;
      do {
        run += (next + 1) * scale;
        if (run > limit - size) {
          throw const ZCodecException('BZIP2 run exceeds block capacity');
        }
        scale *= 2;
        next = symbol();
      } while (next < 2);
      result.fillRange(size, size + run, mtf[0]);
      size += run;
    } else {
      if (size == limit) {
        throw const ZCodecException('BZIP2 block exceeds declared capacity');
      }
      final int index = next - 1;
      final int byte = mtf[index];
      mtf.setRange(1, index + 1, mtf);
      mtf[0] = byte;
      result[size++] = byte;
      next = symbol();
    }
  }
  if (origin >= size) {
    throw const ZCodecException('Invalid BZIP2 BWT origin');
  }
  return (Uint8List.sublistView(result, 0, size), origin, randomized);
}

/// Canonical MSB-first Huffman decoder with oversubscription checks.
final class _BzipHuffman {
  /// Shortest code length; most symbols can be read in one field operation.
  late final int minimum;

  /// Longest populated code length.
  late final int maximum;

  /// Ten-bit prefix lookup; zero entries fall back to long canonical codes.
  final Uint16List prefixes = Uint16List(1024);

  /// Symbol counts for each bit length.
  final List<int> counts = List.filled(21, 0);

  /// First canonical code for each length.
  final List<int> first = List.filled(21, 0);

  /// First symbol offset for each length.
  final List<int> offsets = List.filled(21, 0);

  /// Symbols sorted by length then value.
  final List<int> symbols = [];

  /// Creates checked decode tables.
  _BzipHuffman(List<int> lengths) {
    for (final int length in lengths) {
      counts[length]++;
    }
    minimum = lengths.reduce((a, b) => a < b ? a : b);
    maximum = lengths.reduce((a, b) => a > b ? a : b);
    int code = 0;
    for (int length = 1; length <= 20; length++) {
      first[length] = code;
      offsets[length] = symbols.length;
      for (int symbol = 0; symbol < lengths.length; symbol++) {
        if (lengths[symbol] == length) {
          symbols.add(symbol);
        }
      }
      code += counts[length];
      if (code > 1 << length) {
        throw const ZCodecException('Oversubscribed BZIP2 Huffman tree');
      }
      if (length <= 10) {
        final int repetitions = 1 << (10 - length);
        for (int i = 0; i < counts[length]; i++) {
          final int start = (first[length] + i) * repetitions;
          prefixes.fillRange(start, start + repetitions, (length << 9) | symbols[offsets[length] + i]);
        }
      }
      code *= 2;
    }
  }

  /// Reads one symbol, rejecting holes in incomplete trees.
  int read(_BzipReader reader) {
    final int position = reader.position;
    final int entry = prefixes[reader.read(10)];
    if (entry != 0) {
      reader.position = position + (entry >>> 9);
      return entry & 511;
    }
    reader.position = position;
    int code = reader.read(minimum);
    for (int length = minimum; length <= maximum; length++) {
      final int index = code - first[length];
      if (index >= 0 && index < counts[length]) {
        return symbols[offsets[length] + index];
      }
      if (length < maximum) {
        code = (code << 1) | reader.read(1);
      }
    }
    throw const ZCodecException('Invalid BZIP2 Huffman code');
  }
}
