part of 'package:zcodec/src/zip.dart';

/// Parses ZIP central directories and lazily inflates their entries.
final class ZipDecoder {
  /// Resource limits applied before any entry is decompressed.
  final ZipLimits limits;

  /// Password lookup used by lazily decrypted entries.
  final ZipPasswordProvider? passwordProvider;

  /// Creates a decoder using [limits] for untrusted archives.
  const ZipDecoder({this.limits = const ZipLimits(), this.passwordProvider});

  /// Decodes [input] while retaining one shared copy for lazy entry access.
  ZipArchive decode(List<int> input) {
    final Uint8List bytes = input is Uint8List ? input : Uint8List.fromList(input);
    try {
      return _decode(bytes, const <int>[0]);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid ZIP archive: $error');
    }
  }

  /// Decodes ordered split or spanned ZIP [volumes].
  ///
  /// The first item is disk zero and the final item contains the end record.
  ZipArchive decodeVolumes(List<List<int>> volumes) {
    if (volumes.isEmpty) {
      throw ArgumentError.value(volumes, 'volumes', 'At least one ZIP volume is required');
    }
    final List<int> starts = <int>[];
    final BytesBuilder combined = BytesBuilder(copy: false);
    for (final List<int> volume in volumes) {
      starts.add(combined.length);
      combined.add(volume);
    }
    try {
      return _decode(combined.takeBytes(), starts);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid multi-disk ZIP archive: $error');
    }
  }

