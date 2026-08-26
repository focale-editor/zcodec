part of 'package:zcodec/src/zip.dart';

/// Smallest volume accepted by [ZipEncoder.convertToVolumes].
///
/// Every header must fit inside a single volume, so a volume has to be
/// comfortably larger than the biggest record a ZIP file can contain.
const int _minimumVolumeSize = 65536;

/// Identifies one byte position within split ZIP volumes.
final class _VolumePosition {
  /// Zero-based disk number.
  final int disk;

  /// Byte offset relative to the start of [disk].
  final int offset;

  /// Creates a split-volume position.
  const _VolumePosition({required this.disk, required this.offset});
}

/// Splits records and data across fixed-capacity memory volumes.
final class _VolumeWriter {
  /// Maximum number of bytes in each non-final volume.
  final int volumeSize;

  /// Mutable output buffers in disk order.
  final List<BytesBuilder> _volumes = <BytesBuilder>[BytesBuilder(copy: false)];

  /// Total emitted bytes across every volume.
  int totalLength = 0;

  /// Creates a writer and emits the standard split-archive marker.
  _VolumeWriter(this.volumeSize) {
    writeData(const <int>[0x50, 0x4b, 0x07, 0x08]);
  }

  /// Current disk and relative byte offset.
  _VolumePosition get position => _VolumePosition(disk: _volumes.length - 1, offset: _volumes.last.length);

  /// Ensures a complete [length]-byte record fits on the current disk.
  void ensureRecordSpace(int length) {
    if (length > volumeSize) {
      throw ZCodecException('A $length-byte ZIP record exceeds the $volumeSize-byte volume size');
    }
    if (_volumes.last.length + length > volumeSize) {
      _volumes.add(BytesBuilder(copy: false));
    }
  }

  /// Writes one indivisible header [record] and returns its start position.
  _VolumePosition writeRecord(List<int> record) {
    ensureRecordSpace(record.length);
    final _VolumePosition start = position;
    _volumes.last.add(record);
    totalLength += record.length;
    return start;
  }

  /// Writes splittable file [data] across as many volumes as necessary.
  void writeData(List<int> data) {
    int offset = 0;
    while (offset < data.length) {
      if (_volumes.last.length == volumeSize) {
        _volumes.add(BytesBuilder(copy: false));
      }
      final int count = (data.length - offset).clamp(0, volumeSize - _volumes.last.length);
      _volumes.last.add(Uint8List.sublistView(asBytes(data), offset, offset + count));
      totalLength += count;
      offset += count;
    }
  }

  /// Returns every completed disk without changing their order.
  List<Uint8List> takeVolumes() => <Uint8List>[for (final BytesBuilder volume in _volumes) volume.takeBytes()];
}

