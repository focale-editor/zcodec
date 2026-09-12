part of 'package:zcodec/src/deflate.dart';

/// Compresses a buffer in independently costed blocks with shared history.
final class _DeflateEncoder {
  /// Uncompressed source.
  final Uint8List input;

  /// Match-search effort.
  final int level;

  /// Creates an encoder over [input].
  _DeflateEncoder(this.input, this.level);

  /// Emits stored, fixed, or dynamic blocks according to their bit costs.
  Uint8List encode() {
    final _DeflateBlockWriter writer = _DeflateBlockWriter(level, inputLength: input.length);
    int offset = 0;
    do {
      final int end = input.length - offset > _maximumStoredBlock ? offset + _maximumStoredBlock : input.length;
      writer.writeBlock(input, offset, end, isFinal: end == input.length);
      offset = end;
    } while (offset < input.length);
    return writer.output.takeBytes();
  }
}

/// Reuses a fixed-size match dictionary across DEFLATE blocks.
final class _DeflateBlockWriter {
  /// Destination bit stream.
  final BitWriter output = BitWriter();

  /// Compression effort.
  final int level;

  /// Latest absolute position plus one for each three-byte hash.
  late final Int32List _heads = Int32List(_mask + 1);

  /// Previous hash-chain links, indexed by position modulo the window size.
  late final Int32List _previous = Int32List(_mask + 1);

  /// Dictionary mask, reduced for known short, single-buffer inputs.
  final int _mask;

  /// Absolute position of the next block within the current dictionary epoch.
  int _position = 0;

  /// Number of candidates inspected at each compression level.
  static const List<int> _chainLengths = <int>[0, 4, 8, 16, 32, 64, 128, 256, 512, 1024];

  /// Match lengths that end a search early at each level.
  static const List<int> _sufficientMatches = <int>[0, 16, 24, 32, 48, 64, 96, 128, 192, 258];

  /// Creates an empty block writer.
  _DeflateBlockWriter(this.level, {int? inputLength}) : _mask = _dictionaryCapacity(inputLength ?? _windowSize) - 1;

  /// Writes [input] from [start] to [end], retaining preceding dictionary data.
  ///
  /// The source must also contain up to 32 KiB of preceding input before start.
  void writeBlock(Uint8List input, int start, int end, {required bool isFinal}) {
    final int length = end - start;
    if (level == 0) {
      _writeStoredBlock(output, input, start, end, isFinal: isFinal);
      return;
    }
    _rebase();
    final _DeflateTokens tokens = _tokenize(input, start, end);
    final int fixedCost = 3 + tokens.extraBits + _weightedBits(tokens.literals, _fixedLiteralLengths) + tokens.matchCount * 5;
    final int storedCost = 3 + ((8 - ((output.pendingBits + 3) & 7)) & 7) + 32 + length * 8;
    final _DynamicBlock? dynamic = length >= 64 ? _DynamicBlock(tokens) : null;
    final int dynamicCost = dynamic?.bitLength ?? fixedCost + 1;
    if (storedCost < fixedCost && storedCost <= dynamicCost) {
      _writeStoredBlock(output, input, start, end, isFinal: isFinal);
    } else if (dynamic != null && dynamicCost < fixedCost) {
      output.writeBits((isFinal ? 1 : 0) | 4, 3);
      dynamic.writeHeader(output);
      _writeTokens(output, tokens, dynamic.literalLengths, dynamic.literalCodes, dynamic.distanceLengths, dynamic.distanceCodes);
    } else {
      output.writeBits((isFinal ? 1 : 0) | 2, 3);
      _writeTokens(output, tokens, _fixedLiteralLengths, _fixedLiteralCodes, _fixedDistanceLengths, _fixedDistanceCodes);
    }
    _position += length;
  }

  /// Builds literal and match tokens without serializing rejected candidates.
  _DeflateTokens _tokenize(Uint8List input, int start, int end) {
    final _DeflateTokens result = _DeflateTokens(end - start);
    final int origin = _position - start;
    final Int32List heads = _heads;
    final Int32List previous = _previous;
    final int mask = _mask;
    final int maximumChain = _chainLengths[level];
    final int sufficient = _sufficientMatches[level];
    // The last two positions of the previous block could not yet be hashed.
    for (int index = start < 2 ? 0 : start - 2; index < start && index + 2 < end; index++) {
      final int hash = _hash(input, index, mask);
      final int absolute = index + origin;
      previous[absolute & mask] = heads[hash];
      heads[hash] = absolute + 1;
    }
    int position = start;
    int missed = 0;
    while (position < end) {
      int bestLength = 0;
      int bestDistance = 0;
      if (position + _minimumMatch <= end) {
        final int absolute = position + origin;
        final int hash = _hash(input, position, mask);
        int candidate = heads[hash] - 1;
        previous[absolute & mask] = heads[hash];
        heads[hash] = absolute + 1;
        int chain = maximumChain;
        final int oldest = absolute - _windowSize;
        final int limit = end - position < _maximumMatch ? end - position : _maximumMatch;
        while (candidate >= 0 && candidate >= oldest && chain-- > 0) {
          final int source = candidate - origin;
          if (input[source + bestLength] == input[position + bestLength] && input[source] == input[position]) {
            int length = 1;
            while (length < limit && input[source + length] == input[position + length]) {
              length++;
            }
            if (length >= _minimumMatch && length > bestLength) {
              bestLength = length;
              bestDistance = absolute - candidate;
              if (length >= sufficient || length == limit) {
                break;
              }
            }
          }
          // Inserting the current position overwrites the oldest ring slot.
          // It is still a valid candidate, but its old link is no longer valid.
          if (candidate == oldest) {
            break;
          }
          candidate = previous[candidate & mask] - 1;
        }
      }
      if (bestLength >= _minimumMatch) {
        missed = 0;
        result.addMatch(bestLength, bestDistance);
        final int matchEnd = position + bestLength;
        for (int index = position + 1; index < matchEnd && index + 2 < end; index++) {
          final int hash = _hash(input, index, mask);
          final int absolute = index + origin;
          previous[absolute & mask] = heads[hash];
          heads[hash] = absolute + 1;
        }
        position = matchEnd;
      } else {
        result.addLiteral(input[position++]);
        missed++;
        // Back off unsuccessful searches, but still populate every dictionary
        // position. A compressible region therefore resumes full matching at
        // the next probe, at most sixteen literals later.
        final int skip = missed >>> 5;
        final int probeEnd = position + (skip < 16 ? skip : 16);
        while (position < end && position < probeEnd) {
          if (position + 2 < end) {
            final int hash = _hash(input, position, mask);
            final int absolute = position + origin;
            previous[absolute & mask] = heads[hash];
            heads[hash] = absolute + 1;
          }
          result.addLiteral(input[position++]);
        }
      }
    }
    return result;
  }

