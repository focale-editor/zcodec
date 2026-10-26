part of 'package:zcodec/src/bzip2.dart';

/// Encodes one independently sorted block.
void _encodeBzipBlock(Uint8List input, _BzipWriter writer, void Function(int) checksum) {
  int crc = 0xffffffff;
  final BytesBuilder rle = BytesBuilder();
  int cursor = 0;
  while (cursor < input.length) {
    final int byte = input[cursor];
    int count = 1;
    while (cursor + count < input.length && input[cursor + count] == byte && count < 259) {
      count++;
    }
    for (int i = 0; i < count; i++) {
      crc = _bzipUpdate(crc, byte);
    }
    for (int i = 0; i < count.clamp(0, 4); i++) {
      rle.addByte(byte);
    }
    if (count >= 4) {
      rle.addByte(count - 4);
    }
    cursor += count;
  }
  crc ^= 0xffffffff;
  checksum(crc);
  final (Uint8List transformed, int origin) = _bwt(rle.takeBytes());
  final List<bool> used = List.filled(256, false);
  for (final int byte in transformed) {
    used[byte] = true;
  }
  final List<int> alphabet = [
    for (int i = 0; i < 256; i++)
      if (used[i]) i,
  ];
  final int alphaSize = alphabet.length + 2;
  final List<int> symbols = [];
  int zeroes = 0;
  void flushZeroes() {
    if (zeroes == 0) {
      return;
    }
    int remaining = zeroes - 1;
    while (true) {
      symbols.add(remaining & 1);
      if (remaining < 2) {
        break;
      }
      remaining = (remaining - 2) ~/ 2;
    }
    zeroes = 0;
  }

  for (final int byte in transformed) {
    final int index = alphabet.indexOf(byte);
    if (index == 0) {
      zeroes++;
    } else {
      flushZeroes();
      symbols.add(index + 1);
      for (int i = index; i > 0; i--) {
        alphabet[i] = alphabet[i - 1];
      }
      alphabet[0] = byte;
    }
  }
  flushZeroes();
  symbols.add(alphaSize - 1);
  final List<int> frequencies = List.filled(alphaSize, 0);
  for (final int symbol in symbols) {
    frequencies[symbol]++;
  }
  final List<int> lengths = _huffmanLengths(frequencies);
  final List<int> codes = List.filled(alphaSize, 0);
  int code = 0;
  for (int length = 1; length <= 20; length++) {
    for (int symbol = 0; symbol < alphaSize; symbol++) {
      if (lengths[symbol] == length) {
        codes[symbol] = code++;
      }
    }
    code <<= 1;
  }
  writer
    ..write(24, 0x314159)
    ..write(24, 0x265359)
    ..write(32, crc)
    ..write(1, 0)
    ..write(24, origin);
  final List<bool> groups = List.generate(16, (group) => used.sublist(group * 16, group * 16 + 16).any((value) => value));
  for (final bool group in groups) {
    writer.write(1, group ? 1 : 0);
  }
  for (int group = 0; group < 16; group++) {
    if (groups[group]) {
      for (int j = 0; j < 16; j++) {
        writer.write(1, used[group * 16 + j] ? 1 : 0);
      }
    }
  }
  final int selectors = (symbols.length + 49) ~/ 50;
  writer
    ..write(3, 2)
    ..write(15, selectors);
  for (int i = 0; i < selectors; i++) {
    writer.write(1, 0);
  }
  // Two identical tables satisfy the format while keeping selection deterministic.
  for (int table = 0; table < 2; table++) {
    int current = lengths.first;
    writer.write(5, current);
    for (final int length in lengths) {
      while (current < length) {
        writer.write(2, 2);
        current++;
      }
      while (current > length) {
        writer.write(2, 3);
        current--;
      }
      writer.write(1, 0);
    }
  }
  for (final int symbol in symbols) {
    writer.write(lengths[symbol], codes[symbol]);
  }
}

/// Sorts cyclic suffixes by counting doubled equivalence classes, O(n log n).
(Uint8List, int) _bwt(Uint8List bytes) {
  final int length = bytes.length;
  final Uint32List order = Uint32List(length);
  Uint32List ranks = Uint32List(length);
  Uint32List next = Uint32List(length);
  final Uint32List shifted = Uint32List(length);
  final Uint32List counts = Uint32List(length < 256 ? 256 : length);
  for (final int byte in bytes) {
    counts[byte]++;
  }
  for (int i = 1; i < 256; i++) {
    counts[i] += counts[i - 1];
  }
  for (int i = length - 1; i >= 0; i--) {
    order[--counts[bytes[i]]] = i;
  }
  int classes = 1;
  for (int i = 1; i < length; i++) {
    if (bytes[order[i]] != bytes[order[i - 1]]) {
      classes++;
    }
    ranks[order[i]] = classes - 1;
  }
  for (int span = 1; span < length && classes < length; span *= 2) {
    counts.fillRange(0, classes, 0);
    for (int i = 0; i < length; i++) {
      final int value = order[i] >= span ? order[i] - span : order[i] + length - span;
      shifted[i] = value;
      counts[ranks[value]]++;
    }
    for (int i = 1; i < classes; i++) {
      counts[i] += counts[i - 1];
    }
    for (int i = length - 1; i >= 0; i--) {
      final int value = shifted[i];
      order[--counts[ranks[value]]] = value;
    }
    int newClasses = 1;
    next[order[0]] = 0;
    for (int i = 1; i < length; i++) {
      final int a = order[i];
      final int b = order[i - 1];
      if (ranks[a] != ranks[b] || ranks[(a + span) % length] != ranks[(b + span) % length]) {
        newClasses++;
      }
      next[a] = newClasses - 1;
    }
    final Uint32List previous = ranks;
    ranks = next;
    next = previous;
    classes = newClasses;
  }
  final Uint8List result = Uint8List(length);
  int origin = 0;
  for (int i = 0; i < length; i++) {
    final int suffix = order[i];
    result[i] = bytes[suffix == 0 ? length - 1 : suffix - 1];
    if (suffix == 0) {
      origin = i;
    }
  }
  return (result, origin);
}

/// Builds a positive-frequency Huffman tree, rescaling until lengths fit BZIP2.
List<int> _huffmanLengths(List<int> frequencies) {
  final int size = frequencies.length;
  final List<int> weights = [
    for (final int count in frequencies)
      if (count == 0) 1 else count,
  ];
  while (true) {
    final List<int> nodes = [...weights];
    final List<int> parents = List.filled(size * 2 - 1, -1);
    final List<int> active = List.generate(size, (index) => index);
    while (active.length > 1) {
      active.sort((a, b) => nodes[a] != nodes[b] ? nodes[a].compareTo(nodes[b]) : a.compareTo(b));
      final int a = active.removeAt(0);
      final int b = active.removeAt(0);
      parents[a] = parents[b] = nodes.length;
      active.add(nodes.length);
      nodes.add(nodes[a] + nodes[b]);
    }
    final List<int> lengths = List.generate(size, (index) {
      int depth = 0;
      int node = index;
      while (parents[node] >= 0) {
        depth++;
        node = parents[node];
      }
      return depth;
    });
    if (lengths.every((length) => length <= 20)) {
      return lengths;
    }
    for (int i = 0; i < size; i++) {
      weights[i] = 1 + weights[i] ~/ 2;
    }
  }
}