/// Encodes [archive] into physically separated ZIP volumes.
List<Uint8List> _encodeSplitArchive(
  ZipArchive archive, {
  required int volumeSize,
  required int level,
  required ZipPasswordProvider? passwordProvider,
  required ZipRandomBytes randomBytes,
  required bool forceZip64,
}) {
  validateCompressionLevel(level);
  final _VolumeWriter output = _VolumeWriter(volumeSize);
  final List<_EncodedEntry> encodedEntries = <_EncodedEntry>[];
  for (final ZipEntry entry in archive.entries) {
    _validateEntryName(entry.name);
    final Uint8List name = _encodeEntryText(entry.name, label: 'name');
    final Uint8List comment = _encodeEntryText(entry.comment, label: 'comment');
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
      randomBytes: randomBytes,
    );
    final bool sizeZip64 = forceZip64 || data.length >= 0xffffffff || encrypted.bytes.length >= 0xffffffff;
    final Uint8List localZip64Extra = sizeZip64 ? _zip64LocalExtra(uncompressedSize: data.length, compressedSize: encrypted.bytes.length) : Uint8List(0);
    final Uint8List localExtra = joinBytes(encrypted.extra, localZip64Extra);
    final ({int date, int time}) timestamp = _encodeDosTimestamp(entry.modified);
    final ByteWriter localHeader = ByteWriter()
      ..writeUint32(0x04034b50)
      ..writeUint16(sizeZip64 ? 45 : 20)
      ..writeUint16(encrypted.flags)
      ..writeUint16(encrypted.headerMethod)
      ..writeUint16(timestamp.time)
      ..writeUint16(timestamp.date)
      ..writeUint32(encrypted.headerChecksum)
      ..writeUint32(sizeZip64 ? 0xffffffff : encrypted.bytes.length)
      ..writeUint32(sizeZip64 ? 0xffffffff : data.length)
      ..writeUint16(name.length)
      ..writeUint16(localExtra.length)
      ..writeBytes(name)
      ..writeBytes(localExtra);
    final _VolumePosition localPosition = output.writeRecord(localHeader.takeBytes());
    final bool zip64 = sizeZip64 || localPosition.disk >= 0xffff || localPosition.offset >= 0xffffffff;
    final Uint8List centralZip64Extra = zip64
        ? _zip64CentralExtra(
            uncompressedSize: data.length,
            compressedSize: encrypted.bytes.length,
            localHeaderOffset: localPosition.offset,
            diskStart: localPosition.disk,
          )
        : Uint8List(0);
    encodedEntries.add(
      _EncodedEntry(
        entry: entry,
        name: name,
        comment: comment,
        compressed: encrypted.bytes,
        uncompressedSize: data.length,
        localHeaderOffset: localPosition.offset,
        diskStart: localPosition.disk,
        method: encrypted.headerMethod,
        flags: encrypted.flags,
        extra: localExtra,
        centralExtra: joinBytes(encrypted.extra, centralZip64Extra),
        zip64: zip64,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        checksum: checksum,
        headerChecksum: encrypted.headerChecksum,
      ),
    );
    output.writeData(encrypted.bytes);
  }

  final int centralLengthStart = output.totalLength;
  _VolumePosition? centralStart;
  final Map<int, int> entriesByCentralDisk = <int, int>{};
  for (final _EncodedEntry encoded in encodedEntries) {
    final ByteWriter centralHeader = ByteWriter()
      ..writeUint32(0x02014b50)
      ..writeUint16(encoded.zip64 ? 45 : 20)
      ..writeUint16(encoded.zip64 ? 45 : 20)
      ..writeUint16(encoded.flags)
      ..writeUint16(encoded.method)
      ..writeUint16(encoded.dosTime)
      ..writeUint16(encoded.dosDate)
      ..writeUint32(encoded.headerChecksum)
      ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.compressed.length)
      ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.uncompressedSize)
      ..writeUint16(encoded.name.length)
      ..writeUint16(encoded.centralExtra.length)
      ..writeUint16(encoded.comment.length)
      ..writeUint16(encoded.zip64 ? 0xffff : encoded.diskStart)
      ..writeUint16(0)
      ..writeUint32(encoded.entry.isDirectory ? 0x10 : 0)
      ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.localHeaderOffset)
      ..writeBytes(encoded.name)
      ..writeBytes(encoded.centralExtra)
      ..writeBytes(encoded.comment);
    final _VolumePosition position = output.writeRecord(centralHeader.takeBytes());
    centralStart ??= position;
    entriesByCentralDisk.update(position.disk, (count) => count + 1, ifAbsent: () => 1);
  }
  centralStart ??= output.position;
  final int centralSize = output.totalLength - centralLengthStart;
  final Uint8List archiveComment = _encodeEntryText(archive.comment, label: 'archive comment');
  final bool zip64Archive =
      forceZip64 ||
      encodedEntries.any((entry) => entry.zip64) ||
      encodedEntries.length >= 0xffff ||
      centralSize >= 0xffffffff ||
      centralStart.offset >= 0xffffffff ||
      centralStart.disk >= 0xffff ||
      output.position.disk >= 0xffff;

  _VolumePosition? zip64EndPosition;
  if (zip64Archive) {
    output.ensureRecordSpace(56);
    zip64EndPosition = output.position;
    output.writeRecord(
      (ByteWriter()
            ..writeUint32(0x06064b50)
            ..writeUint64(44)
            ..writeUint16(45)
            ..writeUint16(45)
            ..writeUint32(zip64EndPosition.disk)
            ..writeUint32(centralStart.disk)
            ..writeUint64(entriesByCentralDisk[zip64EndPosition.disk] ?? 0)
            ..writeUint64(encodedEntries.length)
            ..writeUint64(centralSize)
            ..writeUint64(centralStart.offset))
          .takeBytes(),
    );
  }

  final int tailLength = (zip64Archive ? 20 : 0) + 22 + archiveComment.length;
  output.ensureRecordSpace(tailLength);
  final int endDisk = output.position.disk;
  if (zip64Archive) {
    output.writeRecord(
      (ByteWriter()
            ..writeUint32(0x07064b50)
            ..writeUint32(zip64EndPosition!.disk)
            ..writeUint64(zip64EndPosition.offset)
            ..writeUint32(endDisk + 1))
          .takeBytes(),
    );
  }
  output.writeRecord(
    (ByteWriter()
          ..writeUint32(0x06054b50)
          ..writeUint16(zip64Archive ? 0xffff : endDisk)
          ..writeUint16(zip64Archive ? 0xffff : centralStart.disk)
          ..writeUint16(zip64Archive ? 0xffff : (entriesByCentralDisk[endDisk] ?? 0))
          ..writeUint16(zip64Archive ? 0xffff : encodedEntries.length)
          ..writeUint32(zip64Archive ? 0xffffffff : centralSize)
          ..writeUint32(zip64Archive ? 0xffffffff : centralStart.offset)
          ..writeUint16(archiveComment.length)
          ..writeBytes(archiveComment))
        .takeBytes(),
  );
  return output.takeVolumes();
}
