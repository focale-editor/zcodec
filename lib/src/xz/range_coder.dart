part of 'package:zcodec/src/xz.dart';

/// Portable 32-bit LZMA range decoder.
final class _RangeDecoder {
  /// Encoded range bytes, bounded to the current LZMA2 chunk.
  final ByteReader input;

  /// Current interval size.
  int range = 0xffffffff;

  /// Current position within the interval.
  int code = 0;

  /// Reads the five-byte range initialization.
  _RangeDecoder(Uint8List bytes) : input = ByteReader(bytes) {
    if (input.readByte() != 0) {
      throw const ZCodecException('Invalid LZMA range initialization');
    }
    for (int i = 0; i < 4; i++) {
      code = code * 256 + input.readByte();
    }
    if (code == range) {
      throw const ZCodecException('Invalid LZMA initial range');
    }
  }

  /// Renormalizes without relying on signed 64-bit arithmetic.
  void normalize() {
    if (range < 0x1000000) {
      range = (range * 256) & 0xffffffff;
      code = (code * 256 + input.readByte()) & 0xffffffff;
    }
  }

  /// Decodes and adapts one probability.
  int bit(Uint16List probabilities, int index) {
    final int probability = probabilities[index];
    final int bound = (range >>> 11) * probability;
    final int result;
    if (code < bound) {
      range = bound;
      probabilities[index] = probability + ((2048 - probability) >> 5);
      result = 0;
    } else {
      range -= bound;
      code -= bound;
      probabilities[index] = probability - (probability >> 5);
      result = 1;
    }
    normalize();
    return result;
  }

  /// Reads a normal or reverse binary probability tree.
  int tree(Uint16List probabilities, int offset, int bits, {bool reverse = false}) {
    int symbol = 1;
    int result = 0;
    for (int i = 0; i < bits; i++) {
      final int value = bit(probabilities, offset + symbol);
      symbol = (symbol << 1) | value;
      result |= value << i;
    }
    return reverse ? result : symbol - (1 << bits);
  }

  /// Reads equiprobable high distance bits.
  int direct(int count) {
    int value = 0;
    for (int i = 0; i < count; i++) {
      range >>>= 1;
      final int bit = code >= range ? 1 : 0;
      if (bit != 0) {
        code -= range;
      }
      value = value * 2 + bit;
      normalize();
    }
    return value;
  }

  /// Reads the low/middle/high match-length trees.
  int length(Uint16List probabilities, int position) {
    if (bit(probabilities, 0) == 0) {
      return 2 + tree(probabilities, 2 + position * 8, 3);
    }
    if (bit(probabilities, 1) == 0) {
      return 10 + tree(probabilities, 130 + position * 8, 3);
    }
    return 18 + tree(probabilities, 258, 8);
  }
}

/// Carry-aware range encoder using only integers exactly representable on JS.
final class _RangeEncoder {
  /// Encoded bytes.
  final BytesBuilder output = BytesBuilder();

  /// Lower interval endpoint, at most 33 significant bits.
  int low = 0;

  /// Current interval width.
  int range = 0xffffffff;

  /// Byte waiting for a possible carry.
  int cache = 0;

  /// Pending carry-propagation bytes.
  int cacheSize = 1;

  /// Emits an interval byte once its carry is known.
  void shiftLow() {
    final int lower = low % 0x100000000;
    final int carry = low ~/ 0x100000000;
    if (lower < 0xff000000 || carry != 0) {
      int value = cache;
      do {
        output.addByte((value + carry) & 255);
        value = 255;
      } while (--cacheSize != 0);
      cache = lower >>> 24;
    }
    cacheSize++;
    low = (lower & 0xffffff) * 256;
  }

  /// Renormalizes the interval.
  void normalize() {
    if (range < 0x1000000) {
      range = (range * 256) & 0xffffffff;
      shiftLow();
    }
  }

  /// Encodes and adapts one probability.
  void bit(Uint16List probabilities, int index, int value) {
    final int probability = probabilities[index];
    final int bound = (range >>> 11) * probability;
    if (value == 0) {
      range = bound;
      probabilities[index] = probability + ((2048 - probability) >> 5);
    } else {
      low += bound;
      range -= bound;
      probabilities[index] = probability - (probability >> 5);
    }
    normalize();
  }

  /// Writes a normal or reverse binary probability tree.
  void tree(Uint16List probabilities, int offset, int count, int value, {bool reverse = false}) {
    int symbol = 1;
    for (int i = 0; i < count; i++) {
      final int next = (value >>> (reverse ? i : count - 1 - i)) & 1;
      bit(probabilities, offset + symbol, next);
      symbol = (symbol << 1) | next;
    }
  }

  /// Writes equiprobable high distance bits.
  void direct(int count, int value) {
    for (int i = count - 1; i >= 0; i--) {
      range >>>= 1;
      if (((value >>> i) & 1) != 0) {
        low += range;
      }
      normalize();
    }
  }

  /// Writes a length from two through 273.
  void length(Uint16List probabilities, int position, int value) {
    if (value < 10) {
      bit(probabilities, 0, 0);
      tree(probabilities, 2 + position * 8, 3, value - 2);
    } else {
      bit(probabilities, 0, 1);
      if (value < 18) {
        bit(probabilities, 1, 0);
        tree(probabilities, 130 + position * 8, 3, value - 10);
      } else {
        bit(probabilities, 1, 1);
        tree(probabilities, 258, 8, value - 18);
      }
    }
  }

  /// Flushes the five final range bytes.
  Uint8List finish() {
    for (int i = 0; i < 5; i++) {
      shiftLow();
    }
    return output.takeBytes();
  }
}
