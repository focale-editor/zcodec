part of 'package:zcodec/src/zip.dart';

/// Writes ZIP entries incrementally to an arbitrary Dart byte sink.
///
/// Buffered entries may use DEFLATE and password encryption.
/// [addStoredStream] copies large, already-compressed assets without retaining
/// them in memory. Classic ZIP and ZIP64 output are both supported.
final class ZipStreamWriter {
  /// Destination receiving serialized ZIP chunks.
  final Sink<List<int>> _output;

  /// Password lookup used for encrypted buffered entries.
  final ZipPasswordProvider? passwordProvider;

  /// Random-byte source used for encryption headers and salts.
  final ZipRandomBytes _randomBytes;

  /// Whether every entry and the archive end records use ZIP64.
  final bool forceZip64;

  /// Waits until a buffering destination has consumed previously added bytes.
  ///
  /// Stream consumers, including IOSink, are paced automatically through
  /// addStream. Supply this callback for an asynchronous plain Sink instead.
  final Future<void> Function()? flush;

  /// Central-directory metadata accumulated for completed entries.
  final List<_WrittenZipEntry> _entries = <_WrittenZipEntry>[];

  /// Number of bytes emitted to [_output].
  int _offset = 0;

  /// Whether the central directory has already been emitted.
  bool _closed = false;

  /// Whether a streamed entry currently owns the output.
  bool _busy = false;

  /// Whether a failed streamed entry left an incomplete archive.
  bool _failed = false;

  /// Creates a writer that leaves [output] open after [close].
  ZipStreamWriter(
    Sink<List<int>> output, {
    this.passwordProvider,
    ZipRandomBytes? randomBytes,
    this.forceZip64 = false,
    this.flush,
  }) : _output = output,
       _randomBytes = randomBytes ?? _secureRandomBytes;

