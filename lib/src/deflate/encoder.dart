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
  final BitWriter output;

  /// Compression effort.
  final int level;

  /// Latest absolute position plus one for each chain key hash.
  late final Int32List _heads = Int32List(_mask + 1);

  /// Previous hash-chain links, indexed by position modulo the window size.
  late final Int32List _previous = Int32List(_mask + 1);

  /// Latest absolute position plus one for each three-byte hash, maintained
  /// only by blocks whose chains use four-byte keys.
  late final Int32List _trigramHeads = Int32List(_mask + 1);

  /// Absolute position of the first input byte not yet in the dictionary.
  int _insertedEnd = 0;

  /// Reusable storage for the complete bytes of serialized tokens.
  Uint8List _tokenBytes = Uint8List(0);

  /// Dictionary mask, reduced for known short, single-buffer inputs.
  final int _mask;

  /// Absolute position of the next block within the current dictionary epoch.
  int _position = 0;

  /// Number of candidates inspected at each compression level.
  static const List<int> _chainLengths = <int>[0, 4, 8, 16, 32, 64, 128, 256, 512, 1024];

  /// Match lengths that end a search early at each level.
  static const List<int> _sufficientMatches = <int>[0, 16, 24, 32, 48, 64, 96, 128, 192, 258];

  /// Creates an empty block writer.
  ///
  /// A known [inputLength] sizes the dictionary and, for stored output, the
  /// exact output buffer.
  _DeflateBlockWriter(this.level, {int? inputLength})
    : _mask = _dictionaryCapacity(inputLength ?? _windowSize) - 1,
      output = BitWriter(initialCapacity: level == 0 && inputLength != null ? _storedLength(inputLength) : 1024);

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
      _writeTokens(tokens, dynamic.literalLengths, dynamic.literalCodes, dynamic.distanceLengths, dynamic.distanceCodes);
    } else {
      output.writeBits((isFinal ? 1 : 0) | 2, 3);
      _writeTokens(tokens, _fixedLiteralLengths, _fixedLiteralCodes, _fixedDistanceLengths, _fixedDistanceCodes);
    }
    _position += length;
  }

  /// Builds literal and match tokens without serializing rejected candidates.
  ///
  /// Hash chains normally link positions sharing three bytes. On a small
  /// alphabet, such as text or predicted image samples, three-byte strings
  /// repeat so often that chains fill the window with candidates that rarely
  /// extend, and the search slows down several times. Such blocks chain on
  /// four bytes instead and look up three-byte matches in a table holding only
  /// the latest occurrence, which is also the cheapest to encode. Fast levels
  /// walk too few candidates for this to pay off.
  ///
  /// The dictionary, the token storage, and their counters live in local
  /// variables for the whole block.
  _DeflateTokens _tokenize(Uint8List input, int start, int end) {
    final _DeflateTokens result = _DeflateTokens(end - start);
    final Uint32List values = result.values;
    final Uint32List literals = result.literals;
    final Uint32List distances = result.distances;
    int count = 0;
    int matchCount = 0;
    int extraBits = 0;
    final int origin = _position - start;
    final Int32List heads = _heads;
    final Int32List previous = _previous;
    final Int32List? trigramHeads = level >= _fourByteChainLevel && end - start >= _smallAlphabetMinimumBlock && _hasSmallAlphabet(input, start, end) ? _trigramHeads : null;
    final int mask = _mask;
    final int maximumChain = _chainLengths[level];
    final int sufficient = _sufficientMatches[level];
    // Positions from here on have a complete chain key inside the block.
    final int lastKey = end - (trigramHeads == null ? 3 : 4);
    // The previous block could not insert its last positions without the
    // bytes that follow them.
    final int oldestPending = start - _windowSize;
    for (int index = _insertedEnd - origin < oldestPending ? oldestPending : _insertedEnd - origin; index < start && index <= lastKey; index++) {
      if (index >= 0) {
        _insertPosition(heads, previous, trigramHeads, mask, input, index, index + origin);
      }
    }
    int position = start;
    int missed = 0;
    while (position < end) {
      int bestLength = 0;
      int bestDistance = 0;
      if (position <= lastKey) {
        final int absolute = position + origin;
        final int oldest = absolute - _windowSize;
        final int lowest = oldest < 0 ? 0 : oldest;
        final int limit = end - position < _maximumMatch ? end - position : _maximumMatch;
        final int firstByte = input[position];
        final int trigram = (firstByte * 251 + input[position + 1]) * 251 + input[position + 2];
        final int hash;
        if (trigramHeads == null) {
          hash = trigram & mask;
        } else {
          hash = (trigram * 251 + input[position + 3]) & mask;
          final int trigramCandidate = trigramHeads[trigram & mask] - 1;
          trigramHeads[trigram & mask] = absolute + 1;
          final int source = trigramCandidate - origin;
          if (trigramCandidate >= lowest && input[source] == firstByte && input[source + 1] == input[position + 1] && input[source + 2] == input[position + 2]) {
            int length = 3;
            while (length < limit && input[source + length] == input[position + length]) {
              length++;
            }
            bestLength = length;
            bestDistance = absolute - trigramCandidate;
          }
        }
        int candidate = heads[hash] - 1;
        previous[absolute & mask] = heads[hash];
        heads[hash] = absolute + 1;
        int chain = bestLength >= sufficient || bestLength == limit ? 0 : maximumChain;
        // A candidate can only improve on the best match if it agrees on the
        // last matched byte and the one just past it, which rejects most
        // candidates with two reads.
        int scanStart = bestLength == 0 ? 0 : bestLength - 1;
        int scan = chain == 0 ? 0 : (input[position + scanStart] << 8) | input[position + bestLength];
        while (candidate >= lowest && chain-- > 0) {
          final int source = candidate - origin;
          if (((input[source + scanStart] << 8) | input[source + bestLength]) == scan && input[source] == firstByte) {
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
              scanStart = length - 1;
              scan = (input[position + scanStart] << 8) | input[position + length];
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
        values[count++] = (bestDistance << 9) | bestLength;
        final int lengthSymbol = _lengthSymbols[bestLength];
        final int distanceSymbol = _distanceSymbol(bestDistance);
        literals[257 + lengthSymbol]++;
        distances[distanceSymbol]++;
        extraBits += _lengthExtraBits[lengthSymbol] + _distanceExtraBits[distanceSymbol];
        matchCount++;
        final int matchEnd = position + bestLength;
        for (int index = position + 1; index < matchEnd && index <= lastKey; index++) {
          _insertPosition(heads, previous, trigramHeads, mask, input, index, index + origin);
        }
        position = matchEnd;
      } else {
        final int literal = input[position++];
        values[count++] = literal;
        literals[literal]++;
        missed++;
        // Back off unsuccessful searches, but still populate every dictionary
        // position. A compressible region therefore resumes full matching at
        // the next probe, at most sixteen literals later.
        final int skip = missed >>> 5;
        final int probeEnd = position + (skip < 16 ? skip : 16);
        while (position < end && position < probeEnd) {
          if (position <= lastKey) {
            _insertPosition(heads, previous, trigramHeads, mask, input, position, position + origin);
          }
          final int skipped = input[position++];
          values[count++] = skipped;
          literals[skipped]++;
        }
      }
    }
    if (lastKey + 1 + origin > _insertedEnd) {
      _insertedEnd = lastKey + 1 + origin;
    }
    result
      ..count = count
      ..matchCount = matchCount
      ..extraBits = extraBits;
    return result;
  }

  /// Writes a token sequence and its end-of-block symbol.
  ///
  /// Bits accumulate in local variables and complete bytes go to a reusable
  /// buffer, which is much cheaper than one [BitWriter.writeBits] call per
  /// code. Two bytes are flushed after each field once 16 bits are pending, so
  /// adding a field of up to 16 bits never exceeds 32 bits, which keeps shifts
  /// exact on the Web.
  void _writeTokens(_DeflateTokens tokens, Uint8List literalLengths, Uint16List literalCodes, Uint8List distanceLengths, Uint16List distanceCodes) {
    // A token takes at most 48 bits: a length code and its extra bits, then a
    // distance code and its extra bits.
    final int capacity = tokens.count * 6 + 6;
    if (_tokenBytes.length < capacity) {
      _tokenBytes = Uint8List(capacity);
    }
    final Uint8List bytes = _tokenBytes;
    final Uint32List values = tokens.values;
    final ({int bits, int count}) pending = output.takePendingBits();
    int bits = pending.bits;
    int bitCount = pending.count;
    int length = 0;
    for (int index = 0; index <= tokens.count; index++) {
      final int token = index == tokens.count ? 256 : values[index];
      if (token <= 256) {
        bits |= literalCodes[token] << bitCount;
        bitCount += literalLengths[token];
      } else {
        final int matchLength = token & 511;
        final int distance = token >>> 9;
        final int lengthSymbol = _lengthSymbols[matchLength];
        final int distanceSymbol = _distanceSymbol(distance);
        bits |= literalCodes[257 + lengthSymbol] << bitCount;
        bitCount += literalLengths[257 + lengthSymbol];
        if (bitCount >= 16) {
          bytes[length] = bits & 0xff;
          bytes[length + 1] = (bits >>> 8) & 0xff;
          length += 2;
          bits >>>= 16;
          bitCount -= 16;
        }
        bits |= (matchLength - _lengthBases[lengthSymbol]) << bitCount;
        bitCount += _lengthExtraBits[lengthSymbol];
        if (bitCount >= 16) {
          bytes[length] = bits & 0xff;
          bytes[length + 1] = (bits >>> 8) & 0xff;
          length += 2;
          bits >>>= 16;
          bitCount -= 16;
        }
        bits |= distanceCodes[distanceSymbol] << bitCount;
        bitCount += distanceLengths[distanceSymbol];
        if (bitCount >= 16) {
          bytes[length] = bits & 0xff;
          bytes[length + 1] = (bits >>> 8) & 0xff;
          length += 2;
          bits >>>= 16;
          bitCount -= 16;
        }
        bits |= (distance - _distanceBases[distanceSymbol]) << bitCount;
        bitCount += _distanceExtraBits[distanceSymbol];
      }
      if (bitCount >= 16) {
        bytes[length] = bits & 0xff;
        bytes[length + 1] = (bits >>> 8) & 0xff;
        length += 2;
        bits >>>= 16;
        bitCount -= 16;
      }
    }
    while (bitCount >= 8) {
      bytes[length++] = bits & 0xff;
      bits >>>= 8;
      bitCount -= 8;
    }
    output
      ..writeBytes(Uint8List.sublistView(bytes, 0, length))
      ..writeBits(bits, bitCount);
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
      _trigramHeads[index] = _trigramHeads[index] > shift ? _trigramHeads[index] - shift : 0;
    }
    _position -= shift;
    _insertedEnd -= shift;
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

/// Links [position] into the hash chains of the current block.
///
/// Without [trigramHeads], chains are keyed by the three bytes at [position];
/// otherwise by four bytes, and [trigramHeads] records the three-byte key. Both
/// hashes stay below 2^33 before masking, so they are exact on the Web too.
@pragma('vm:prefer-inline')
void _insertPosition(Int32List heads, Int32List previous, Int32List? trigramHeads, int mask, Uint8List input, int position, int absolute) {
  final int trigram = (input[position] * 251 + input[position + 1]) * 251 + input[position + 2];
  final int hash;
  if (trigramHeads == null) {
    hash = trigram & mask;
  } else {
    trigramHeads[trigram & mask] = absolute + 1;
    hash = (trigram * 251 + input[position + 3]) & mask;
  }
  previous[absolute & mask] = heads[hash];
  heads[hash] = absolute + 1;
}

/// Lowest compression level whose small-alphabet blocks chain on four bytes.
const int _fourByteChainLevel = 4;

/// Number of distinct byte values below which blocks chain on four bytes.
const int _smallAlphabet = 64;

/// Shortest block whose alphabet is considered: shorter blocks trivially use
/// few byte values but are too short for long chains to form.
const int _smallAlphabetMinimumBlock = 4096;

/// Whether [input] from [start] to [end] uses fewer than [_smallAlphabet]
/// distinct byte values.
bool _hasSmallAlphabet(Uint8List input, int start, int end) {
  final Uint8List seen = Uint8List(256);
  int distinct = 0;
  for (int index = start; index < end; index++) {
    if (seen[input[index]] == 0) {
      seen[input[index]] = 1;
      if (++distinct == _smallAlphabet) {
        return false;
      }
    }
  }
  return true;
}

/// Returns the size of [length] bytes written as stored blocks.
int _storedLength(int length) => length + 5 * (length == 0 ? 1 : (length + _maximumStoredBlock - 1) ~/ _maximumStoredBlock);

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
