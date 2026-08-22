part of 'package:zcodec/src/zip.dart';

final class _EncodedEntry {
  /// Original entry.
  final ZipEntry entry;

  /// UTF-8 entry name.
  final Uint8List name;

  /// UTF-8 entry comment.
  final Uint8List comment;

  /// Stored or DEFLATE-compressed entry bytes.
  final Uint8List compressed;

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
    required this.compressed,
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

/// Describes a compressed payload after optional password encryption.
final class _EncryptedPayload {
  /// Bytes stored in the ZIP data area.
  final Uint8List bytes;

  /// Compression method written in headers.
  final int headerMethod;

  /// General-purpose ZIP flags.
  final int flags;

  /// Encryption-specific extra fields.
  final Uint8List extra;

  /// CRC value written to headers.
  final int headerChecksum;

  /// Creates a prepared ZIP payload.
  const _EncryptedPayload({
    required this.bytes,
    required this.headerMethod,
    required this.flags,
    required this.extra,
    required this.headerChecksum,
  });
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
      _volumes.last.add(data.sublist(offset, offset + count));
      totalLength += count;
      offset += count;
    }
  }

  /// Returns every completed disk without changing their order.
  List<Uint8List> takeVolumes() => <Uint8List>[for (final BytesBuilder volume in _volumes) volume.takeBytes()];
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

/// Locates the final ZIP end record while accounting for a variable comment.
int _findEndOfCentralDirectory(Uint8List bytes) {
  final int minimum = (bytes.length - 22 - 0xffff).clamp(0, bytes.length);
  for (int offset = bytes.length - 22; offset >= minimum; offset--) {
    if (bytes[offset] == 0x50 && bytes[offset + 1] == 0x4b && bytes[offset + 2] == 0x05 && bytes[offset + 3] == 0x06) {
      final int commentLength = bytes[offset + 20] | (bytes[offset + 21] << 8);
      if (offset + 22 + commentLength == bytes.length) {
        return offset;
      }
    }
  }
  throw const ZCodecException('ZIP end-of-central-directory record not found');
}

/// Returns the first byte of local entry data and validates key metadata.
int _readLocalDataOffset(Uint8List bytes, int offset, int centralFlags, int centralMethod) {
  final ByteReader local = ByteReader(bytes, offset: offset);
  if (local.readUint32() != 0x04034b50) {
    throw const ZCodecException('Invalid ZIP local-file header');
  }
  local.skip(2);
  final int flags = local.readUint16();
  final int method = local.readUint16();
  local.skip(16);
  final int nameLength = local.readUint16();
  final int extraLength = local.readUint16();
  if (flags != centralFlags || method != centralMethod) {
    throw const ZCodecException('ZIP local and central headers disagree');
  }
  local.skip(nameLength + extraLength);
  return local.offset;
}

/// Parses the recognized records from a ZIP extra-field byte sequence.
_ParsedExtraFields _parseExtraFields(Uint8List bytes) {
  final ByteReader input = ByteReader(bytes);
  _AesExtra? aes;
  Uint8List? zip64;
  while (input.remaining != 0) {
    if (input.remaining < 4) {
      throw const ZCodecException('Truncated ZIP extra-field header');
    }
    final int identifier = input.readUint16();
    final int length = input.readUint16();
    final Uint8List data = input.readBytes(length);
    if (identifier == 0x0001) {
      zip64 = data;
    } else if (identifier == 0x9901) {
      if (data.length < 7) {
        throw const ZCodecException('Truncated WinZip AES extra field');
      }
      final ByteReader aesInput = ByteReader(data);
      final int version = aesInput.readUint16();
      final int firstVendorByte = aesInput.readByte();
      final int secondVendorByte = aesInput.readByte();
      final int strength = aesInput.readByte();
      final int actualMethod = aesInput.readUint16();
      if ((version != 1 && version != 2) || firstVendorByte != 0x41 || secondVendorByte != 0x45) {
        throw const ZCodecException('Unsupported WinZip AES extra field');
      }
      aes = _AesExtra(version: version, strength: strength, actualMethod: actualMethod);
    }
  }
  return _ParsedExtraFields(aes: aes, zip64: zip64);
}

/// Encodes a timestamp into DOS date and time fields.
({int date, int time}) _encodeDosTimestamp(DateTime value) {
  final int year = value.year.clamp(1980, 2107);
  final int month = value.month.clamp(1, 12);
  final int day = value.day.clamp(1, 31);
  final int date = ((year - 1980) << 9) | (month << 5) | day;
  final int time = (value.hour.clamp(0, 23) << 11) | (value.minute.clamp(0, 59) << 5) | (value.second.clamp(0, 59) ~/ 2);
  return (date: date, time: time);
}

/// Decodes DOS date and time fields, tolerating zeroed legacy timestamps.
DateTime _decodeDosTimestamp(int date, int time) {
  final int year = ((date >>> 9) & 0x7f) + 1980;
  final int month = ((date >>> 5) & 0x0f).clamp(1, 12);
  final int day = (date & 0x1f).clamp(1, 31);
  final int hour = (time >>> 11) & 0x1f;
  final int minute = (time >>> 5) & 0x3f;
  final int second = (time & 0x1f) * 2;
  return DateTime(year, month, day, hour.clamp(0, 23), minute.clamp(0, 59), second.clamp(0, 59));
}

/// Decodes UTF-8 names or the ASCII-compatible portion of legacy ZIP names.
String _decodeText(Uint8List bytes, {required bool utf8Encoded}) {
  if (utf8Encoded) {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw ZCodecException('Invalid UTF-8 ZIP metadata: $error');
    }
  }
  return latin1.decode(bytes);
}

