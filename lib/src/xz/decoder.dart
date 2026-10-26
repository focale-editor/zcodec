part of 'package:zcodec/src/xz.dart';

/// LZMA packet decoder with a ring dictionary bounded by the XZ header.
final class _LzmaDecoder {
  /// Probability state persists across chunks unless LZMA2 resets it.
  final _LzmaModels models = _LzmaModels();

  /// Circular history, never resized from decoded byte counts.
  final Uint8List dictionary;

  /// Logical position since the last dictionary reset.
  int position = 0;

  /// Creates the checked dictionary.
  _LzmaDecoder(int size) : dictionary = Uint8List(size);

  /// Starts a new dictionary without retaining a reference to earlier bytes.
  void resetDictionary() => position = 0;

  /// Returns a checked previously decoded byte.
  int previous(int distance) {
    if (distance >= position || distance >= dictionary.length) {
      throw const ZCodecException('LZMA distance exceeds available dictionary');
    }
    return dictionary[(position - distance - 1) % dictionary.length];
  }

  /// Appends one byte to the circular history.
  void put(int byte) {
    dictionary[position % dictionary.length] = byte;
    position++;
  }

  /// Imports a stored LZMA2 chunk into the history.
  void stored(Uint8List bytes) {
    bytes.forEach(put);
  }

  /// Decodes one bounded LZMA2 compressed chunk, including range finalization.
  Uint8List decode(Uint8List bytes, int size) {
    final _RangeDecoder reader = _RangeDecoder(bytes);
    final Uint8List result = Uint8List(size);
    int output = 0;
    final _LzmaModels m = models;
    while (output < size) {
      final int ps = m.positionState(position);
      if (reader.bit(m.match, m.state * 16 + ps) == 0) {
        final int base = m.literalBase(position, position == 0 ? 0 : previous(0));
        int symbol = 1;
        int offset = m.state < 7 ? 0 : 256;
        int matchByte = offset == 0 ? 0 : previous(m.reps[0]);
        while (symbol < 256) {
          matchByte <<= 1;
          final int matchBit = matchByte & offset;
          final int bit = reader.bit(m.literals, base + offset + matchBit + symbol);
          symbol = (symbol << 1) | bit;
          if (matchBit != bit * offset) {
            offset = 0;
          }
        }
        final int byte = symbol - 256;
        put(byte);
        result[output++] = byte;
        m.literalState();
        continue;
      }
      int length;
      if (reader.bit(m.rep, m.state) == 0) {
        length = reader.length(m.length, ps);
        final int slot = reader.tree(m.slots, (length - 2).clamp(0, 3) * 64, 6);
        int distance = slot;
        if (slot >= 4) {
          final int bits = (slot >> 1) - 1;
          distance = (2 | (slot & 1)) * (1 << bits);
          if (slot < 14) {
            distance += reader.tree(m.distances, distance - slot - 1, bits, reverse: true);
          } else {
            distance += reader.direct(bits - 4) * 16 + reader.tree(m.align, 0, 4, reverse: true);
          }
        }
        m.reps[3] = m.reps[2];
        m.reps[2] = m.reps[1];
        m.reps[1] = m.reps[0];
        m.reps[0] = distance;
        m.state = m.state < 7 ? 7 : 10;
      } else {
        if (reader.bit(m.rep0, m.state) == 0) {
          if (reader.bit(m.shortRep, m.state * 16 + ps) == 0) {
            final int byte = previous(m.reps[0]);
            put(byte);
            result[output++] = byte;
            m.state = m.state < 7 ? 9 : 11;
            continue;
          }
        } else {
          final int index = reader.bit(m.rep1, m.state) == 0 ? 1 : (reader.bit(m.rep2, m.state) == 0 ? 2 : 3);
          final int distance = m.reps[index];
          for (int i = index; i > 0; i--) {
            m.reps[i] = m.reps[i - 1];
          }
          m.reps[0] = distance;
        }
        length = reader.length(m.repLength, ps);
        m.state = m.state < 7 ? 8 : 11;
      }
      if (length > size - output) {
        throw const ZCodecException('LZMA match crosses its chunk boundary');
      }
      for (int i = 0; i < length; i++) {
        final int byte = previous(m.reps[0]);
        put(byte);
        result[output++] = byte;
      }
    }
    if (reader.input.remaining != 0 || reader.code != 0) {
      throw const ZCodecException('Invalid LZMA range termination');
    }
    return result;
  }
}
