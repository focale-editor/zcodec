part of 'package:zcodec/src/zip.dart';

/// Selects how a ZIP entry is represented.
enum ZipCompression {
  /// Stores bytes verbatim, which is appropriate for PNG and other compressed formats.
  store,

  /// Compresses bytes as a raw DEFLATE stream.
  deflate,
}

/// Selects per-entry ZIP password encryption.
enum ZipEncryption {
  /// Leaves the entry unencrypted.
  none,

  /// Uses the widely supported but cryptographically weak ZipCrypto format.
  zipCrypto,

  /// Uses WinZip AES AE-2 with a 128-bit key.
  aes128,

  /// Uses WinZip AES AE-2 with a 192-bit key.
  aes192,

  /// Uses WinZip AES AE-2 with a 256-bit key.
  aes256,
}

/// Supplies a password for an entry name, or `null` when none is available.
typedef ZipPasswordProvider = String? Function(String entryName);

/// Supplies cryptographically suitable random bytes for encryption headers.
typedef ZipRandomBytes = Uint8List Function(int length);

/// Bounds resource use while parsing an untrusted ZIP archive.
final class ZipLimits {
  /// Maximum number of entries accepted from the central directory.
  final int maxEntries;

  /// Maximum uncompressed size accepted for any individual entry.
  final int maxEntryBytes;

  /// Maximum sum of all declared uncompressed entry sizes.
  final int maxTotalBytes;

  /// Creates archive limits suitable for ordinary application documents.
  const ZipLimits({
    this.maxEntries = 10000,
    this.maxEntryBytes = 512 * 1024 * 1024,
    this.maxTotalBytes = 1024 * 1024 * 1024,
  }) : assert(maxEntries >= 0, 'maxEntries must not be negative'),
       assert(maxEntryBytes >= 0, 'maxEntryBytes must not be negative'),
       assert(maxTotalBytes >= 0, 'maxTotalBytes must not be negative');
}

/// Represents one file or directory in a ZIP archive.
final class ZipEntry {
  /// Entry path, using forward slashes as separators.
  final String name;

  /// Compression method used for this entry.
  final ZipCompression compression;

  /// Password encryption applied to this entry.
  final ZipEncryption encryption;

  /// Last modification time stored with DOS timestamp precision.
  final DateTime modified;

  /// Optional per-entry comment.
  final String comment;

  /// CRC-32 of the uncompressed bytes.
  final int checksum;

  /// Number of compressed bytes stored in the archive.
  final int compressedSize;

  /// Number of bytes produced after decompression.
  final int uncompressedSize;

  /// Materialized bytes for a new or decoded entry.
  Uint8List? _decodedData;

  /// Complete source archive retained for lazy entry decoding.
  final Uint8List? _sourceArchive;

  /// Offset of this entry's compressed bytes in [_sourceArchive].
  final int _dataOffset;

  /// Maximum output allowed when lazily inflating this entry.
  final int _maximumOutputBytes;

  /// Password lookup retained for lazy decryption.
  final ZipPasswordProvider? _passwordProvider;

  /// Byte used to validate a traditional encryption password.
  final int _passwordCheckByte;

  /// Whether the CRC field must be checked after extraction.
  final bool _verifyChecksum;

  /// Creates an entry backed by uncompressed [data].
  ZipEntry({
    required this.name,
    required List<int> data,
    this.compression = ZipCompression.deflate,
    this.encryption = ZipEncryption.none,
    DateTime? modified,
    this.comment = '',
  }) : modified = modified ?? DateTime.now(),
       checksum = crc32(data),
       compressedSize = data.length,
       uncompressedSize = data.length,
       _decodedData = Uint8List.fromList(data),
       _sourceArchive = null,
       _dataOffset = 0,
       _maximumOutputBytes = data.length,
       _passwordProvider = null,
       _passwordCheckByte = 0,
       _verifyChecksum = true {
    _validateEntryName(name);
  }

