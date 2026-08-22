import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/byte_io.dart';
import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/deflate_codec.dart';
import 'package:zcodec/src/exception.dart';

/// Represents one RFC 1952 GZIP member and its optional metadata.
final class GzipMember {
  /// Uncompressed member bytes.
  final Uint8List data;

  /// Original modification time, or `null` when the header stores zero.
  final DateTime? modified;

  /// Optional original file name encoded as ISO-8859-1.
  final String? name;

  /// Optional human-readable comment encoded as ISO-8859-1.
  final String? comment;

  /// Optional raw GZIP extra-field bytes.
  final Uint8List extra;

  /// Operating-system identifier stored in the member header.
  final int operatingSystem;

  /// Whether the member advertises probably textual data.
  final bool isText;

  /// Whether the member includes a header CRC-16.
  final bool headerChecksum;

  /// Compression-specific extra flags stored in the member header.
  final int compressionFlags;

  /// Creates a GZIP member backed by a copy of [data] and [extra].
  GzipMember({
    required List<int> data,
    this.modified,
    this.name,
    this.comment,
    List<int> extra = const <int>[],
    this.operatingSystem = 255,
    this.isText = false,
    this.headerChecksum = false,
    this.compressionFlags = 0,
  }) : data = Uint8List.fromList(data),
       extra = Uint8List.fromList(extra) {
    if (operatingSystem < 0 || operatingSystem > 255) {
      throw RangeError.range(operatingSystem, 0, 255, 'operatingSystem');
    }
    if (compressionFlags < 0 || compressionFlags > 255) {
      throw RangeError.range(compressionFlags, 0, 255, 'compressionFlags');
    }
    if (this.extra.length > 0xffff) {
      throw ArgumentError.value(this.extra.length, 'extra', 'A GZIP extra field cannot exceed 65535 bytes');
    }
    _encodeOptionalText(name, label: 'name');
    _encodeOptionalText(comment, label: 'comment');
  }
}

/// Encodes and decodes RFC 1952 GZIP files in pure Dart.
final class GzipCodec {
  /// Raw DEFLATE implementation shared by every codec instance.
  static const DeflateCodec _deflate = DeflateCodec();

  /// Creates a stateless GZIP codec.
  const GzipCodec();

  /// Compresses [input] as one GZIP member.
  Uint8List encode(
    List<int> input, {
    int level = 6,
    DateTime? modified,
    String? name,
    String? comment,
    List<int> extra = const <int>[],
    int operatingSystem = 255,
    bool isText = false,
    bool headerChecksum = false,
  }) => encodeMembers(
    <GzipMember>[
      GzipMember(
        data: input,
        modified: modified,
        name: name,
        comment: comment,
        extra: extra,
        operatingSystem: operatingSystem,
        isText: isText,
        headerChecksum: headerChecksum,
      ),
    ],
    level: level,
  );

