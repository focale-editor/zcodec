part of 'package:zcodec/src/deflate.dart';

/// Maximum backward distance permitted by RFC 1951.
const int _windowSize = 32768;

/// Longest byte run represented by one length symbol.
const int _maximumMatch = 258;

/// Shortest byte run worth encoding as a match.
const int _minimumMatch = 3;

/// Largest payload of one stored DEFLATE block.
const int _maximumStoredBlock = 65535;

/// Base match length for symbols 257 through 285.
const List<int> _lengthBases = <int>[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];

/// Extra-bit count for each match-length symbol.
const List<int> _lengthExtraBits = <int>[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];

/// Base backward distance for symbols 0 through 29.
const List<int> _distanceBases = <int>[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];

/// Extra-bit count for each backward-distance symbol.
const List<int> _distanceExtraBits = <int>[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

/// Order in which dynamic-block code lengths are stored.
const List<int> _codeLengthOrder = <int>[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/// Code lengths of the fixed literal/length alphabet.
final Uint8List _fixedLiteralLengths = Uint8List.fromList(<int>[
  for (int symbol = 0; symbol < 288; symbol++)
    if (symbol <= 143) 8 else if (symbol <= 255) 9 else if (symbol <= 279) 7 else 8,
]);

/// Decoder for the fixed literal/length alphabet.
final _HuffmanTable _fixedLiteralTable = _HuffmanTable(_fixedLiteralLengths, name: 'fixed literal/length');

/// Decoder for the fixed distance alphabet.
///
/// All 32 five-bit codes are defined so that the tree stays complete; symbols
/// 30 and 31 are rejected by the decoder as reserved values.
final _HuffmanTable _fixedDistanceTable = _HuffmanTable(Uint8List(32)..fillRange(0, 32, 5), name: 'fixed distance');

/// Bit-reversed code of every fixed literal/length symbol.
final Uint16List _fixedLiteralCodes = _buildFixedCodes();

/// Match-length symbol index for lengths 3 through 258.
final Uint8List _lengthSymbols = _buildLengthSymbols();

/// Distance symbol for distances 1 through 256.
final Uint8List _lowDistanceSymbols = _buildLowDistanceSymbols();

/// Distance symbol for distances above 256, indexed by `(distance - 1) >>> 7`.
final Uint8List _highDistanceSymbols = _buildHighDistanceSymbols();

/// Builds the reversed fixed-alphabet codes indexed by symbol.
Uint16List _buildFixedCodes() {
  final Uint16List codes = Uint16List(288);
  for (int symbol = 0; symbol < 288; symbol++) {
    codes[symbol] = switch (symbol) {
      <= 143 => _reverseBits(0x30 + symbol, 8),
      <= 255 => _reverseBits(0x190 + symbol - 144, 9),
      <= 279 => _reverseBits(symbol - 256, 7),
      _ => _reverseBits(0xc0 + symbol - 280, 8),
    };
  }
  return codes;
}

/// Builds the length-to-symbol lookup used by the encoder.
Uint8List _buildLengthSymbols() {
  final Uint8List symbols = Uint8List(_maximumMatch + 1);
  int index = 0;
  for (int length = _minimumMatch; length <= _maximumMatch; length++) {
    while (length > _lengthBases[index] + ((1 << _lengthExtraBits[index]) - 1)) {
      index++;
    }
    symbols[length] = index;
  }
  return symbols;
}

/// Builds the distance-to-symbol lookup for the first 256 distances.
Uint8List _buildLowDistanceSymbols() {
  final Uint8List symbols = Uint8List(257);
  int index = 0;
  for (int distance = 1; distance <= 256; distance++) {
    while (distance > _distanceBases[index] + ((1 << _distanceExtraBits[index]) - 1)) {
      index++;
    }
    symbols[distance] = index;
  }
  return symbols;
}

/// Builds the distance-to-symbol lookup for distances above 256.
Uint8List _buildHighDistanceSymbols() {
  final Uint8List symbols = Uint8List(_windowSize >>> 7);
  int index = 0;
  for (int slot = 0; slot < symbols.length; slot++) {
    final int distance = (slot << 7) + 1;
    while (distance > _distanceBases[index] + ((1 << _distanceExtraBits[index]) - 1)) {
      index++;
    }
    symbols[slot] = index;
  }
  return symbols;
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
