part of 'package:zcodec/src/zip.dart';

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