/// Decodes an archive comment as UTF-8 when possible, then as legacy bytes.
String _decodeArchiveComment(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Rejects names that cannot be represented safely in a ZIP header.
void _validateEntryName(String name) {
  if (name.isEmpty) {
    throw const ZCodecException('ZIP entry names must not be empty');
  }
  if (name.contains('\u0000')) {
    throw const ZCodecException('ZIP entry names must not contain NUL');
  }
}

/// Encodes and bounds one UTF-8 ZIP metadata field.
Uint8List _encodeEntryText(String value, {required String label}) {
  final Uint8List encoded = Uint8List.fromList(utf8.encode(value));
  if (encoded.length > 0xffff) {
    throw ZCodecException('ZIP $label exceeds 65535 bytes');
  }
  return encoded;
}

/// Encrypts one compressed entry and prepares its header metadata.
_EncryptedPayload _encryptPayload({
  required Uint8List compressed,
  required ZipEncryption encryption,
  required String? password,
  required int checksum,
  required int actualMethod,
  required ZipRandomBytes randomBytes,
}) {
  if (encryption == ZipEncryption.none) {
    return _EncryptedPayload(bytes: compressed, headerMethod: actualMethod, flags: 0x0800, extra: Uint8List(0), headerChecksum: checksum);
  }
  if (password == null) {
    throw const ZCodecException('A password provider is required for encrypted ZIP entries');
  }
  if (encryption == ZipEncryption.zipCrypto) {
    final Uint8List header = randomBytes(12);
    if (header.length != 12) {
      throw StateError('The random byte provider returned ${header.length} bytes; expected 12');
    }
    header[11] = (checksum >>> 24) & 0xff;
    final ZipCryptoCipher cipher = ZipCryptoCipher(password);
    return _EncryptedPayload(
      bytes: _joinBytes(cipher.encrypt(header), cipher.encrypt(compressed)),
      headerMethod: actualMethod,
      flags: 0x0801,
      extra: Uint8List(0),
      headerChecksum: checksum,
    );
  }
  final int keyLength = _aesKeyLength(encryption);
  final int strength = keyLength == 16
      ? 1
      : keyLength == 24
      ? 2
      : 3;
  final WinZipAesPayload payload = encryptWinZipAes(
    compressed: compressed,
    password: password,
    keyLength: keyLength,
    randomBytes: randomBytes,
  );
  final ByteWriter extra = ByteWriter()
    ..writeUint16(0x9901)
    ..writeUint16(7)
    ..writeUint16(2)
    ..writeByte(0x41)
    ..writeByte(0x45)
    ..writeByte(strength)
    ..writeUint16(actualMethod);
  return _EncryptedPayload(bytes: payload.bytes, headerMethod: 99, flags: 0x0801, extra: extra.takeBytes(), headerChecksum: 0);
}

/// Returns the AES key length represented by [encryption].
int _aesKeyLength(ZipEncryption encryption) => switch (encryption) {
  ZipEncryption.aes128 => 16,
  ZipEncryption.aes192 => 24,
  ZipEncryption.aes256 => 32,
  ZipEncryption.none || ZipEncryption.zipCrypto => throw StateError('$encryption does not use AES'),
};

/// Generates [length] bytes using the Dart SDK secure random source.
Uint8List _secureRandomBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(<int>[for (int index = 0; index < length; index++) random.nextInt(256)]);
}

/// Concatenates two byte sequences.
Uint8List _joinBytes(List<int> first, List<int> second) => Uint8List(first.length + second.length)
  ..setRange(0, first.length, first)
  ..setRange(first.length, first.length + second.length, second);

/// Builds the mandatory local ZIP64 size extra field.
Uint8List _zip64LocalExtra({required int uncompressedSize, required int compressedSize}) =>
    (ByteWriter()
          ..writeUint16(0x0001)
          ..writeUint16(16)
          ..writeUint64(uncompressedSize)
          ..writeUint64(compressedSize))
        .takeBytes();

/// Builds a central ZIP64 extra field containing all sentinel values.
Uint8List _zip64CentralExtra({required int uncompressedSize, required int compressedSize, required int localHeaderOffset, required int diskStart}) =>
    (ByteWriter()
          ..writeUint16(0x0001)
          ..writeUint16(28)
          ..writeUint64(uncompressedSize)
          ..writeUint64(compressedSize)
          ..writeUint64(localHeaderOffset)
          ..writeUint32(diskStart))
        .takeBytes();

/// Encodes [archive] into physically separated ZIP volumes.
List<Uint8List> _encodeSplitArchive(
  ZipArchive archive, {
  required int volumeSize,
  required int level,
  required ZipPasswordProvider? passwordProvider,
  required ZipRandomBytes randomBytes,
  required bool forceZip64,
}) {
  if (level < 0 || level > 9) {
    throw RangeError.range(level, 0, 9, 'level');
  }
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
      ZipCompression.deflate => ZipEncoder._deflate.encode(data, level: level),
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
    final Uint8List localExtra = _joinBytes(encrypted.extra, localZip64Extra);
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
        localHeaderOffset: localPosition.offset,
        diskStart: localPosition.disk,
        method: encrypted.headerMethod,
        flags: encrypted.flags,
        extra: localExtra,
        centralExtra: _joinBytes(encrypted.extra, centralZip64Extra),
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
      ..writeUint32(encoded.zip64 ? 0xffffffff : encoded.entry.uncompressedSize)
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
