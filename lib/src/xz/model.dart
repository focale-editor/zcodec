part of 'package:zcodec/src/xz.dart';

/// Integrity algorithms defined by the XZ container.
enum XzCheck {
  /// No payload checksum; structural CRCs are still verified.
  none(0, 0),

  /// IEEE CRC-32.
  crc32(1, 4),

  /// CRC-64/XZ, represented portably as two unsigned words.
  crc64(4, 8),

  /// SHA-256.
  sha256(10, 32);

  /// Encoded XZ check identifier.
  final int id;

  /// Check field length in bytes.
  final int size;

  /// Creates a standard integrity algorithm.
  const XzCheck(this.id, this.size);
}
