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
    output.addBytes(input.readAlignedBytes(length));
  }

  /// Builds and decodes the Huffman trees of one dynamic block.
  void _decodeDynamic() {
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
    _decodeHuffman(
      _HuffmanTable(Uint8List.sublistView(lengths, 0, literalCount), name: 'literal/length'),
      _HuffmanTable(Uint8List.sublistView(lengths, literalCount), name: 'distance', allowEmpty: true),
    );
  }

  /// Decodes literals and back-references using the supplied trees.
  void _decodeHuffman(_HuffmanTable literals, _HuffmanTable distances) {
    while (true) {
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
