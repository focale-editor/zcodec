part of 'package:zcodec/src/xz.dart';

/// XZ stream signature.
const List<int> _xzMagic = [253, 55, 122, 88, 90, 0];

/// Writes a canonical base-128 XZ variable-length integer.
void _xzNumber(ByteWriter output, int value) {
  int remaining = value;
  do {
    final int byte = remaining & 127;
    remaining ~/= 128;
    output.writeByte(byte | (remaining == 0 ? 0 : 128));
  } while (remaining != 0);
}

/// Reads a canonical integer within the exact range shared by VM and Web.
int _readXzNumber(ByteReader input) {
  int value = 0;
  int scale = 1;
  for (int i = 0; i < 8; i++) {
    final int byte = input.readByte();
    value += (byte & 127) * scale;
    if (value > 0x1fffffffffffff || (i > 0 && byte == 0)) {
      throw const ZCodecException('Invalid or oversized XZ integer');
    }
    if (byte < 128) {
      return value;
    }
    scale *= 128;
  }
  throw const ZCodecException('Oversized XZ integer');
}

/// Writes mandatory CRC32 after a header/index payload.
Uint8List _xzWithCrc(Uint8List bytes) {
  final ByteWriter writer = ByteWriter()
    ..writeBytes(bytes)
    ..writeUint32(crc32(bytes));
  return writer.takeBytes();
}

/// Verifies a trailing CRC32 field and returns the checked payload.
Uint8List _xzVerifyCrc(Uint8List bytes) {
  if (bytes.length < 4) {
    throw const ZCodecException('Truncated XZ CRC');
  }
  final Uint8List payload = Uint8List.sublistView(bytes, 0, bytes.length - 4);
  final int expected = ByteData.sublistView(bytes).getUint32(bytes.length - 4, Endian.little);
  if (crc32(payload) != expected) {
    throw const ZCodecException('XZ structure checksum mismatch');
  }
  return payload;
}

/// Compares short framing or integrity fields without string conversions.
bool _xzEqual(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  for (int i = 0; i < first.length; i++) {
    if (first[i] != second[i]) {
      return false;
    }
  }
  return true;
}

/// Creates the exact canonical index expected from observed block sizes.
Uint8List _xzIndex(List<(int, int)> records) {
  final ByteWriter writer = ByteWriter()..writeByte(0);
  _xzNumber(writer, records.length);
  for (final (int packed, int unpacked) in records) {
    _xzNumber(writer, packed);
    _xzNumber(writer, unpacked);
  }
  writer.writeZeroes((-writer.length) & 3);
  return _xzWithCrc(writer.takeBytes());
}
