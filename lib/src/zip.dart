import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/byte_io.dart';
import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/deflate_codec.dart';
import 'package:zcodec/src/exception.dart';

/// Selects how a ZIP entry is represented.
enum ZipCompression {
  /// Stores bytes verbatim, which is appropriate for PNG and other compressed formats.
  store,

  /// Compresses bytes as a raw DEFLATE stream.
  deflate,
}

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

  /// Creates an entry backed by uncompressed [data].
  ZipEntry({
    required this.name,
    required List<int> data,
    this.compression = ZipCompression.deflate,
    DateTime? modified,
    this.comment = '',
  }) : modified = modified ?? DateTime.now(),
       checksum = crc32(data),
       compressedSize = data.length,
       uncompressedSize = data.length,
       _decodedData = Uint8List.fromList(data),
       _sourceArchive = null,
       _dataOffset = 0,
       _maximumOutputBytes = data.length {
    _validateEntryName(name);
  }

  /// Creates an entry backed by a compressed slice of [sourceArchive].
  ZipEntry._lazy({
    required this.name,
    required this.compression,
    required this.modified,
    required this.comment,
    required this.checksum,
    required this.compressedSize,
    required this.uncompressedSize,
    required this._sourceArchive,
    required this._dataOffset,
    required this._maximumOutputBytes,
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
    final Uint8List compressed = Uint8List.sublistView(archive, _dataOffset, _dataOffset + compressedSize);
    final Uint8List decoded = switch (compression) {
      ZipCompression.store => Uint8List.fromList(compressed),
      ZipCompression.deflate => const DeflateCodec().decode(compressed, maxOutputBytes: _maximumOutputBytes),
    };
    if (decoded.length != uncompressedSize) {
      throw ZCodecException('ZIP entry "$name" has ${decoded.length} bytes; expected $uncompressedSize');
    }
    final int actualChecksum = crc32(decoded);
    if (actualChecksum != checksum) {
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
}

/// Contains the entries and archive comment of a ZIP file.
final class ZipArchive {
  /// Entries in central-directory order.
  final List<ZipEntry> entries;

  /// Optional archive-level comment.
  final String comment;

  /// Creates an archive from [entries].
  ZipArchive({Iterable<ZipEntry> entries = const <ZipEntry>[], this.comment = ''}) : entries = List<ZipEntry>.unmodifiable(entries);

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

/// Serializes ZIP archives without native compression libraries.
final class ZipEncoder {
  /// Raw DEFLATE implementation used for compressed entries.
  static const DeflateCodec _deflate = DeflateCodec();

  /// Creates a stateless ZIP encoder.
  const ZipEncoder();

  /// Encodes [archive] using [level] for DEFLATE entries.
  Uint8List encode(ZipArchive archive, {int level = 6}) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    if (archive.entries.length > 0xffff) {
      throw const ZCodecException('ZIP64 is required for more than 65535 entries');
    }
    final ByteWriter output = ByteWriter();
    final List<_EncodedEntry> encodedEntries = <_EncodedEntry>[];
    for (final ZipEntry entry in archive.entries) {
      _validateEntryName(entry.name);
      final Uint8List name = Uint8List.fromList(utf8.encode(entry.name));
      final Uint8List comment = Uint8List.fromList(utf8.encode(entry.comment));
      if (name.length > 0xffff || comment.length > 0xffff) {
        throw ZCodecException('ZIP entry metadata is too long for "${entry.name}"');
      }
      final Uint8List data = entry.data;
      final int checksum = crc32(data);
      final Uint8List compressed = switch (entry.compression) {
        ZipCompression.store => data,
        ZipCompression.deflate => _deflate.encode(data, level: level),
      };
      if (data.length > 0xffffffff || compressed.length > 0xffffffff || output.length > 0xffffffff) {
        throw const ZCodecException('ZIP64 is required for entries or archives larger than 4 GiB');
      }
      final int method = entry.compression == ZipCompression.store ? 0 : 8;
      final ({int date, int time}) timestamp = _encodeDosTimestamp(entry.modified);
      final _EncodedEntry encoded = _EncodedEntry(
        entry: entry,
        name: name,
        comment: comment,
        compressed: compressed,
        localHeaderOffset: output.length,
        method: method,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        checksum: checksum,
      );
      encodedEntries.add(encoded);
      output
        ..writeUint32(0x04034b50)
        ..writeUint16(20)
        ..writeUint16(0x0800)
        ..writeUint16(method)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(checksum)
        ..writeUint32(compressed.length)
        ..writeUint32(data.length)
        ..writeUint16(name.length)
        ..writeUint16(0)
        ..writeBytes(name)
        ..writeBytes(compressed);
    }

    final int centralDirectoryOffset = output.length;
    for (final _EncodedEntry encoded in encodedEntries) {
      final ZipEntry entry = encoded.entry;
      output
        ..writeUint32(0x02014b50)
        ..writeUint16(20)
        ..writeUint16(20)
        ..writeUint16(0x0800)
        ..writeUint16(encoded.method)
        ..writeUint16(encoded.dosTime)
        ..writeUint16(encoded.dosDate)
        ..writeUint32(encoded.checksum)
        ..writeUint32(encoded.compressed.length)
        ..writeUint32(entry.uncompressedSize)
        ..writeUint16(encoded.name.length)
        ..writeUint16(0)
        ..writeUint16(encoded.comment.length)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint32(entry.isDirectory ? 0x10 : 0)
        ..writeUint32(encoded.localHeaderOffset)
        ..writeBytes(encoded.name)
        ..writeBytes(encoded.comment);
    }
    final int centralDirectorySize = output.length - centralDirectoryOffset;
    final Uint8List archiveComment = Uint8List.fromList(utf8.encode(archive.comment));
    if (archiveComment.length > 0xffff) {
      throw const ZCodecException('ZIP archive comment exceeds 65535 bytes');
    }
    output
      ..writeUint32(0x06054b50)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(encodedEntries.length)
      ..writeUint16(encodedEntries.length)
      ..writeUint32(centralDirectorySize)
      ..writeUint32(centralDirectoryOffset)
      ..writeUint16(archiveComment.length)
      ..writeBytes(archiveComment);
    return output.takeBytes();
  }
}

/// Writes ZIP entries incrementally to an arbitrary Dart byte sink.
///
/// Buffered entries may use DEFLATE. [addStoredStream] copies large,
/// already-compressed assets without retaining them in memory.
final class ZipStreamWriter {
  /// Raw DEFLATE implementation used by buffered compressed entries.
  static const DeflateCodec _deflate = DeflateCodec();

  /// Destination receiving serialized ZIP chunks.
  final Sink<List<int>> _output;

  /// Central-directory metadata accumulated for completed entries.
  final List<_WrittenZipEntry> _entries = <_WrittenZipEntry>[];

  /// Number of bytes emitted to [_output].
  int _offset = 0;

  /// Whether the central directory has already been emitted.
  bool _closed = false;

  /// Creates a writer that leaves [output] open after [close].
  ZipStreamWriter(Sink<List<int>> output) : _output = output;

  /// Adds one buffered [entry], optionally compressing it at [level].
  void add(ZipEntry entry, {int level = 6}) {
    _ensureOpen();
    _ensureEntryCapacity();
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    final Uint8List name = _encodeEntryText(entry.name, label: 'name');
    final Uint8List comment = _encodeEntryText(entry.comment, label: 'comment');
    final Uint8List data = entry.data;
    final int checksum = crc32(data);
    final Uint8List compressed = switch (entry.compression) {
      ZipCompression.store => data,
      ZipCompression.deflate => _deflate.encode(data, level: level),
    };
    _requireClassicSize(data.length);
    _requireClassicSize(compressed.length);
    final int method = entry.compression == ZipCompression.store ? 0 : 8;
    final ({int date, int time}) timestamp = _encodeDosTimestamp(entry.modified);
    final int localHeaderOffset = _offset;
    _append(
      ByteWriter()
        ..writeUint32(0x04034b50)
        ..writeUint16(20)
        ..writeUint16(0x0800)
        ..writeUint16(method)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(checksum)
        ..writeUint32(compressed.length)
        ..writeUint32(data.length)
        ..writeUint16(name.length)
        ..writeUint16(0)
        ..writeBytes(name),
    );
    _appendBytes(compressed);
    _entries.add(
      _WrittenZipEntry(
        name: name,
        comment: comment,
        checksum: checksum,
        compressedSize: compressed.length,
        uncompressedSize: data.length,
        localHeaderOffset: localHeaderOffset,
        method: method,
        flags: 0x0800,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        isDirectory: entry.isDirectory,
      ),
    );
  }

  /// Copies one stored entry from [data] without buffering the full payload.
  ///
  /// [size] must be known before streaming and must match the exact number of
  /// bytes emitted by [data]. A data descriptor records the incremental CRC-32.
  Future<void> addStoredStream({
    required String name,
    required Stream<List<int>> data,
    required int size,
    DateTime? modified,
    String comment = '',
  }) async {
    _ensureOpen();
    _ensureEntryCapacity();
    _validateEntryName(name);
    _requireClassicSize(size);
    final Uint8List encodedName = _encodeEntryText(name, label: 'name');
    final Uint8List encodedComment = _encodeEntryText(comment, label: 'comment');
    final ({int date, int time}) timestamp = _encodeDosTimestamp(modified ?? DateTime.now());
    final int localHeaderOffset = _offset;
    const int flags = 0x0808;
    _append(
      ByteWriter()
        ..writeUint32(0x04034b50)
        ..writeUint16(20)
        ..writeUint16(flags)
        ..writeUint16(0)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(0)
        ..writeUint32(0)
        ..writeUint32(0)
        ..writeUint16(encodedName.length)
        ..writeUint16(0)
        ..writeBytes(encodedName),
    );
    final Crc32Accumulator checksum = Crc32Accumulator();
    int actualSize = 0;
    await for (final List<int> chunk in data) {
      if (chunk.length > size - actualSize) {
        throw ZCodecException('ZIP stream "$name" exceeds its declared $size-byte size');
      }
      final Uint8List bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      checksum.add(bytes);
      _appendBytes(bytes);
      actualSize += bytes.length;
    }
    if (actualSize != size) {
      throw ZCodecException('ZIP stream "$name" has $actualSize bytes; expected $size');
    }
    _append(
      ByteWriter()
        ..writeUint32(0x08074b50)
        ..writeUint32(checksum.value)
        ..writeUint32(size)
        ..writeUint32(size),
    );
    _entries.add(
      _WrittenZipEntry(
        name: encodedName,
        comment: encodedComment,
        checksum: checksum.value,
        compressedSize: size,
        uncompressedSize: size,
        localHeaderOffset: localHeaderOffset,
        method: 0,
        flags: flags,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        isDirectory: name.endsWith('/'),
      ),
    );
  }

  /// Writes the central directory and prevents further entries from being added.
  ///
  /// The destination sink is deliberately not closed because its ownership
  /// remains with the caller.
  void close({String comment = ''}) {
    _ensureOpen();
    _closed = true;
    if (_entries.length > 0xffff) {
      throw const ZCodecException('ZIP64 is required for more than 65535 entries');
    }
    final Uint8List archiveComment = _encodeEntryText(comment, label: 'archive comment');
    final int centralDirectoryOffset = _offset;
    for (final _WrittenZipEntry entry in _entries) {
      _append(
        ByteWriter()
          ..writeUint32(0x02014b50)
          ..writeUint16(20)
          ..writeUint16(20)
          ..writeUint16(entry.flags)
          ..writeUint16(entry.method)
          ..writeUint16(entry.dosTime)
          ..writeUint16(entry.dosDate)
          ..writeUint32(entry.checksum)
          ..writeUint32(entry.compressedSize)
          ..writeUint32(entry.uncompressedSize)
          ..writeUint16(entry.name.length)
          ..writeUint16(0)
          ..writeUint16(entry.comment.length)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint32(entry.isDirectory ? 0x10 : 0)
          ..writeUint32(entry.localHeaderOffset)
          ..writeBytes(entry.name)
          ..writeBytes(entry.comment),
      );
    }
    final int centralDirectorySize = _offset - centralDirectoryOffset;
    _append(
      ByteWriter()
        ..writeUint32(0x06054b50)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(_entries.length)
        ..writeUint16(_entries.length)
        ..writeUint32(centralDirectorySize)
        ..writeUint32(centralDirectoryOffset)
        ..writeUint16(archiveComment.length)
        ..writeBytes(archiveComment),
    );
  }

  /// Emits all bytes accumulated by [writer].
  void _append(ByteWriter writer) => _appendBytes(writer.takeBytes());

  /// Emits [bytes] and advances the archive offset.
  void _appendBytes(List<int> bytes) {
    if (bytes.length > 0xffffffff - _offset) {
      throw const ZCodecException('ZIP64 is required for archives larger than 4 GiB');
    }
    _output.add(bytes);
    _offset += bytes.length;
  }

  /// Rejects mutations after [close].
  void _ensureOpen() {
    if (_closed) {
      throw StateError('The ZIP stream writer is already closed');
    }
  }

  /// Rejects an entry count that would require ZIP64.
  void _ensureEntryCapacity() {
    if (_entries.length >= 0xffff) {
      throw const ZCodecException('ZIP64 is required for more than 65535 entries');
    }
  }
}

/// Parses ZIP central directories and lazily inflates their entries.
final class ZipDecoder {
  /// Resource limits applied before any entry is decompressed.
  final ZipLimits limits;

  /// Creates a decoder using [limits] for untrusted archives.
  const ZipDecoder({this.limits = const ZipLimits()});

  /// Decodes [input] while retaining one shared copy for lazy entry access.
  ZipArchive decode(List<int> input) {
    final Uint8List bytes = input is Uint8List ? input : Uint8List.fromList(input);
    try {
      return _decode(bytes);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid ZIP archive: $error');
    }
  }

  /// Parses a validated byte buffer into lazy entries.
  ZipArchive _decode(Uint8List bytes) {
    final int endOffset = _findEndOfCentralDirectory(bytes);
    final ByteReader end = ByteReader(bytes, offset: endOffset + 4);
    final int disk = end.readUint16();
    final int centralDisk = end.readUint16();
    final int entriesOnDisk = end.readUint16();
    final int entryCount = end.readUint16();
    final int centralSize = end.readUint32();
    final int centralOffset = end.readUint32();
    final int commentLength = end.readUint16();
    if (disk != 0 || centralDisk != 0 || entriesOnDisk != entryCount) {
      throw const ZCodecException('Multi-disk ZIP archives are not supported');
    }
    if (entryCount == 0xffff || centralSize == 0xffffffff || centralOffset == 0xffffffff) {
      throw const ZCodecException('ZIP64 archives are not supported');
    }
    if (entryCount > limits.maxEntries) {
      throw ZCodecException('ZIP archive exceeds the ${limits.maxEntries}-entry limit');
    }
    if (centralOffset > endOffset || centralSize > endOffset - centralOffset) {
      throw const ZCodecException('Invalid ZIP central-directory bounds');
    }
    final String archiveComment = _decodeArchiveComment(end.readBytes(commentLength));
    if (end.offset != bytes.length) {
      throw const ZCodecException('Unexpected bytes after the ZIP end record');
    }

    final ByteReader central = ByteReader(bytes, offset: centralOffset);
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
      final int compressedSize = central.readUint32();
      final int uncompressedSize = central.readUint32();
      final int nameLength = central.readUint16();
      final int extraLength = central.readUint16();
      final int entryCommentLength = central.readUint16();
      final int startDisk = central.readUint16();
      central.skip(6);
      final int localOffset = central.readUint32();
      final Uint8List nameBytes = central.readBytes(nameLength);
      central.skip(extraLength);
      final Uint8List commentBytes = central.readBytes(entryCommentLength);
      if (startDisk != 0) {
        throw const ZCodecException('Multi-disk ZIP entries are not supported');
      }
      if ((flags & 0x0001) != 0 || (flags & 0x0040) != 0) {
        throw const ZCodecException('Encrypted ZIP entries are not supported');
      }
      if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff || localOffset == 0xffffffff) {
        throw const ZCodecException('ZIP64 entries are not supported');
      }
      final ZipCompression compression = switch (method) {
        0 => ZipCompression.store,
        8 => ZipCompression.deflate,
        _ => throw ZCodecException('Unsupported ZIP compression method $method'),
      };
      if (compression == ZipCompression.store && compressedSize != uncompressedSize) {
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
      final int dataOffset = _readLocalDataOffset(bytes, localOffset, flags, method);
      if (dataOffset > centralOffset || compressedSize > centralOffset - dataOffset) {
        throw ZCodecException('ZIP entry "$name" has invalid data bounds');
      }
      entries.add(
        ZipEntry._lazy(
          name: name,
          compression: compression,
          modified: _decodeDosTimestamp(dosDate, dosTime),
          comment: _decodeText(commentBytes, utf8Encoded: utf8Encoded),
          checksum: checksum,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          sourceArchive: bytes,
          dataOffset: dataOffset,
          maximumOutputBytes: uncompressedSize,
        ),
      );
    }
    if (central.offset != centralOffset + centralSize) {
      throw const ZCodecException('ZIP central-directory size does not match its entries');
    }
    return ZipArchive(entries: entries, comment: archiveComment);
  }
}

/// Holds the encoded form and metadata of an entry during serialization.
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

  /// Numeric ZIP compression method.
  final int method;

  /// DOS date field.
  final int dosDate;

  /// DOS time field.
  final int dosTime;

  /// CRC-32 of the uncompressed entry bytes at serialization time.
  final int checksum;

  /// Creates serialization metadata for one entry.
  const _EncodedEntry({
    required this.entry,
    required this.name,
    required this.comment,
    required this.compressed,
    required this.localHeaderOffset,
    required this.method,
    required this.dosDate,
    required this.dosTime,
    required this.checksum,
  });
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

/// Rejects a size that requires a ZIP64 integer field.
void _requireClassicSize(int size) {
  if (size < 0 || size > 0xffffffff) {
    throw const ZCodecException('ZIP64 is required for entries larger than 4 GiB');
  }
}
