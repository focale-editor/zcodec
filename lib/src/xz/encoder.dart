part of 'package:zcodec/src/xz.dart';

/// Encodes a bounded 64-KiB chunk with a greedy, depth-limited hash chain.
///
/// Chunks reset their dictionaries, keeping encoder memory and worst-case
/// match-search work independent of stream length. Incompressible chunks are
/// stored by the LZMA2 wrapper instead.
Uint8List _encodeLzma(Uint8List bytes) {
  final _LzmaModels m = _LzmaModels();
  final _RangeEncoder writer = _RangeEncoder();
  final Int32List heads = Int32List(65536)..fillRange(0, 65536, -1);
  final Int32List chain = Int32List(bytes.length)..fillRange(0, bytes.length, -1);
  int position = 0;
  int lastDistance = 0;
  int hash(int index) => ((bytes[index] * 251 + bytes[index + 1]) * 251 + bytes[index + 2]) & 65535;
  void insert(int index) {
    if (index + 2 < bytes.length) {
      final int key = hash(index);
      chain[index] = heads[key];
      heads[key] = index;
    }
  }

  while (position < bytes.length) {
    int bestLength = 0;
    int bestDistance = 0;
    final int maxLength = (bytes.length - position).clamp(0, 273);
    if (maxLength >= 3) {
      int candidate = heads[hash(position)];
      int attempts = 32;
      while (candidate >= 0 && attempts-- > 0) {
        if (bytes[candidate + bestLength] == bytes[position + bestLength]) {
          int length = 0;
          while (length < maxLength && bytes[candidate + length] == bytes[position + length]) {
            length++;
          }
          if (length > bestLength) {
            bestLength = length;
            bestDistance = position - candidate - 1;
            if (length == maxLength) {
              break;
            }
          }
        }
        candidate = chain[candidate];
      }
    }
    final int ps = m.positionState(position);
    if (bestLength >= 3) {
      writer
        ..bit(m.match, m.state * 16 + ps, 1)
        ..bit(m.rep, m.state, 0)
        ..length(m.length, ps, bestLength);
      int slot = bestDistance;
      if (bestDistance >= 4) {
        final int log = bestDistance.bitLength - 1;
        slot = log * 2 + ((bestDistance >>> (log - 1)) & 1);
      }
      writer.tree(m.slots, (bestLength - 2).clamp(0, 3) * 64, 6, slot);
      if (slot >= 4) {
        final int bits = (slot >> 1) - 1;
        final int base = (2 | (slot & 1)) * (1 << bits);
        final int extra = bestDistance - base;
        if (slot < 14) {
          writer.tree(m.distances, base - slot - 1, bits, extra, reverse: true);
        } else {
          writer.direct(bits - 4, extra >>> 4);
          writer.tree(m.align, 0, 4, extra & 15, reverse: true);
        }
      }
      lastDistance = bestDistance;
      m.state = m.state < 7 ? 7 : 10;
      for (int i = 0; i < bestLength; i++) {
        insert(position++);
      }
    } else {
      writer.bit(m.match, m.state * 16 + ps, 0);
      final int base = m.literalBase(position, position == 0 ? 0 : bytes[position - 1]);
      int offset = m.state < 7 ? 0 : 256;
      int matchByte = offset == 0 ? 0 : bytes[position - lastDistance - 1];
      int symbol = 1;
      final int byte = bytes[position];
      for (int shift = 7; shift >= 0; shift--) {
        matchByte <<= 1;
        final int matchBit = matchByte & offset;
        final int bit = (byte >>> shift) & 1;
        writer.bit(m.literals, base + offset + matchBit + symbol, bit);
        symbol = (symbol << 1) | bit;
        if (matchBit != bit * offset) {
          offset = 0;
        }
      }
      m.literalState();
      insert(position++);
    }
  }
  return writer.finish();
}