  /// Keeps long-lived streams inside the signed 32-bit dictionary range.
  void _rebase() {
    if (_position < 0x40000000) {
      return;
    }
    final int shift = (_position & ~(_windowSize - 1)) - _windowSize;
    for (int index = 0; index < _windowSize; index++) {
      _heads[index] = _heads[index] > shift ? _heads[index] - shift : 0;
      _previous[index] = _previous[index] > shift ? _previous[index] - shift : 0;
    }
    _position -= shift;
  }
}

/// Literal bytes or packed distance/length back-references.
final class _DeflateTokens {
  /// Packed block tokens: literals, or distance shifted nine bits plus length.
  final Uint32List values;

  /// Literal/length frequencies, including the end-of-block symbol.
  final Uint32List literals = Uint32List(286)..[256] = 1;

  /// Distance-code frequencies.
  final Uint32List distances = Uint32List(30);

  /// Number of initialized tokens.
  int count = 0;

  /// Number of back-references.
  int matchCount = 0;

  /// Extra length and distance bits shared by both Huffman representations.
  int extraBits = 0;

  /// Reserves at most one token per input byte.
  _DeflateTokens(int maximumTokens) : values = Uint32List(maximumTokens);

  /// Records a literal byte.
  void addLiteral(int value) {
    values[count++] = value;
    literals[value]++;
  }

  /// Records a length/distance pair and its coding cost.
  void addMatch(int length, int distance) {
    values[count++] = (distance << 9) | length;
    final int lengthSymbol = _lengthSymbols[length];
    final int distanceSymbol = _distanceSymbol(distance);
    literals[257 + lengthSymbol]++;
    distances[distanceSymbol]++;
    extraBits += _lengthExtraBits[lengthSymbol] + _distanceExtraBits[distanceSymbol];
    matchCount++;
  }
}

/// Writes a token sequence and its end-of-block symbol.
void _writeTokens(BitWriter output, _DeflateTokens tokens, Uint8List literalLengths, Uint16List literalCodes, Uint8List distanceLengths, Uint16List distanceCodes) {
  for (int index = 0; index < tokens.count; index++) {
    final int token = tokens.values[index];
    if (token < 256) {
      output.writeBits(literalCodes[token], literalLengths[token]);
    } else {
      final int length = token & 511;
      final int distance = token >>> 9;
      final int lengthSymbol = _lengthSymbols[length];
      final int distanceSymbol = _distanceSymbol(distance);
      output
        ..writeBits(literalCodes[257 + lengthSymbol], literalLengths[257 + lengthSymbol])
        ..writeBits(length - _lengthBases[lengthSymbol], _lengthExtraBits[lengthSymbol])
        ..writeBits(distanceCodes[distanceSymbol], distanceLengths[distanceSymbol])
        ..writeBits(distance - _distanceBases[distanceSymbol], _distanceExtraBits[distanceSymbol]);
    }
  }
  output.writeBits(literalCodes[256], literalLengths[256]);
}

/// Writes one byte-aligned stored block with its length and complement.
void _writeStoredBlock(BitWriter output, Uint8List input, int start, int end, {required bool isFinal}) {
  final int length = end - start;
  output
    ..writeBits(isFinal ? 1 : 0, 3)
    ..alignToByte()
    ..writeByte(length & 0xff)
    ..writeByte((length >>> 8) & 0xff)
    ..writeByte((~length) & 0xff)
    ..writeByte(((~length) >>> 8) & 0xff)
    ..writeBytes(Uint8List.sublistView(input, start, end));
}

/// Hashes three consecutive bytes into the dictionary.
int _hash(Uint8List input, int position, int mask) => ((input[position] * 251 + input[position + 1]) * 251 + input[position + 2]) & mask;

/// Chooses a power-of-two table without overallocating for tiny entries.
int _dictionaryCapacity(int length) {
  int capacity = 256;
  while (capacity < length && capacity < _windowSize) {
    capacity *= 2;
  }
  return capacity;
}

/// Returns the code representing [distance].
int _distanceSymbol(int distance) => distance <= 256 ? _lowDistanceSymbols[distance] : _highDistanceSymbols[(distance - 1) >>> 7];

/// Counts the bits consumed by symbols with the supplied frequencies.
int _weightedBits(Uint32List frequencies, Uint8List lengths) {
  int bits = 0;
  for (int index = 0; index < frequencies.length; index++) {
    bits += frequencies[index] * lengths[index];
  }
  return bits;
}
