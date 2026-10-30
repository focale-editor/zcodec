part of 'package:zcodec/src/zstd.dart';

/// Reads Zstandard's reverse bitstreams without platform-sized integer shifts.
final class _ZstdReverseBits {
  /// Complete entropy-coded bytes, including the terminal one bit.
  final Uint8List bytes;

  /// Number of data bits remaining before the current cursor.
  int remaining;

  /// Locates and removes the mandatory terminal one bit and high zero padding.
  _ZstdReverseBits({required this.bytes}) : remaining = bytes.isEmpty ? 0 : (bytes.length - 1) * 8 + bytes.last.bitLength - 1 {
    if (bytes.isEmpty || bytes.last == 0) {
      throw const ZCodecException('Invalid Zstandard bitstream end marker');
    }
  }

  /// Looks ahead with zero padding below the beginning of the stream.
  int peek(int count) {
    int value = 0;
    for (int bit = remaining - 1; bit >= remaining - count; bit--) {
      value = value * 2 + (bit < 0 ? 0 : (bytes[bit ~/ 8] >>> (bit % 8)) & 1);
    }
    return value;
  }

  /// Consumes an exact field, rejecting truncation before advancing.
  int read(int count) {
    if (count < 0 || count > 32 || count > remaining) {
      throw const ZCodecException('Truncated Zstandard entropy stream');
    }
    final int result = peek(count);
    remaining -= count;
    return result;
  }
}

/// Returns a checked little-endian field without losing precision on the Web.
int _zstdInteger(ByteReader reader, int count) {
  int value = 0;
  int factor = 1;
  for (int index = 0; index < count; index++) {
    value += reader.readByte() * factor;
    if (value > 9007199254740991) {
      throw const ZCodecException('Zstandard integer exceeds the supported size');
    }
    factor *= 256;
  }
  return value;
}
