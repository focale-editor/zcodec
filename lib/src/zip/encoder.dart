part of 'package:zcodec/src/zip.dart';

/// Serializes ZIP archives without native compression libraries.
///
/// [passwordProvider] is consulted for encrypted entries. [randomBytes]
/// defaults to a secure SDK source and is exposed primarily for deterministic
/// tests. ZIP64 records are selected automatically, or for every entry when
/// [forceZip64] is true.
final class ZipEncoder extends BinaryEncoder<ZipArchive> {
  /// Compression effort from 0 through 9 for DEFLATE entries.
  final int level;

  /// Password lookup consulted for encrypted entries.
  final ZipPasswordProvider? passwordProvider;

  /// Random-byte source used for encryption headers and salts.
  final ZipRandomBytes? randomBytes;

  /// Whether every entry and end record uses ZIP64.
  final bool forceZip64;

  /// Creates a ZIP encoder.
  const ZipEncoder({
    this.level = defaultCompressionLevel,
    this.passwordProvider,
    this.randomBytes,
    this.forceZip64 = false,
  });

  @override
  Uint8List convert(ZipArchive archive) => _convertPrepared(archive, _prepare(archive));

  /// Compresses each payload only as the serializer requests it.
  Iterable<_PreparedZipEntry> _prepare(ZipArchive archive) sync* {
    validateCompressionLevel(level);
    for (final ZipEntry entry in archive.entries) {
      _validateEntryName(entry.name);
      final Uint8List name = _encodeEntryText(entry.name, label: 'entry name');
      final Uint8List comment = _encodeEntryText(entry.comment, label: 'entry comment');
      final Uint8List data = entry.data;
      final int checksum = crc32(data);
      final Uint8List compressed = switch (entry.compression) {
        ZipCompression.store => data,
        ZipCompression.deflate => DeflateEncoder(level: level).convert(data),
      };
      final int actualMethod = entry.compression == ZipCompression.store ? 0 : 8;
      final _EncryptedPayload encrypted = _encryptPayload(
        compressed: compressed,
        encryption: entry.encryption,
        password: passwordProvider?.call(entry.name),
        checksum: checksum,
        actualMethod: actualMethod,
        randomBytes: randomBytes ?? _secureRandomBytes,
      );
      final ({int date, int time}) timestamp = _encodeDosTimestamp(entry.modified);
      yield _PreparedZipEntry(entry: entry, name: name, comment: comment, payload: encrypted, uncompressedSize: data.length, checksum: checksum, timestamp: timestamp);
    }
  }

