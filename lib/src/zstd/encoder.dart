part of 'package:zcodec/src/zstd.dart';

/// A literal run followed by a backward match, before entropy encoding.
typedef _ZstdSequence = ({int literals, int length, int distance});

/// Writes one frame using raw literals and predefined sequence distributions.
Uint8List _encodeZstd({required Uint8List bytes, required int level, required bool checksum}) {
  if (bytes.length > 0xffffffff) {
    throw const ZCodecException('Zstandard encoder input exceeds its 32-bit content size');
  }
  final ByteWriter writer = ByteWriter()
    ..writeUint32(_zstdMagic)
    ..writeByte(0x80 | (checksum ? 4 : 0))
    ..writeByte(0x38)
    ..writeUint32(bytes.length);
  if (bytes.isEmpty) {
    writer
      ..writeByte(1)
      ..writeUint16(0);
  }
  for (int start = 0; start < bytes.length; start += 65536) {
    final int end = start + 65536 < bytes.length ? start + 65536 : bytes.length;
    final Uint8List block = Uint8List.sublistView(bytes, start, end);
    final bool repeated = level > 0 && block.every((value) => value == block.first);
    final Uint8List? compressed = level > 0 && !repeated ? _compressZstdBlock(bytes: block, level: level) : null;
    final int type = repeated
        ? 1
        : compressed != null && compressed.length < block.length
        ? 2
        : 0;
    final int size = type == 2 ? compressed!.length : block.length;
    final int header = size * 8 + type * 2 + (end == bytes.length ? 1 : 0);
    writer
      ..writeByte(header & 255)
      ..writeUint16(header >> 8);
    if (type == 1) {
      writer.writeByte(block.first);
    } else {
      writer.writeBytes(type == 2 ? compressed! : block);
    }
  }
  if (checksum) {
    writer.writeUint32(_zstdChecksum(bytes));
  }
  return writer.takeBytes();
}

/// Finds block-local matches using bounded chains of four-byte hashes.
Uint8List? _compressZstdBlock({required Uint8List bytes, required int level}) {
  final Int32List heads = Int32List(65536)..fillRange(0, 65536, -1);
  final Int32List previous = Int32List(bytes.length)..fillRange(0, bytes.length, -1);
  final BytesBuilder literals = BytesBuilder();
  final List<_ZstdSequence> sequences = [];

  /// Records an input position and returns the preceding matching hash bucket.
  int remember(int offset) {
    final int hash = (((bytes[offset] * 251 + bytes[offset + 1]) * 251 + bytes[offset + 2]) * 251 + bytes[offset + 3]) & 65535;
    final int old = heads[hash];
    heads[hash] = offset;
    previous[offset] = old;
    return old;
  }

  int position = 0;
  int literalStart = 0;
  while (position + 4 <= bytes.length) {
    int candidate = remember(position);
    int bestLength = 3;
    int bestDistance = 0;
    int attempts = 1 << level;
    while (candidate >= 0 && attempts-- > 0) {
      int length = 0;
      while (position + length < bytes.length && bytes[candidate + length] == bytes[position + length]) {
        length++;
      }
      if (length > bestLength) {
        bestLength = length;
        bestDistance = position - candidate;
        if (position + length == bytes.length) {
          break;
        }
      }
      candidate = previous[candidate];
    }
    if (bestDistance == 0) {
      position++;
      continue;
    }
    literals.add(Uint8List.sublistView(bytes, literalStart, position));
    sequences.add((literals: position - literalStart, length: bestLength, distance: bestDistance));
    final int end = position + bestLength;
    for (int offset = position + 1; offset < end && offset + 4 <= bytes.length; offset++) {
      remember(offset);
    }
    position = end;
    literalStart = end;
  }
  if (sequences.isEmpty) {
    return null;
  }
  literals.add(Uint8List.sublistView(bytes, literalStart));
  final Uint8List literalBytes = literals.takeBytes();
  final ByteWriter writer = ByteWriter();
  final int count = literalBytes.length;
  final int header = count < 32 ? count * 8 : count * 16 + (count < 4096 ? 4 : 12);
  writer.writeByte(header & 255);
  if (count >= 32) {
    writer.writeByte((header >> 8) & 255);
  }
  if (count >= 4096) {
    writer.writeByte(header >> 16);
  }
  writer.writeBytes(literalBytes);
  if (sequences.length < 128) {
    writer.writeByte(sequences.length);
  } else if (sequences.length < 0x7f00) {
    writer
      ..writeByte((sequences.length >> 8) + 128)
      ..writeByte(sequences.length & 255);
  } else {
    writer
      ..writeByte(255)
      ..writeUint16(sequences.length - 0x7f00);
  }
  writer.writeByte(0);
  final BitWriter bits = BitWriter();
  int lengthState = 0;
  int matchState = 0;
  int offsetState = 0;

  /// Finds the code whose contiguous value range contains a length.
  int codeFor(int value, List<int> baselines) {
    int code = baselines.length - 1;
    while (baselines[code] > value) {
      code--;
    }
    return code;
  }

  /// Inverts an entropy transition, emitting the bits read by the decoder.
  int transition(_ZstdEntropyTable table, int symbol, int next, bool last) {
    for (int index = 0; index < table.states.length; index++) {
      final _ZstdTransition state = table.states[index];
      if (state.symbol == symbol && (last || next >= state.base && next < state.base + (1 << state.bits))) {
        if (!last) {
          bits.writeBits(next - state.base, state.bits);
        }
        return index;
      }
    }
    throw StateError('Zstandard sequence is outside the predefined alphabet');
  }

  for (int index = sequences.length - 1; index >= 0; index--) {
    final _ZstdSequence sequence = sequences[index];
    final int lengthCode = codeFor(sequence.literals, _zstdLiteralBase);
    final int matchCode = codeFor(sequence.length, _zstdMatchBase);
    final int offsetValue = sequence.distance + 3;
    final int offsetCode = offsetValue.bitLength - 1;
    final bool last = index == sequences.length - 1;
    offsetState = transition(_zstdOffsetTable, offsetCode, offsetState, last);
    matchState = transition(_zstdMatchTable, matchCode, matchState, last);
    lengthState = transition(_zstdLiteralTable, lengthCode, lengthState, last);
    bits
      ..writeBits(sequence.literals - _zstdLiteralBase[lengthCode], _zstdLiteralBits[lengthCode])
      ..writeBits(sequence.length - _zstdMatchBase[matchCode], _zstdMatchBits[matchCode])
      ..writeBits(offsetValue - (1 << offsetCode), offsetCode);
  }
  bits
    ..writeBits(matchState, _zstdMatchTable.accuracy)
    ..writeBits(offsetState, _zstdOffsetTable.accuracy)
    ..writeBits(lengthState, _zstdLiteralTable.accuracy)
    ..writeBits(1, 1);
  writer.writeBytes(bits.takeBytes());
  return writer.takeBytes();
}
