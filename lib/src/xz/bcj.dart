part of 'package:zcodec/src/xz.dart';

/// Incremental, length-preserving XZ prefilter.
abstract interface class _XzFilter {
  /// Decodes bytes, releasing any incomplete instruction on the final call.
  Uint8List decode(Uint8List bytes, {bool last = false});
}

/// BCJ decoders with bounded instruction tails across LZMA2 chunk boundaries.
///
/// The x86 conversion is adapted from archive 4.5.2; ARM64 follows XZ Utils
/// 5.8.4's arm64.c. See NOTICE for provenance and licenses.
final class _BcjDecoder implements _XzFilter {
  /// XZ filter identifier (x86=4, PowerPC=5, ARM64=10).
  final int id;

  /// Logical instruction address, including the header's start offset.
  int position;

  /// At most four bytes awaiting a complete instruction.
  Uint8List tail = Uint8List(0);

  /// x86 branch candidate mask carried between chunks.
  int previousMask = 0;

  /// Address of the previous x86 candidate.
  int previousPosition;

  /// Creates filter state at the specified instruction address.
  _BcjDecoder(this.id, this.position) : previousPosition = position - 5;
  @override
  Uint8List decode(Uint8List bytes, {bool last = false}) {
    final Uint8List buffer = joinBytes(tail, bytes);
    int cursor = 0;
    if (id == 4) {
      while (cursor + 4 < buffer.length) {
        if (buffer[cursor] & 0xfe != 0xe8) {
          cursor++;
          continue;
        }
        final int distance = position + cursor - previousPosition;
        previousPosition = position + cursor;
        if (distance > 5) {
          previousMask = 0;
        } else {
          for (int i = 0; i < distance; i++) {
            previousMask = ((previousMask & 0x77) << 1) & 255;
          }
        }
        final int high = buffer[cursor + 4];
        if (_bcjSignByte(high) && ((0x17 >>> ((previousMask >>> 1) & 7)) & 1) != 0 && (previousMask >>> 1) < 16) {
          final ByteData data = ByteData.sublistView(buffer);
          int source = data.getUint32(cursor + 1, Endian.little);
          int destination;
          while (true) {
            destination = (source - (position + cursor + 5)) & 0xffffffff;
            if (previousMask == 0) {
              break;
            }
            final int bitNumber = const [0, 1, 2, 2, 3, 3, 3, 3][previousMask >>> 1];
            if (!_bcjSignByte((destination >>> (24 - bitNumber * 8)) & 255)) {
              break;
            }
            source = (destination ^ const [0xffffffff, 0xffffff, 0xffff, 0xff][bitNumber]) & 0xffffffff;
          }
          data.setUint32(cursor + 1, destination, Endian.little);
          buffer[cursor + 4] = (~(((destination >>> 24) & 1) - 1)) & 255;
          cursor += 5;
          previousMask = 0;
        } else {
          previousMask |= 1;
          if (_bcjSignByte(high)) {
            previousMask |= 16;
          }
          cursor++;
        }
      }
    } else {
      final ByteData data = ByteData.sublistView(buffer);
      for (; cursor + 4 <= buffer.length; cursor += 4) {
        final int pc = (position + cursor) & 0xffffffff;
        if (id == 5) {
          final int instruction = data.getUint32(cursor);
          if (instruction & 0xfc000003 == 0x48000001) {
            data.setUint32(cursor, (instruction & 0xfc000003) | ((instruction - pc) & 0x03fffffc));
          }
        } else {
          int instruction = data.getUint32(cursor, Endian.little);
          if (instruction >>> 26 == 0x25) {
            instruction = 0x94000000 | ((instruction - (pc >>> 2)) & 0x03ffffff);
          } else if (instruction & 0x9f000000 == 0x90000000) {
            final int source = ((instruction >>> 29) & 3) | ((instruction >>> 3) & 0x001ffffc);
            if ((source + 0x00020000) & 0x001c0000 != 0) {
              continue;
            }
            final int destination = source - (pc >>> 12);
            instruction = (instruction & 0x9000001f) | ((destination & 3) << 29) | ((destination & 0x0003fffc) << 3) | ((-(destination & 0x00020000)) & 0x00e00000);
          }
          data.setUint32(cursor, instruction, Endian.little);
        }
      }
    }
    if (last) {
      tail = Uint8List(0);
      position += buffer.length;
      return buffer;
    }
    tail = Uint8List.fromList(Uint8List.sublistView(buffer, cursor));
    position += cursor;
    return Uint8List.sublistView(buffer, 0, cursor);
  }
}

/// Whether an x86 address has a sign-extension byte worth transforming.
bool _bcjSignByte(int byte) => byte == 0 || byte == 255;