  /// Serializes prepared payloads, retaining only central-directory metadata.
  Uint8List _convertPrepared(ZipArchive archive, Iterable<_PreparedZipEntry> prepared) {
    final ByteWriter output = ByteWriter();
    final List<_EncodedEntry> encodedEntries = <_EncodedEntry>[];
    for (final _PreparedZipEntry item in prepared) {
      final ZipEntry entry = item.entry;
      final Uint8List name = item.name;
      final Uint8List comment = item.comment;
      final _EncryptedPayload encrypted = item.payload;
      final ({int date, int time}) timestamp = item.timestamp;
      final bool zip64 = forceZip64 || item.uncompressedSize >= 0xffffffff || encrypted.bytes.length >= 0xffffffff || output.length >= 0xffffffff;
      final Uint8List localZip64Extra = zip64 ? _zip64LocalExtra(uncompressedSize: item.uncompressedSize, compressedSize: encrypted.bytes.length) : Uint8List(0);
      final Uint8List centralZip64Extra = zip64
          ? _zip64CentralExtra(
              uncompressedSize: item.uncompressedSize,
              compressedSize: encrypted.bytes.length,
              localHeaderOffset: output.length,
              diskStart: 0,
            )
          : Uint8List(0);
      final _EncodedEntry encoded = _EncodedEntry(
        entry: entry,
        name: name,
        comment: comment,
        compressedSize: encrypted.bytes.length,
        uncompressedSize: item.uncompressedSize,
        localHeaderOffset: output.length,
        diskStart: 0,
        method: encrypted.headerMethod,
        flags: encrypted.flags,
        extra: joinBytes(encrypted.extra, localZip64Extra),
        centralExtra: joinBytes(encrypted.extra, centralZip64Extra),
        zip64: zip64,
        headerChecksum: encrypted.headerChecksum,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        checksum: item.checksum,
      );
      encodedEntries.add(encoded);
      output
        ..writeUint32(0x04034b50)
        ..writeUint16(zip64 ? 45 : 20)
        ..writeUint16(encrypted.flags)
        ..writeUint16(encrypted.headerMethod)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(encrypted.headerChecksum)
        ..writeUint32(zip64 ? 0xffffffff : encrypted.bytes.length)
        ..writeUint32(zip64 ? 0xffffffff : item.uncompressedSize)
        ..writeUint16(name.length)
        ..writeUint16(encoded.extra.length)
        ..writeBytes(name)
        ..writeBytes(encoded.extra)
        ..writeBytes(encrypted.bytes);
    }

    final int centralDirectoryOffset = output.length;
    for (final _EncodedEntry encoded in encodedEntries) {
      final ZipEntry entry = encoded.entry;
      output
        ..writeUint32(0x02014b50)
        ..writeUint16(encoded.zip64 ? 45 : 20)
        ..writeUint16(encoded.zip64 ? 45 : 20)
        ..writeUint16(encoded.flags)
        ..writeUint16(encoded.method)
        ..writeUint16(encoded.dosTime)
        ..writeUint16(encoded.dosDate)
        ..writeUint32(encoded.headerChecksum)
        ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.compressedSize)
        ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.uncompressedSize)
        ..writeUint16(encoded.name.length)
        ..writeUint16(encoded.centralExtra.length)
        ..writeUint16(encoded.comment.length)
        ..writeUint16(encoded.zip64 ? 0xffff : 0)
        ..writeUint16(0)
        ..writeUint32(entry.isDirectory ? 0x10 : 0)
        ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.localHeaderOffset)
        ..writeBytes(encoded.name)
        ..writeBytes(encoded.centralExtra)
        ..writeBytes(encoded.comment);
    }
    final int centralDirectorySize = output.length - centralDirectoryOffset;
    final Uint8List archiveComment = _encodeEntryText(archive.comment, label: 'archive comment');
    final bool zip64Archive = forceZip64 || encodedEntries.any((entry) => entry.zip64) || encodedEntries.length >= 0xffff || centralDirectorySize >= 0xffffffff || centralDirectoryOffset >= 0xffffffff;
    if (zip64Archive) {
      final int zip64EndOffset = output.length;
      output
        ..writeUint32(0x06064b50)
        ..writeUint64(44)
        ..writeUint16(45)
        ..writeUint16(45)
        ..writeUint32(0)
        ..writeUint32(0)
        ..writeUint64(encodedEntries.length)
        ..writeUint64(encodedEntries.length)
        ..writeUint64(centralDirectorySize)
        ..writeUint64(centralDirectoryOffset)
        ..writeUint32(0x07064b50)
        ..writeUint32(0)
        ..writeUint64(zip64EndOffset)
        ..writeUint32(1);
    }
    output
      ..writeUint32(0x06054b50)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(zip64Archive ? 0xffff : encodedEntries.length)
      ..writeUint16(zip64Archive ? 0xffff : encodedEntries.length)
      ..writeUint32(zip64Archive ? 0xffffffff : centralDirectorySize)
      ..writeUint32(zip64Archive ? 0xffffffff : centralDirectoryOffset)
      ..writeUint16(archiveComment.length)
      ..writeBytes(archiveComment);
    return output.takeBytes();
  }

  /// Encodes [archive] into ordered split ZIP volumes.
  ///
  /// Every non-final volume is at most [volumeSize] bytes and should normally
  /// be named `.z01`, `.z02`, and so on; the final volume uses `.zip`. A single
  /// volume is returned when the whole archive fits.
  List<Uint8List> convertToVolumes(ZipArchive archive, {required int volumeSize}) {
    if (volumeSize < _minimumVolumeSize) {
      throw RangeError.value(volumeSize, 'volumeSize', 'Split ZIP volumes must contain at least $_minimumVolumeSize bytes');
    }
    final List<_PreparedZipEntry> prepared = _prepare(archive).toList();
    if (_singleVolumeSize(archive, prepared) <= volumeSize) {
      return <Uint8List>[_convertPrepared(archive, prepared)];
    }
    return _encodeSplitArchive(
      archive,
      volumeSize: volumeSize,
      prepared: prepared,
      forceZip64: forceZip64,
    );
  }

  /// Computes exact monovolume size without building an intermediate archive.
  int _singleVolumeSize(ZipArchive archive, List<_PreparedZipEntry> prepared) {
    int localSize = 0;
    int centralSize = 0;
    bool hasZip64Entry = forceZip64;
    for (final _PreparedZipEntry item in prepared) {
      final bool zip64 = forceZip64 || item.uncompressedSize >= 0xffffffff || item.payload.bytes.length >= 0xffffffff || localSize >= 0xffffffff;
      hasZip64Entry = hasZip64Entry || zip64;
      localSize += 30 + item.name.length + item.payload.extra.length + (zip64 ? 20 : 0) + item.payload.bytes.length;
      centralSize += 46 + item.name.length + item.comment.length + item.payload.extra.length + (zip64 ? 32 : 0);
    }
    final bool zip64 = hasZip64Entry || prepared.length >= 0xffff || localSize >= 0xffffffff || centralSize >= 0xffffffff;
    return localSize + centralSize + 22 + (zip64 ? 76 : 0) + _encodeEntryText(archive.comment, label: 'archive comment').length;
  }
}
