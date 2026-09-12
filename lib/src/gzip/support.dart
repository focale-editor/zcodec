part of 'package:zcodec/src/gzip.dart';

/// Smallest possible GZIP member: a 10-byte header, an empty stored DEFLATE
/// block, and an 8-byte trailer.
const int _minimumMemberLength = 10 + 2 + 8;

/// Holds one decoded member and the following input offset.
final class _DecodedGzipMember {
  /// Decoded member.
  final GzipMember member;

  /// Offset immediately after the member trailer.
  final int nextOffset;

  /// Creates a member decoding result.
  const _DecodedGzipMember({required this.member, required this.nextOffset});
}

/// Holds a zero-terminated header string and its following offset.
final class _TerminatedText {
  /// Decoded ISO-8859-1 text.
  final String value;

  /// Offset immediately after the NUL terminator.
  final int nextOffset;

  /// Creates a terminated-text decoding result.
  const _TerminatedText({required this.value, required this.nextOffset});
}

/// Writes one complete GZIP [member] compressed at [level].
void _encodeMember(ByteWriter output, GzipMember member, int level) {
  _writeGzipHeader(output, member.header, level);
  output
    ..writeBytes(DeflateEncoder(level: level).convert(member.data))
    ..writeUint32(crc32(member.data))
    ..writeUint32(member.data.length & 0xffffffff);
}

/// Writes the metadata and optional header checksum of one GZIP member.
void _writeGzipHeader(ByteWriter output, GzipHeader header, int level) {
  final Uint8List? encodedName = _encodeHeaderText(header.name, label: 'name');
  final Uint8List? encodedComment = _encodeHeaderText(header.comment, label: 'comment');
  int flags = header.isText ? 0x01 : 0;
  if (header.headerChecksum) {
    flags |= 0x02;
  }
  if (header.extra.isNotEmpty) {
    flags |= 0x04;
  }
  if (encodedName != null) {
    flags |= 0x08;
  }
  if (encodedComment != null) {
    flags |= 0x10;
  }
  final int extraFlags = header.compressionFlags != 0
      ? header.compressionFlags
      : switch (level) {
          9 => 2,
          1 => 4,
          _ => 0,
        };
  final ByteWriter headerBytes = ByteWriter()
    ..writeByte(0x1f)
    ..writeByte(0x8b)
    ..writeByte(8)
    ..writeByte(flags)
    ..writeUint32(_encodeModifiedTime(header.modified))
    ..writeByte(extraFlags)
    ..writeByte(header.operatingSystem);
  if (header.extra.isNotEmpty) {
    headerBytes
      ..writeUint16(header.extra.length)
      ..writeBytes(header.extra);
  }
  if (encodedName != null) {
    headerBytes
      ..writeBytes(encodedName)
      ..writeByte(0);
  }
  if (encodedComment != null) {
    headerBytes
      ..writeBytes(encodedComment)
      ..writeByte(0);
  }
  final Uint8List encodedHeader = headerBytes.takeBytes();
  output.writeBytes(encodedHeader);
  if (header.headerChecksum) {
    // RFC 1952 stores the two least significant bytes of the header CRC-32.
    output.writeUint16(crc32(encodedHeader) & 0xffff);
  }
}

