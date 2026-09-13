part of 'package:zcodec/src/deflate.dart';

/// Expands stored, fixed-Huffman, and dynamic-Huffman DEFLATE blocks.
final class _DeflateDecoder {
  /// Bit-aligned compressed input.
  final BitReader input;

  /// Bounded uncompressed output.
  final _OutputBuffer output;

  /// Creates a decoder capped at [maximumOutputBytes].
  _DeflateDecoder(this.input, int maximumOutputBytes) : output = _OutputBuffer(maximumOutputBytes);

  /// Decodes blocks through the final-block marker.
  Uint8List decode() {
    bool isFinal = false;
    while (!isFinal) {
      isFinal = input.readBits(1) == 1;
      switch (input.readBits(2)) {
        case 0:
          _decodeStored();
        case 1:
          _decodeHuffman(_fixedLiteralTable, _fixedDistanceTable);
        case 2:
          _decodeDynamic();
        default:
          throw const ZCodecException('Reserved DEFLATE block type');
      }
    }
    return output.takeBytes();
  }

  /// Decodes one byte-aligned stored block.
  void _decodeStored() {
    input.alignToByte();
    final int length = input.readBits(16);
    final int complement = input.readBits(16);
    if ((length ^ 0xffff) != complement) {
      throw const ZCodecException('Invalid stored-block length');
    }
    _reserveOutput(length);
    output.addBytes(input.readAlignedBytes(length));
  }

  /// Ensures room for [additional] bytes, growing toward the projected size.
  ///
  /// The final length is extrapolated from the compression ratio so far and
  /// bounded by the longest match per remaining input bit. Large outputs
  /// mostly fill freshly mapped memory, so fitting the buffer early is
  /// noticeably faster than doubling it repeatedly.
  void _reserveOutput(int additional) {
    if (output.capacity - output.length >= additional) {
      return;
    }
    final int consumed = input.byteOffset;
    output.reserve(
      additional,
      expectedLength: consumed == 0 ? 0 : output.length * input.bytes.length ~/ consumed,
      lengthBound: output.length + input.remainingBits * _maximumMatch,
    );
  }

  /// Builds and decodes the Huffman trees of one dynamic block.
  void _decodeDynamic() {
    final ({_HuffmanTable literals, _HuffmanTable distances}) trees = _readDynamicTrees(input);
    _decodeHuffman(trees.literals, trees.distances);
  }

  /// Decodes literals and back-references using the supplied trees.
  ///
  /// Tokens are decoded by [_decodeHuffmanFast] while both buffers have room,
  /// and one at a time with exact bounds checks near their ends.
  void _decodeHuffman(_HuffmanTable literals, _HuffmanTable distances) {
    while (true) {
      if (_decodeHuffmanFast(input, output, literals, distances, output.capacity - _maximumMatch)) {
        return;
      }
      // Growing here, before the slow token, lets the next fast run resume
      // instead of doubling the buffer inside [_OutputBuffer.copy].
      _reserveOutput(_maximumMatch * 2);
      final int symbol = literals.read(input);
      if (symbol < 256) {
        output.add(symbol);
      } else if (symbol == 256) {
        return;
      } else if (symbol <= 285) {
        final int index = symbol - 257;
        final int length = _lengthBases[index] + input.readBits(_lengthExtraBits[index]);
        if (distances.isEmpty) {
          throw const ZCodecException('Length encountered without a distance tree');
        }
        final int distanceSymbol = distances.read(input);
        if (distanceSymbol >= _distanceBases.length) {
          throw const ZCodecException('Reserved DEFLATE distance symbol');
        }
        output.copy(_distanceBases[distanceSymbol] + input.readBits(_distanceExtraBits[distanceSymbol]), length);
      } else {
        throw const ZCodecException('Reserved DEFLATE length symbol');
      }
    }
  }
}

/// Input bytes that one fast token may load, from an empty to a full buffer.
///
/// A token consumes at most 48 bits and the buffer ends with at most 32, so
/// no token loads more than ten bytes.
const int _fastInputMargin = 10;