  /// Adds one buffered [entry], optionally compressing it at [level].
  void add(ZipEntry entry, {int level = defaultCompressionLevel}) {
    _ensureOpen();
    _ensureEntryCapacity();
    validateCompressionLevel(level);
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
      randomBytes: _randomBytes,
    );
    final ({int date, int time}) timestamp = _encodeDosTimestamp(entry.modified);
    final int localHeaderOffset = _offset;
    final bool zip64 = forceZip64 || data.length >= 0xffffffff || encrypted.bytes.length >= 0xffffffff || localHeaderOffset >= 0xffffffff;
    final Uint8List localExtra = joinBytes(
      encrypted.extra,
      zip64 ? _zip64LocalExtra(uncompressedSize: data.length, compressedSize: encrypted.bytes.length) : Uint8List(0),
    );
    final Uint8List centralExtra = joinBytes(
      encrypted.extra,
      zip64
          ? _zip64CentralExtra(
              uncompressedSize: data.length,
              compressedSize: encrypted.bytes.length,
              localHeaderOffset: localHeaderOffset,
              diskStart: 0,
            )
          : Uint8List(0),
    );
    _append(
      ByteWriter()
        ..writeUint32(0x04034b50)
        ..writeUint16(zip64 ? 45 : 20)
        ..writeUint16(encrypted.flags)
        ..writeUint16(encrypted.headerMethod)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(encrypted.headerChecksum)
        ..writeUint32(zip64 ? 0xffffffff : encrypted.bytes.length)
        ..writeUint32(zip64 ? 0xffffffff : data.length)
        ..writeUint16(name.length)
        ..writeUint16(localExtra.length)
        ..writeBytes(name)
        ..writeBytes(localExtra),
    );
    _appendBytes(encrypted.bytes);
    _entries.add(
      _WrittenZipEntry(
        name: name,
        comment: comment,
        checksum: encrypted.headerChecksum,
        compressedSize: encrypted.bytes.length,
        uncompressedSize: data.length,
        localHeaderOffset: localHeaderOffset,
        method: encrypted.headerMethod,
        flags: encrypted.flags,
        centralExtra: centralExtra,
        zip64: zip64,
        dosDate: timestamp.date,
        dosTime: timestamp.time,
        isDirectory: entry.isDirectory,
      ),
    );
  }

  /// Copies one stored entry from [data] without buffering the full payload.
  ///
  /// [size] must be known before streaming and must match the exact number of
  /// bytes emitted by [data]. A classic or ZIP64 data descriptor records the
  /// incremental CRC-32. Streamed entries are not encrypted; use [add] when
  /// per-entry encryption is required.
  Future<void> addStoredStream({
    required String name,
    required Stream<List<int>> data,
    required int size,
    DateTime? modified,
    String comment = '',
  }) async {
    _ensureOpen();
    _busy = true;
    try {
      await _addStoredStream(name: name, data: data, size: size, modified: modified, comment: comment);
    } on Object {
      _failed = true;
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Writes one entry while respecting the destination's consumption rate.
  Future<void> _addStoredStream({required String name, required Stream<List<int>> data, required int size, DateTime? modified, required String comment}) async {
    _ensureEntryCapacity();
    _validateEntryName(name);
    if (size < 0) {
      throw RangeError.value(size, 'size', 'A ZIP stream size must not be negative');
    }
    final Uint8List encodedName = _encodeEntryText(name, label: 'entry name');
    final Uint8List encodedComment = _encodeEntryText(comment, label: 'entry comment');
    final ({int date, int time}) timestamp = _encodeDosTimestamp(modified ?? DateTime.now());
    final int localHeaderOffset = _offset;
    final bool zip64 = forceZip64 || size >= 0xffffffff || localHeaderOffset >= 0xffffffff;
    final Uint8List localExtra = zip64 ? _zip64LocalExtra(uncompressedSize: size, compressedSize: size) : Uint8List(0);
    final Uint8List centralExtra = zip64 ? _zip64CentralExtra(uncompressedSize: size, compressedSize: size, localHeaderOffset: localHeaderOffset, diskStart: 0) : Uint8List(0);
    const int flags = 0x0808;
    _append(
      ByteWriter()
        ..writeUint32(0x04034b50)
        ..writeUint16(zip64 ? 45 : 20)
        ..writeUint16(flags)
        ..writeUint16(0)
        ..writeUint16(timestamp.time)
        ..writeUint16(timestamp.date)
        ..writeUint32(0)
        ..writeUint32(zip64 ? 0xffffffff : 0)
        ..writeUint32(zip64 ? 0xffffffff : 0)
        ..writeUint16(encodedName.length)
        ..writeUint16(localExtra.length)
        ..writeBytes(encodedName)
        ..writeBytes(localExtra),
    );
    final Crc32Accumulator checksum = Crc32Accumulator();
    int actualSize = 0;
    List<int> validateChunk(List<int> chunk) {
      if (chunk.length > size - actualSize) {
        throw ZCodecException('ZIP stream "$name" exceeds its declared $size-byte size');
      }
      final Uint8List bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      checksum.add(bytes);
      actualSize += bytes.length;
      return bytes;
    }

    final Sink<List<int>> destination = _output;
    final Future<void> Function()? drain = flush;
    if (drain == null && destination is StreamConsumer<List<int>>) {
      await (destination as StreamConsumer<List<int>>).addStream(
        data.map((chunk) {
          final List<int> bytes = validateChunk(chunk);
          _offset += bytes.length;
          return bytes;
        }),
      );
    } else {
      if (drain != null) {
        await drain();
      }
      await for (final List<int> chunk in data) {
        _appendBytes(validateChunk(chunk));
        if (drain != null) {
          await drain();
        }
      }
    }
    if (actualSize != size) {
      throw ZCodecException('ZIP stream "$name" has $actualSize bytes; expected $size');
    }
    final ByteWriter descriptor = ByteWriter()
      ..writeUint32(0x08074b50)
      ..writeUint32(checksum.value);
    if (zip64) {
      descriptor
        ..writeUint64(size)
        ..writeUint64(size);
    } else {
      descriptor
        ..writeUint32(size)
        ..writeUint32(size);
    }
    _append(descriptor);
    if (drain != null) {
      await drain();
    }
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
        centralExtra: centralExtra,
        zip64: zip64,
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
    final Uint8List archiveComment = _encodeEntryText(comment, label: 'archive comment');
    final int centralDirectoryOffset = _offset;
    for (final _WrittenZipEntry entry in _entries) {
      _append(
        ByteWriter()
          ..writeUint32(0x02014b50)
          ..writeUint16(entry.zip64 ? 45 : 20)
          ..writeUint16(entry.zip64 ? 45 : 20)
          ..writeUint16(entry.flags)
          ..writeUint16(entry.method)
          ..writeUint16(entry.dosTime)
          ..writeUint16(entry.dosDate)
          ..writeUint32(entry.checksum)
          ..writeUint32(entry.zip64 ? 0xffffffff : entry.compressedSize)
          ..writeUint32(entry.zip64 ? 0xffffffff : entry.uncompressedSize)
          ..writeUint16(entry.name.length)
          ..writeUint16(entry.centralExtra.length)
          ..writeUint16(entry.comment.length)
          ..writeUint16(entry.zip64 ? 0xffff : 0)
          ..writeUint16(0)
          ..writeUint32(entry.isDirectory ? 0x10 : 0)
          ..writeUint32(entry.zip64 ? 0xffffffff : entry.localHeaderOffset)
          ..writeBytes(entry.name)
          ..writeBytes(entry.centralExtra)
          ..writeBytes(entry.comment),
      );
    }
    final int centralDirectorySize = _offset - centralDirectoryOffset;
    final bool zip64Archive = forceZip64 || _entries.any((entry) => entry.zip64) || _entries.length >= 0xffff || centralDirectorySize >= 0xffffffff || centralDirectoryOffset >= 0xffffffff;
    if (zip64Archive) {
      final int zip64EndOffset = _offset;
      _append(
        ByteWriter()
          ..writeUint32(0x06064b50)
          ..writeUint64(44)
          ..writeUint16(45)
          ..writeUint16(45)
          ..writeUint32(0)
          ..writeUint32(0)
          ..writeUint64(_entries.length)
          ..writeUint64(_entries.length)
          ..writeUint64(centralDirectorySize)
          ..writeUint64(centralDirectoryOffset)
          ..writeUint32(0x07064b50)
          ..writeUint32(0)
          ..writeUint64(zip64EndOffset)
          ..writeUint32(1),
      );
    }
    _append(
      ByteWriter()
        ..writeUint32(0x06054b50)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(zip64Archive ? 0xffff : _entries.length)
        ..writeUint16(zip64Archive ? 0xffff : _entries.length)
        ..writeUint32(zip64Archive ? 0xffffffff : centralDirectorySize)
        ..writeUint32(zip64Archive ? 0xffffffff : centralDirectoryOffset)
        ..writeUint16(archiveComment.length)
        ..writeBytes(archiveComment),
    );
  }

  /// Emits all bytes accumulated by [writer].
  void _append(ByteWriter writer) => _appendBytes(writer.takeBytes());

  /// Emits [bytes] and advances the archive offset.
  void _appendBytes(List<int> bytes) {
    _output.add(bytes);
    _offset += bytes.length;
  }

  /// Rejects mutations after [close].
  void _ensureOpen() {
    if (_closed) {
      throw StateError('The ZIP stream writer is already closed');
    }
    if (_busy) {
      throw StateError('A streamed ZIP entry is still being written');
    }
    if (_failed) {
      throw StateError('The ZIP stream writer contains an incomplete entry');
    }
  }

  /// Rejects entry counts beyond Dart's portable exact-integer range.
  void _ensureEntryCapacity() {
    if (_entries.length >= 0x1fffffffffffff) {
      throw const ZCodecException('ZIP entry count exceeds Dart\'s portable exact-integer range');
    }
  }
}
