part of 'package:zcodec/src/zip.dart';

/// Holds the encoded form and metadata of an entry during serialization.
final class _EncodedEntry {
  /// Original entry.
  final ZipEntry entry;

  /// UTF-8 entry name.
  final Uint8List name;

  /// UTF-8 entry comment.
  final Uint8List comment;

  /// Number of bytes already written to the entry's data area.
  final int compressedSize;

  /// Number of bytes the entry expands to.
  final int uncompressedSize;

  /// Byte offset of the corresponding local header.
  final int localHeaderOffset;

  /// Disk containing the corresponding local header.
  final int diskStart;

  /// Numeric ZIP compression method.
  final int method;

  /// General-purpose ZIP flags.
  final int flags;

  /// Extra fields shared by the local and central headers.
  final Uint8List extra;

  /// Extra fields written only to the central header.
  final Uint8List centralExtra;

  /// Whether this entry uses ZIP64 sentinel fields.
  final bool zip64;

  /// DOS date field.
  final int dosDate;

  /// DOS time field.
  final int dosTime;

  /// CRC-32 of the uncompressed entry bytes at serialization time.
  final int checksum;

  /// CRC value written to ZIP headers, which is zero for WinZip AE-2.
  final int headerChecksum;

  /// Creates serialization metadata for one entry.
  const _EncodedEntry({
    required this.entry,
    required this.name,
    required this.comment,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.diskStart,
    required this.method,
    required this.flags,
    required this.extra,
    required this.centralExtra,
    required this.zip64,
    required this.dosDate,
    required this.dosTime,
    required this.checksum,
    required this.headerChecksum,
  });
}

/// A payload compressed and encrypted once, before its physical placement.
final class _PreparedZipEntry {
  /// Original entry metadata.
  final ZipEntry entry;

  /// Encoded file name.
  final Uint8List name;

  /// Encoded entry comment.
  final Uint8List comment;

  /// Prepared bytes and encryption-specific metadata.
  final _EncryptedPayload payload;

  /// Number of uncompressed bytes.
  final int uncompressedSize;

  /// CRC at preparation time.
  final int checksum;

  /// Encoded modification time.
  final ({int date, int time}) timestamp;

  /// Creates a prepared payload.
  const _PreparedZipEntry({required this.entry, required this.name, required this.comment, required this.payload, required this.uncompressedSize, required this.checksum, required this.timestamp});
}

/// Holds recognized ZIP extra fields from one header.
final class _ParsedExtraFields {
  /// WinZip AES metadata, when present.
  final _AesExtra? aes;

  /// Raw ZIP64 values in their specification-defined order.
  final Uint8List? zip64;

  /// Creates a parsed extra-field collection.
  const _ParsedExtraFields({required this.aes, required this.zip64});
}

/// Describes the WinZip AES 0x9901 extra field.
final class _AesExtra {
  /// AE format version, either 1 or 2.
  final int version;

  /// AES key-strength code from 1 through 3.
  final int strength;

  /// Actual compression method hidden behind method 99.
  final int actualMethod;

  /// Creates validated WinZip AES metadata.
  const _AesExtra({required this.version, required this.strength, required this.actualMethod});
}

/// Stores central-directory metadata for an incrementally written entry.
final class _WrittenZipEntry {
  /// UTF-8 entry name.
  final Uint8List name;

  /// UTF-8 entry comment.
  final Uint8List comment;

  /// CRC-32 of the uncompressed bytes.
  final int checksum;

  /// Number of bytes stored in the local entry.
  final int compressedSize;

  /// Number of bytes represented by the entry.
  final int uncompressedSize;

  /// Byte offset of the local-file header.
  final int localHeaderOffset;

  /// Numeric ZIP compression method.
  final int method;

  /// General-purpose ZIP flags.
  final int flags;

  /// Extra fields written to the central-directory entry.
  final Uint8List centralExtra;

  /// Whether the central entry uses ZIP64 sentinel values.
  final bool zip64;

  /// DOS date field.
  final int dosDate;

  /// DOS time field.
  final int dosTime;

  /// Whether the entry name denotes a directory.
  final bool isDirectory;

  /// Creates central-directory metadata for a completed entry.
  const _WrittenZipEntry({
    required this.name,
    required this.comment,
    required this.checksum,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.method,
    required this.flags,
    required this.centralExtra,
    required this.zip64,
    required this.dosDate,
    required this.dosTime,
    required this.isDirectory,
  });
}
