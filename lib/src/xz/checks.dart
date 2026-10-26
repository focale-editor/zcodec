part of 'package:zcodec/src/xz.dart';

/// Reflected CRC64/XZ table represented by portable pairs of unsigned words.
final List<(int, int)> _crc64Table = List.generate(256, (index) {
  int low = index;
  int high = 0;
  for (int bit = 0; bit < 8; bit++) {
    final bool carry = low & 1 != 0;
    low = (low >>> 1) | ((high & 1) << 31);
    high >>>= 1;
    if (carry) {
      low ^= 0xd7870f42;
      high ^= 0xc96c5795;
    }
  }
  return (low & 0xffffffff, high & 0xffffffff);
});

/// Incremental integrity check for one XZ block.
final class _XzDigest {
  /// Selected stream-wide check algorithm.
  final XzCheck check;

  /// CRC32 accumulator, used only for that check.
  final Crc32Accumulator crc = Crc32Accumulator();

  /// SHA-256 accumulator, allocated only when needed.
  final Sha256? sha;

  /// Low CRC64 word.
  int low = 0xffffffff;

  /// High CRC64 word.
  int high = 0xffffffff;

  /// Creates an empty integrity accumulator.
  _XzDigest(this.check) : sha = check == XzCheck.sha256 ? Sha256() : null;

  /// Absorbs uncompressed block bytes.
  void add(Uint8List bytes) {
    switch (check) {
      case XzCheck.none:
        break;
      case XzCheck.crc32:
        crc.add(bytes);
      case XzCheck.crc64:
        for (final int byte in bytes) {
          final (int tableLow, int tableHigh) = _crc64Table[(low ^ byte) & 255];
          low = (((low >>> 8) | ((high & 255) << 24)) ^ tableLow) & 0xffffffff;
          high = ((high >>> 8) ^ tableHigh) & 0xffffffff;
        }
      case XzCheck.sha256:
        sha!.add(bytes);
    }
  }

  /// Returns the encoded check field.
  Uint8List finish() {
    final ByteWriter writer = ByteWriter();
    switch (check) {
      case XzCheck.none:
        break;
      case XzCheck.crc32:
        writer.writeUint32(crc.value);
      case XzCheck.crc64:
        writer
          ..writeUint32(low ^ 0xffffffff)
          ..writeUint32(high ^ 0xffffffff);
      case XzCheck.sha256:
        return sha!.close();
    }
    return writer.takeBytes();
  }
}