  /// Parses a validated byte buffer into lazy entries.
  ZipArchive _decode(Uint8List bytes, List<int> volumeStarts) {
    final int endOffset = _findEndOfCentralDirectory(bytes);
    final ByteReader end = ByteReader(bytes, offset: endOffset + 4);
    int disk = end.readUint16();
    int centralDisk = end.readUint16();
    int entriesOnDisk = end.readUint16();
    int entryCount = end.readUint16();
    int centralSize = end.readUint32();
    int centralOffset = end.readUint32();
    final int commentLength = end.readUint16();
    final String archiveComment = _decodeArchiveComment(end.readBytes(commentLength));
    if (end.offset != bytes.length) {
      throw const ZCodecException('Unexpected bytes after the ZIP end record');
    }
    final bool hasZip64End = disk == 0xffff || centralDisk == 0xffff || entriesOnDisk == 0xffff || entryCount == 0xffff || centralSize == 0xffffffff || centralOffset == 0xffffffff;
    if (hasZip64End) {
      if (endOffset < 20) {
        throw const ZCodecException('ZIP64 end locator is missing');
      }
      final ByteReader locator = ByteReader(bytes, offset: endOffset - 20);
      if (locator.readUint32() != 0x07064b50) {
        throw const ZCodecException('ZIP64 end locator is missing');
      }
      final int zip64Disk = locator.readUint32();
      final int zip64Offset = locator.readUint64();
      final int diskCount = locator.readUint32();
      if (zip64Disk >= volumeStarts.length || diskCount != volumeStarts.length) {
        throw const ZCodecException('ZIP64 locator does not match the supplied volumes');
      }
      final ByteReader zip64End = ByteReader(bytes, offset: volumeStarts[zip64Disk] + zip64Offset);
      if (zip64End.readUint32() != 0x06064b50 || zip64End.readUint64() < 44) {
        throw const ZCodecException('Invalid ZIP64 end record');
      }
      zip64End.skip(4);
      disk = zip64End.readUint32();
      centralDisk = zip64End.readUint32();
      entriesOnDisk = zip64End.readUint64();
      entryCount = zip64End.readUint64();
      centralSize = zip64End.readUint64();
      centralOffset = zip64End.readUint64();
    }
    if (disk != volumeStarts.length - 1 || centralDisk >= volumeStarts.length || (volumeStarts.length == 1 && entriesOnDisk != entryCount)) {
      throw const ZCodecException('ZIP end record does not match the supplied volumes');
    }
    if (entryCount > limits.maxEntries) {
      throw ZCodecException('ZIP archive exceeds the ${limits.maxEntries}-entry limit');
    }
    final int absoluteCentralOffset = volumeStarts[centralDisk] + centralOffset;
    if (absoluteCentralOffset > endOffset || centralSize > endOffset - absoluteCentralOffset) {
      throw const ZCodecException('Invalid ZIP central-directory bounds');
    }
    final ByteReader central = ByteReader(bytes, offset: absoluteCentralOffset);
    final List<ZipEntry> entries = <ZipEntry>[];
    int totalSize = 0;
    for (int index = 0; index < entryCount; index++) {
      if (central.readUint32() != 0x02014b50) {
        throw const ZCodecException('Invalid ZIP central-directory entry');
      }
      central.skip(4);
      final int flags = central.readUint16();
      final int method = central.readUint16();
      final int dosTime = central.readUint16();
      final int dosDate = central.readUint16();
      final int checksum = central.readUint32();
      int compressedSize = central.readUint32();
      int uncompressedSize = central.readUint32();
      final int nameLength = central.readUint16();
      final int extraLength = central.readUint16();
      final int entryCommentLength = central.readUint16();
      int startDisk = central.readUint16();
      central.skip(6);
      int localOffset = central.readUint32();
      final Uint8List nameBytes = central.readBytes(nameLength);
      final Uint8List extraBytes = central.readBytes(extraLength);
      final Uint8List commentBytes = central.readBytes(entryCommentLength);
      final _ParsedExtraFields extra = _parseExtraFields(extraBytes);
      if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff || localOffset == 0xffffffff || startDisk == 0xffff) {
        final Uint8List? zip64Bytes = extra.zip64;
        if (zip64Bytes == null) {
          throw const ZCodecException('ZIP64 entry is missing its 0x0001 extra field');
        }
        final ByteReader zip64 = ByteReader(zip64Bytes);
        if (uncompressedSize == 0xffffffff) {
          uncompressedSize = zip64.readUint64();
        }
        if (compressedSize == 0xffffffff) {
          compressedSize = zip64.readUint64();
        }
        if (localOffset == 0xffffffff) {
          localOffset = zip64.readUint64();
        }
        if (startDisk == 0xffff) {
          startDisk = zip64.readUint32();
        }
      }
      if (startDisk != 0) {
        if (startDisk >= volumeStarts.length) {
          throw const ZCodecException('ZIP entry starts on a missing volume');
        }
      }
      if ((flags & 0x0040) != 0) {
        throw const ZCodecException('PKWARE Strong Encryption requires proprietary technology and is not supported');
      }
      late final ZipEncryption encryption;
      late final int actualMethod;
      late final bool verifyChecksum;
      if ((flags & 0x0001) == 0) {
        if (method == 99) {
          throw const ZCodecException('WinZip AES method is missing the encryption flag');
        }
        encryption = ZipEncryption.none;
        actualMethod = method;
        verifyChecksum = true;
      } else if (method == 99) {
        final _AesExtra? aes = extra.aes;
        if (aes == null) {
          throw const ZCodecException('WinZip AES entry is missing its 0x9901 extra field');
        }
        encryption = switch (aes.strength) {
          1 => ZipEncryption.aes128,
          2 => ZipEncryption.aes192,
          3 => ZipEncryption.aes256,
          _ => throw const ZCodecException('Invalid WinZip AES strength'),
        };
        actualMethod = aes.actualMethod;
        verifyChecksum = aes.version == 1;
      } else {
        encryption = ZipEncryption.zipCrypto;
        actualMethod = method;
        verifyChecksum = true;
      }
      final ZipCompression compression = switch (actualMethod) {
        0 => ZipCompression.store,
        8 => ZipCompression.deflate,
        _ => throw ZCodecException('Unsupported ZIP compression method $actualMethod'),
      };
      if (compression == ZipCompression.store && encryption == ZipEncryption.none && compressedSize != uncompressedSize) {
        throw const ZCodecException('Stored ZIP entry has different compressed and uncompressed sizes');
      }
      if (uncompressedSize > limits.maxEntryBytes) {
        throw ZCodecException('ZIP entry exceeds the ${limits.maxEntryBytes}-byte limit');
      }
      if (uncompressedSize > limits.maxTotalBytes - totalSize) {
        throw ZCodecException('ZIP archive exceeds the ${limits.maxTotalBytes}-byte expanded-size limit');
      }
      totalSize += uncompressedSize;
      final bool utf8Encoded = (flags & 0x0800) != 0;
      final String name = _decodeText(nameBytes, utf8Encoded: utf8Encoded);
      _validateEntryName(name);
      final int absoluteLocalOffset = volumeStarts[startDisk] + localOffset;
      final int dataOffset = _readLocalDataOffset(bytes, absoluteLocalOffset, flags, method);
      if (dataOffset > absoluteCentralOffset || compressedSize > absoluteCentralOffset - dataOffset) {
        throw ZCodecException('ZIP entry "$name" has invalid data bounds');
      }
      entries.add(
        ZipEntry._lazy(
          name: name,
          compression: compression,
          encryption: encryption,
          modified: _decodeDosTimestamp(dosDate, dosTime),
          comment: _decodeText(commentBytes, utf8Encoded: utf8Encoded),
          checksum: checksum,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          sourceArchive: bytes,
          dataOffset: dataOffset,
          maximumOutputBytes: uncompressedSize,
          passwordProvider: passwordProvider,
          passwordCheckByte: (flags & 0x0008) != 0 ? (dosTime >>> 8) & 0xff : (checksum >>> 24) & 0xff,
          verifyChecksum: verifyChecksum,
        ),
      );
    }
    if (central.offset != absoluteCentralOffset + centralSize) {
      throw const ZCodecException('ZIP central-directory size does not match its entries');
    }
    return ZipArchive(entries: entries, comment: archiveComment, volumeCount: volumeStarts.length);
  }
}

/// Holds the encoded form and metadata of an entry during serialization.