/// Decodes one member beginning at [start].
_DecodedGzipMember _decodeMember(Uint8List bytes, int start, int? maximumOutput) {
  if (bytes.length - start < _minimumMemberLength) {
    throw const ZCodecException('Truncated GZIP member');
  }
  int offset = start;
  if (bytes[offset++] != 0x1f || bytes[offset++] != 0x8b) {
    throw const ZCodecException('Invalid GZIP member signature');
  }
  if (bytes[offset++] != 8) {
    throw const ZCodecException('Unsupported GZIP compression method');
  }
  final int flags = bytes[offset++];
  if ((flags & 0xe0) != 0) {
    throw const ZCodecException('Reserved GZIP flags are set');
  }
  final int modifiedSeconds = _readUint32(bytes, offset);
  offset += 4;
  final int compressionFlags = bytes[offset++];
  final int operatingSystem = bytes[offset++];
  Uint8List extra = Uint8List(0);
  if ((flags & 0x04) != 0) {
    _requireAvailable(bytes, offset, 2);
    final int length = bytes[offset] | (bytes[offset + 1] << 8);
    offset += 2;
    _requireAvailable(bytes, offset, length);
    extra = Uint8List.fromList(Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
  }
  String? name;
  if ((flags & 0x08) != 0) {
    final _TerminatedText text = _readTerminatedText(bytes, offset, label: 'file name');
    name = text.value;
    offset = text.nextOffset;
  }
  String? comment;
  if ((flags & 0x10) != 0) {
    final _TerminatedText text = _readTerminatedText(bytes, offset, label: 'comment');
    comment = text.value;
    offset = text.nextOffset;
  }
  if ((flags & 0x02) != 0) {
    _requireAvailable(bytes, offset, 2);
    final int expected = bytes[offset] | (bytes[offset + 1] << 8);
    if ((crc32(Uint8List.sublistView(bytes, start, offset)) & 0xffff) != expected) {
      throw const ZCodecException('Invalid GZIP header checksum');
    }
    offset += 2;
  }
  final DeflateDecodeResult decoded = DeflateDecoder(maxOutputBytes: maximumOutput).convertPrefix(Uint8List.sublistView(bytes, offset));
  offset += decoded.bytesRead;
  _requireAvailable(bytes, offset, 8);
  final int expectedChecksum = _readUint32(bytes, offset);
  final int expectedSize = _readUint32(bytes, offset + 4);
  offset += 8;
  if (crc32(decoded.data) != expectedChecksum) {
    throw const ZCodecException('Invalid GZIP data checksum');
  }
  if ((decoded.data.length & 0xffffffff) != expectedSize) {
    throw const ZCodecException('Invalid GZIP uncompressed size');
  }
  return _DecodedGzipMember(
    member: GzipMember._decoded(
      data: decoded.data,
      header: GzipHeader(
        modified: modifiedSeconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(modifiedSeconds * 1000, isUtc: true),
        name: name,
        comment: comment,
        extra: extra,
        operatingSystem: operatingSystem,
        isText: (flags & 0x01) != 0,
        headerChecksum: (flags & 0x02) != 0,
        compressionFlags: compressionFlags,
      ),
    ),
    nextOffset: offset,
  );
}

/// Encodes optional GZIP [value] as ISO-8859-1 without its terminator.
Uint8List? _encodeHeaderText(String? value, {required String label}) {
  if (value == null) {
    return null;
  }
  if (value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, label, 'GZIP text must not contain NUL');
  }
  try {
    return Uint8List.fromList(latin1.encode(value));
  } on FormatException {
    throw ArgumentError.value(value, label, 'GZIP text must be representable as ISO-8859-1');
  }
}

/// Converts [modified] to an unsigned RFC 1952 timestamp.
int _encodeModifiedTime(DateTime? modified) {
  if (modified == null) {
    return 0;
  }
  final int seconds = modified.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw ArgumentError.value(modified, 'modified', 'GZIP timestamps must fit an unsigned 32-bit Unix time');
  }
  return seconds;
}

/// Reads a little-endian unsigned 32-bit integer at [offset].
int _readUint32(Uint8List bytes, int offset) {
  _requireAvailable(bytes, offset, 4);
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) & 0xffffffff;
}

/// Reads a zero-terminated ISO-8859-1 string at [offset].
_TerminatedText _readTerminatedText(Uint8List bytes, int offset, {required String label}) {
  int cursor = offset;
  while (cursor < bytes.length && bytes[cursor] != 0) {
    cursor++;
  }
  if (cursor == bytes.length) {
    throw ZCodecException('Unterminated GZIP $label');
  }
  return _TerminatedText(value: latin1.decode(Uint8List.sublistView(bytes, offset, cursor)), nextOffset: cursor + 1);
}

/// Ensures [length] bytes are available at [offset].
void _requireAvailable(Uint8List bytes, int offset, int length) {
  if (offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset) {
    throw const ZCodecException('Truncated GZIP member');
  }
}