/// Decodes tokens while the input and output buffers have safe margins.
///
/// Returns whether the end-of-block symbol was consumed. Otherwise it stops
/// at a token boundary once fewer than [_fastInputMargin] input bytes remain
/// or the output reaches [outputLimit], which must leave [_maximumMatch]
/// bytes of capacity. The caller then continues with exact checks.
///
/// The bit buffer, both offsets, and the tables live in local variables for
/// the whole loop instead of going through the reader and the output buffer
/// for every token. Do not capture these variables in a closure: captured
/// variables would move to the heap.
bool _decodeHuffmanFast(BitReader input, _OutputBuffer output, _HuffmanTable literals, _HuffmanTable distances, int outputLimit) {
  final Uint8List source = input.bytes;
  final int inputLimit = source.length - _fastInputMargin;
  int inputOffset = input.loadedByteOffset;
  int outputOffset = output.length;
  if (inputOffset > inputLimit || outputOffset >= outputLimit) {
    return false;
  }
  assert(output.capacity - outputLimit >= _maximumMatch, 'Fast decoding requires a full match of spare capacity');
  int bits = input.bitBuffer;
  int bitCount = input.bitBufferLength;
  final Uint8List target = output._bytes;
  final Uint32List literalEntries = literals._entries;
  final int literalRootLength = literals._rootLength;
  final int literalRootMask = (1 << literalRootLength) - 1;
  final Uint32List distanceEntries = distances._entries;
  final int distanceRootLength = distances._rootLength;
  final int distanceRootMask = (1 << distanceRootLength) - 1;
  bool endOfBlock = false;
  while (inputOffset <= inputLimit && outputOffset < outputLimit) {
    // Twenty bits cover a literal/length code and its extra bits. Refills stop
    // at 32 bits, which keeps every shift exact on the Web.
    if (bitCount < 20) {
      do {
        bits |= source[inputOffset++] << bitCount;
        bitCount += 8;
      } while (bitCount <= 24);
    }
    int entry = literalEntries[bits & literalRootMask];
    if ((entry & 0xf) == 0) {
      if (entry != 0) {
        entry = literalEntries[(entry >>> 8) + ((bits >>> literalRootLength) & ((1 << ((entry >>> 4) & 0xf)) - 1))];
      }
      if (entry == 0) {
        throw const ZCodecException('Invalid Huffman code');
      }
    }
    int codeLength = entry & 0xf;
    bits >>>= codeLength;
    bitCount -= codeLength;
    final int symbol = entry >>> 4;
    if (symbol < 256) {
      target[outputOffset++] = symbol;
      continue;
    }
    if (symbol == 256) {
      endOfBlock = true;
      break;
    }
    if (symbol > 285) {
      throw const ZCodecException('Reserved DEFLATE length symbol');
    }
    if (distances.isEmpty) {
      throw const ZCodecException('Length encountered without a distance tree');
    }
    final int lengthIndex = symbol - 257;
    final int lengthExtraBits = _lengthExtraBits[lengthIndex];
    final int length = _lengthBases[lengthIndex] + (bits & ((1 << lengthExtraBits) - 1));
    bits >>>= lengthExtraBits;
    bitCount -= lengthExtraBits;
    if (bitCount < 15) {
      do {
        bits |= source[inputOffset++] << bitCount;
        bitCount += 8;
      } while (bitCount <= 24);
    }
    entry = distanceEntries[bits & distanceRootMask];
    if ((entry & 0xf) == 0) {
      if (entry != 0) {
        entry = distanceEntries[(entry >>> 8) + ((bits >>> distanceRootLength) & ((1 << ((entry >>> 4) & 0xf)) - 1))];
      }
      if (entry == 0) {
        throw const ZCodecException('Invalid Huffman code');
      }
    }
    codeLength = entry & 0xf;
    bits >>>= codeLength;
    bitCount -= codeLength;
    final int distanceSymbol = entry >>> 4;
    if (distanceSymbol >= _distanceBases.length) {
      throw const ZCodecException('Reserved DEFLATE distance symbol');
    }
    final int distanceExtraBits = _distanceExtraBits[distanceSymbol];
    if (bitCount < distanceExtraBits) {
      do {
        bits |= source[inputOffset++] << bitCount;
        bitCount += 8;
      } while (bitCount <= 24);
    }
    final int distance = _distanceBases[distanceSymbol] + (bits & ((1 << distanceExtraBits) - 1));
    bits >>>= distanceExtraBits;
    bitCount -= distanceExtraBits;
    if (distance > outputOffset) {
      throw const ZCodecException('Invalid DEFLATE back-reference distance');
    }
    final int from = outputOffset - distance;
    if (distance == 1) {
      target.fillRange(outputOffset, outputOffset + length, target[from]);
    } else if (length <= 32 || distance < length) {
      // Short copies are cheaper inline than through setRange, and a forward
      // byte loop replicates overlapping references correctly.
      for (int index = 0; index < length; index++) {
        target[outputOffset + index] = target[from + index];
      }
    } else {
      target.setRange(outputOffset, outputOffset + length, target, from);
    }
    outputOffset += length;
  }
  input.restoreBuffer(loadedByteOffset: inputOffset, bitBuffer: bits, bitBufferLength: bitCount);
  output.length = outputOffset;
  return endOfBlock;
}

/// Reads the complete Huffman description at the start of a dynamic block.
({_HuffmanTable literals, _HuffmanTable distances}) _readDynamicTrees(BitReader input) {
  final int literalCount = input.readBits(5) + 257;
  final int distanceCount = input.readBits(5) + 1;
  final int codeLengthCount = input.readBits(4) + 4;
  final Uint8List codeLengths = Uint8List(_codeLengthOrder.length);
  for (int index = 0; index < codeLengthCount; index++) {
    codeLengths[_codeLengthOrder[index]] = input.readBits(3);
  }
  final _HuffmanTable codeLengthTable = _HuffmanTable(codeLengths, name: 'code-length');
  final int total = literalCount + distanceCount;
  final Uint8List lengths = Uint8List(total);
  int written = 0;
  while (written < total) {
    final int symbol = codeLengthTable.read(input);
    if (symbol <= 15) {
      lengths[written++] = symbol;
      continue;
    }
    final int value;
    final int count;
    switch (symbol) {
      case 16:
        if (written == 0) {
          throw const ZCodecException('A repeated code length has no predecessor');
        }
        value = lengths[written - 1];
        count = input.readBits(2) + 3;
      case 17:
        value = 0;
        count = input.readBits(3) + 3;
      case 18:
        value = 0;
        count = input.readBits(7) + 11;
      default:
        throw const ZCodecException('Invalid code-length symbol');
    }
    if (written + count > total) {
      throw const ZCodecException('Repeated code lengths exceed the Huffman alphabet');
    }
    lengths.fillRange(written, written + count, value);
    written += count;
  }
  if (lengths[256] == 0) {
    throw const ZCodecException('DEFLATE block has no end-of-block symbol');
  }
  return (
    literals: _HuffmanTable(Uint8List.sublistView(lengths, 0, literalCount), name: 'literal/length'),
    distances: _HuffmanTable(Uint8List.sublistView(lengths, literalCount), name: 'distance', rootLength: 8, allowEmpty: true),
  );
}
