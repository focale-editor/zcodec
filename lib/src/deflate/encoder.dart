part of 'package:zcodec/src/deflate.dart';

/// Compresses one buffer with LZ77 matching and the fixed Huffman alphabet.
final class _DeflateEncoder {
  /// Uncompressed bytes being encoded.
  final Uint8List input;

  /// Requested compression effort from 1 through 9.
  final int level;

  /// Creates a fixed-Huffman encoder for [input].
  _DeflateEncoder(this.input, this.level);

  /// Number of match candidates inspected per position, indexed by level.
  static const List<int> _chainLengths = <int>[0, 4, 8, 16, 32, 64, 128, 256, 512, 1024];

  /// Match length that ends the search early, indexed by level.
  static const List<int> _sufficientMatches = <int>[0, 16, 24, 32, 48, 64, 96, 128, 192, 258];

  /// Compresses all input into one final fixed-Huffman block.
  Uint8List encode() {
    final BitWriter output = BitWriter()
      ..writeBits(1, 1)
      ..writeBits(1, 2);
    final Int32List heads = Int32List(_windowSize);
    final Int32List previous = Int32List(input.length);
    final int maximumChain = _chainLengths[level];
    final int sufficient = _sufficientMatches[level];
    int position = 0;
    while (position < input.length) {
      int bestLength = 0;
      int bestDistance = 0;
      if (position + _minimumMatch <= input.length) {
        final int hash = _hash(position);
        int candidate = heads[hash] - 1;
        previous[position] = heads[hash];
        heads[hash] = position + 1;
        int chain = maximumChain;
        final int oldest = position - _windowSize;
        final int limit = input.length - position < _maximumMatch ? input.length - position : _maximumMatch;
        while (candidate >= 0 && candidate >= oldest && chain-- > 0) {
          // Comparing the byte just past the current best match first rejects
          // most candidates without walking the whole run.
          if (input[candidate + bestLength] == input[position + bestLength] && input[candidate] == input[position]) {
            int length = 1;
            while (length < limit && input[candidate + length] == input[position + length]) {
              length++;
            }
            if (length >= _minimumMatch && length > bestLength) {
              bestLength = length;
              bestDistance = position - candidate;
              if (length >= sufficient || length >= limit) {
                break;
              }
            }
          }
          candidate = previous[candidate] - 1;
        }
      }

      if (bestLength >= _minimumMatch) {
        _writeLength(output, bestLength);
        _writeDistance(output, bestDistance);
        final int end = position + bestLength;
        position++;
        while (position < end) {
          if (position + _minimumMatch <= input.length) {
            final int hash = _hash(position);
            previous[position] = heads[hash];
            heads[hash] = position + 1;
          }
          position++;
        }
      } else {
        _writeSymbol(output, input[position]);
        position++;
      }
    }
    _writeSymbol(output, 256);
    return output.takeBytes();
  }

  /// Hashes three bytes at [position] into the match-chain table.
  int _hash(int position) => ((input[position] * 251 + input[position + 1]) * 251 + input[position + 2]) & (_windowSize - 1);
}

/// Encodes [input] as one or more uncompressed DEFLATE blocks.
Uint8List _encodeStored(Uint8List input) {
  final BitWriter output = BitWriter();
  int offset = 0;
  do {
    final int remaining = input.length - offset;
    final int length = remaining < _maximumStoredBlock ? remaining : _maximumStoredBlock;
    final bool isFinal = offset + length == input.length;
    output
      ..writeBits(isFinal ? 1 : 0, 1)
      ..writeBits(0, 2)
      ..alignToByte()
      ..writeByte(length & 0xff)
      ..writeByte((length >>> 8) & 0xff)
      ..writeByte((~length) & 0xff)
      ..writeByte(((~length) >>> 8) & 0xff)
      ..writeBytes(Uint8List.sublistView(input, offset, offset + length));
    offset += length;
  } while (offset < input.length);
  return output.takeBytes();
}

/// Returns the exact size [_encodeStored] would produce for [length] bytes.
int _storedLength(int length) {
  final int blocks = length == 0 ? 1 : (length + _maximumStoredBlock - 1) ~/ _maximumStoredBlock;
  return blocks * 5 + length;
}

/// Writes the fixed-alphabet code of one literal or length [symbol].
void _writeSymbol(BitWriter output, int symbol) => output.writeBits(_fixedLiteralCodes[symbol], _fixedLiteralLengths[symbol]);

/// Writes the RFC 1951 symbol and extra bits for [length].
void _writeLength(BitWriter output, int length) {
  final int index = _lengthSymbols[length];
  _writeSymbol(output, 257 + index);
  output.writeBits(length - _lengthBases[index], _lengthExtraBits[index]);
}

/// Writes the RFC 1951 symbol and extra bits for [distance].
void _writeDistance(BitWriter output, int distance) {
  final int index = distance <= 256 ? _lowDistanceSymbols[distance] : _highDistanceSymbols[(distance - 1) >>> 7];
  output
    ..writeBits(_reverseBits(index, 5), 5)
    ..writeBits(distance - _distanceBases[index], _distanceExtraBits[index]);
}