  /// Compresses [members] as one concatenated GZIP file.
  Uint8List encodeMembers(Iterable<GzipMember> members, {int level = 6}) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    final ByteWriter output = ByteWriter();
    int count = 0;
    for (final GzipMember member in members) {
      output.writeBytes(_encodeMember(member, level));
      count++;
    }
    if (count == 0) {
      throw ArgumentError.value(members, 'members', 'A GZIP file must contain at least one member');
    }
    return output.takeBytes();
  }

  /// Decompresses and concatenates every member in [input].
  Uint8List decode(List<int> input, {int? maxOutputBytes, int maxMembers = 10000}) {
    final List<GzipMember> members = decodeMembers(input, maxOutputBytes: maxOutputBytes, maxMembers: maxMembers);
    final BytesBuilder output = BytesBuilder(copy: false);
    for (final GzipMember member in members) {
      output.add(member.data);
    }
    return output.takeBytes();
  }

  /// Decompresses every member in [input] while preserving its metadata.
  List<GzipMember> decodeMembers(List<int> input, {int? maxOutputBytes, int maxMembers = 10000}) {
    if (maxOutputBytes != null && maxOutputBytes < 0) {
      throw RangeError.value(maxOutputBytes, 'maxOutputBytes', 'Must not be negative');
    }
    if (maxMembers <= 0) {
      throw RangeError.value(maxMembers, 'maxMembers', 'Must be positive');
    }
    final Uint8List bytes = input is Uint8List ? input : Uint8List.fromList(input);
    if (bytes.isEmpty) {
      throw const ZCodecException('A GZIP file must contain at least one member');
    }
    try {
      final List<GzipMember> members = <GzipMember>[];
      int offset = 0;
      int totalOutput = 0;
      while (offset < bytes.length) {
        if (members.length >= maxMembers) {
          throw ZCodecException('GZIP file exceeds the $maxMembers-member limit');
        }
        final _DecodedGzipMember decoded = _decodeMember(
          bytes,
          offset,
          maxOutputBytes == null ? null : maxOutputBytes - totalOutput,
        );
        members.add(decoded.member);
        totalOutput += decoded.member.data.length;
        offset = decoded.nextOffset;
      }
      return List<GzipMember>.unmodifiable(members);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid GZIP file: $error');
    }
  }

  /// Encodes one [member] using [level].
  Uint8List _encodeMember(GzipMember member, int level) {
    final Uint8List? encodedName = _encodeOptionalText(member.name, label: 'name');
    final Uint8List? encodedComment = _encodeOptionalText(member.comment, label: 'comment');
    int flags = member.isText ? 0x01 : 0;
    if (member.headerChecksum) {
      flags |= 0x02;
    }
    if (member.extra.isNotEmpty) {
      flags |= 0x04;
    }
    if (encodedName != null) {
      flags |= 0x08;
    }
    if (encodedComment != null) {
      flags |= 0x10;
    }
    final int modifiedSeconds = _encodeModifiedTime(member.modified);
    final int extraFlags = member.compressionFlags != 0
        ? member.compressionFlags
        : level == 9
        ? 2
        : level == 1
        ? 4
        : 0;
    final ByteWriter header = ByteWriter()
      ..writeByte(0x1f)
      ..writeByte(0x8b)
      ..writeByte(8)
      ..writeByte(flags)
      ..writeUint32(modifiedSeconds)
      ..writeByte(extraFlags)
      ..writeByte(member.operatingSystem);
    if (member.extra.isNotEmpty) {
      header
        ..writeUint16(member.extra.length)
        ..writeBytes(member.extra);
    }
    if (encodedName != null) {
      header
        ..writeBytes(encodedName)
        ..writeByte(0);
    }
    if (encodedComment != null) {
      header
        ..writeBytes(encodedComment)
        ..writeByte(0);
    }
    final ByteWriter output = ByteWriter();
    final Uint8List headerBytes = header.takeBytes();
    output.writeBytes(headerBytes);
    if (member.headerChecksum) {
      output.writeUint16(crc32(headerBytes) & 0xffff);
    }
    output
      ..writeBytes(_deflate.encode(member.data, level: level))
      ..writeUint32(crc32(member.data))
      ..writeUint32(member.data.length & 0xffffffff);
    return output.takeBytes();
  }

  /// Decodes one member beginning at [start].
  _DecodedGzipMember _decodeMember(Uint8List bytes, int start, int? maximumOutput) {
    if (bytes.length - start < 18) {
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
      final int actual = crc32(Uint8List.sublistView(bytes, start, offset)) & 0xffff;
      if (actual != expected) {
        throw const ZCodecException('Invalid GZIP header checksum');
      }
      offset += 2;
    }
    final DeflateDecodeResult decoded = _deflate.decodePrefix(
      Uint8List.sublistView(bytes, offset),
      maxOutputBytes: maximumOutput,
    );
    offset += decoded.bytesRead;
    _requireAvailable(bytes, offset, 8);
    final int expectedChecksum = _readUint32(bytes, offset);
    final int expectedSize = _readUint32(bytes, offset + 4);
    offset += 8;
    final int actualChecksum = crc32(decoded.data);
    if (actualChecksum != expectedChecksum) {
      throw const ZCodecException('Invalid GZIP data checksum');
    }
    if ((decoded.data.length & 0xffffffff) != expectedSize) {
      throw const ZCodecException('Invalid GZIP uncompressed size');
    }
    return _DecodedGzipMember(
      member: GzipMember(
        data: decoded.data,
        modified: modifiedSeconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(modifiedSeconds * 1000, isUtc: true),
        name: name,
        comment: comment,
        extra: extra,
        operatingSystem: operatingSystem,
        isText: (flags & 0x01) != 0,
        headerChecksum: (flags & 0x02) != 0,
        compressionFlags: compressionFlags,
      ),
      nextOffset: offset,
    );
  }
}

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

/// Encodes optional GZIP [value] as ISO-8859-1 without its terminator.
Uint8List? _encodeOptionalText(String? value, {required String label}) {
  if (value == null) {
    return null;
  }
  if (value.contains('\u0000')) {
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
  final int start = offset;
  int cursor = offset;
  while (cursor < bytes.length && bytes[cursor] != 0) {
    cursor++;
  }
  if (cursor == bytes.length) {
    throw ZCodecException('Unterminated GZIP $label');
  }
  return _TerminatedText(value: latin1.decode(Uint8List.sublistView(bytes, start, cursor)), nextOffset: cursor + 1);
}

/// Ensures [length] bytes are available at [offset].
void _requireAvailable(Uint8List bytes, int offset, int length) {
  if (offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset) {
    throw const ZCodecException('Truncated GZIP member');
  }
}