  /// Creates an entry backed by a compressed slice of [sourceArchive].
  ZipEntry._lazy({
    required this.name,
    required this.compression,
    required this.encryption,
    required this.modified,
    required this.comment,
    required this.checksum,
    required this.compressedSize,
    required this.uncompressedSize,
    required this._sourceArchive,
    required this._dataOffset,
    required this._maximumOutputBytes,
    required this._passwordProvider,
    required this._passwordCheckByte,
    required this._verifyChecksum,
  }) : _decodedData = null,
       assert(_dataOffset >= 0, 'dataOffset must not be negative'),
       assert(_maximumOutputBytes >= 0, 'maximumOutputBytes must not be negative');

  /// Whether this entry denotes a directory.
  bool get isDirectory => name.endsWith('/');

  /// Whether [name] is relative and cannot escape an extraction root.
  bool get hasSafePath {
    if (name.startsWith('/') || name.startsWith(r'\')) {
      return false;
    }
    final List<String> parts = name.replaceAll(r'\', '/').split('/');
    return !parts.contains('..') && (parts.isEmpty || !parts.first.contains(':'));
  }

  /// Returns the uncompressed entry data, inflating and checking it on demand.
  Uint8List get data {
    final Uint8List? materialized = _decodedData;
    if (materialized != null) {
      return materialized;
    }
    final Uint8List archive = _sourceArchive!;
    final Uint8List payload = Uint8List.sublistView(archive, _dataOffset, _dataOffset + compressedSize);
    final Uint8List compressed = _decrypt(payload);
    final Uint8List decoded = switch (compression) {
      ZipCompression.store => Uint8List.fromList(compressed),
      ZipCompression.deflate => const DeflateCodec().decode(compressed, maxOutputBytes: _maximumOutputBytes),
    };
    if (decoded.length != uncompressedSize) {
      throw ZCodecException('ZIP entry "$name" has ${decoded.length} bytes; expected $uncompressedSize');
    }
    final int actualChecksum = crc32(decoded);
    if (_verifyChecksum && actualChecksum != checksum) {
      throw ZCodecException('ZIP entry "$name" has an invalid CRC-32 checksum');
    }
    _decodedData = decoded;
    return decoded;
  }

  /// Releases lazily decoded data while retaining access to its archive slice.
  ///
  /// Entries created directly keep their data because they have no compressed
  /// source from which it could be reconstructed.
  void release() {
    if (_sourceArchive != null) {
      _decodedData = null;
    }
  }

  /// Decrypts [payload] according to this entry's encryption metadata.
  Uint8List _decrypt(Uint8List payload) {
    if (encryption == ZipEncryption.none) {
      return payload;
    }
    final String? password = _passwordProvider?.call(name);
    if (password == null) {
      throw ZCodecException('ZIP entry "$name" requires a password');
    }
    if (encryption == ZipEncryption.zipCrypto) {
      if (payload.length < 12) {
        throw ZCodecException('ZIP entry "$name" has a truncated encryption header');
      }
      final ZipCryptoCipher cipher = ZipCryptoCipher(password);
      final Uint8List header = cipher.decrypt(Uint8List.sublistView(payload, 0, 12));
      if (header[11] != _passwordCheckByte) {
        throw ZCodecException('Incorrect password for ZIP entry "$name"');
      }
      return cipher.decrypt(Uint8List.sublistView(payload, 12));
    }
    return decryptWinZipAes(payload: payload, password: password, keyLength: _aesKeyLength(encryption));
  }
}

/// Contains the entries and archive comment of a ZIP file.
final class ZipArchive {
  /// Entries in central-directory order.
  final List<ZipEntry> entries;

  /// Optional archive-level comment.
  final String comment;

  /// Number of physical ZIP volumes represented by this archive.
  final int volumeCount;

  /// Creates an archive from [entries].
  ZipArchive({Iterable<ZipEntry> entries = const <ZipEntry>[], this.comment = '', this.volumeCount = 1})
    : assert(volumeCount > 0, 'volumeCount must be positive'),
      entries = List<ZipEntry>.unmodifiable(entries);

  /// Finds the first entry whose path equals [name].
  ZipEntry? find(String name) {
    for (final ZipEntry entry in entries) {
      if (entry.name == name) {
        return entry;
      }
    }
    return null;
  }

  /// Releases materialized data for all lazily decoded entries.
  void release() {
    for (final ZipEntry entry in entries) {
      entry.release();
    }
  }
}
