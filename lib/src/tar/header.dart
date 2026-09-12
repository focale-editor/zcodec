part of 'package:zcodec/src/tar.dart';

/// Size in bytes of every TAR header and padding block.
const int _tarBlockSize = 512;

/// Largest TAR number ZCodec reads or writes.
///
/// GNU base-256 fields are 8 or 12 bytes wide, which is far more than a Dart
/// integer can hold, so both directions are bounded by the exact-integer range
/// shared by every Dart platform rather than by the nominal field width. The
/// limit is over eight petabytes, well beyond any real archive.
const int _maximumTarNumber = 0x1fffffffffffff;

/// Holds the fields parsed from one physical TAR header.
final class _TarHeader {
  /// Header entry name before GNU or PAX overrides.
  final String name;

  /// POSIX mode bits.
  final int mode;

  /// Numeric owner identifier.
  final int userId;

  /// Numeric group identifier.
  final int groupId;

  /// Stored payload size from the physical header.
  final int size;

  /// Modification time in Unix seconds.
  final int modifiedSeconds;

  /// Raw typeflag byte.
  final int typeFlag;

  /// Link target before GNU or PAX overrides.
  final String linkName;

  /// Textual owner name.
  final String userName;

  /// Textual group name.
  final String groupName;

  /// Major device number.
  final int deviceMajor;

  /// Minor device number.
  final int deviceMinor;

  /// Creates parsed physical TAR metadata.
  const _TarHeader({
    required this.name,
    required this.mode,
    required this.userId,
    required this.groupId,
    required this.size,
    required this.modifiedSeconds,
    required this.typeFlag,
    required this.linkName,
    required this.userName,
    required this.groupName,
    required this.deviceMajor,
    required this.deviceMinor,
  });
}

/// Maps [type] to its conventional ustar typeflag.
int _typeFlagFor(TarEntryType type) => switch (type) {
  TarEntryType.regular => 0x30,
  TarEntryType.hardLink => 0x31,
  TarEntryType.symbolicLink => 0x32,
  TarEntryType.characterDevice => 0x33,
  TarEntryType.blockDevice => 0x34,
  TarEntryType.directory => 0x35,
  TarEntryType.fifo => 0x36,
  TarEntryType.contiguous => 0x37,
  TarEntryType.unknown => 0x3f,
};

/// Maps a raw TAR [typeFlag] to its semantic entry type.
TarEntryType _entryTypeFor(int typeFlag) => switch (typeFlag) {
  0 || 0x30 => TarEntryType.regular,
  0x31 => TarEntryType.hardLink,
  0x32 => TarEntryType.symbolicLink,
  0x33 => TarEntryType.characterDevice,
  0x34 => TarEntryType.blockDevice,
  0x35 => TarEntryType.directory,
  0x36 => TarEntryType.fifo,
  0x37 => TarEntryType.contiguous,
  _ => TarEntryType.unknown,
};

/// Whether [block] contains only zero bytes.
bool _isZeroTarBlock(Uint8List block) {
  for (final int byte in block) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

/// Parses a physical TAR header at [offset].
_TarHeader _parseTarHeader(Uint8List bytes, int offset, {required bool verifyChecksum}) {
  if (offset < 0 || offset > bytes.length || _tarBlockSize > bytes.length - offset) {
    throw const ZCodecException('Truncated TAR header');
  }
  final Uint8List block = Uint8List.sublistView(bytes, offset, offset + _tarBlockSize);
  if (verifyChecksum) {
    final int expected = _readTarNumber(block, 148, 8, label: 'checksum');
    int unsignedSum = 0;
    int signedSum = 0;
    for (int index = 0; index < block.length; index++) {
      final int value = index >= 148 && index < 156 ? 0x20 : block[index];
      unsignedSum += value;
      signedSum += value >= 0x80 ? value - 0x100 : value;
    }
    if (expected != unsignedSum && expected != signedSum) {
      throw const ZCodecException('Invalid TAR header checksum');
    }
  }
  final String name = _readTarText(block, 0, 100);
  // The prefix field only exists in POSIX ustar. The GNU format, whose magic
  // ends with a space instead of a NUL, stores atime and ctime at the same
  // offset, so reading it as a path there would corrupt the entry name.
  final String prefix = _isPosixUstar(block) ? _readTarText(block, 345, 155) : '';
  return _TarHeader(
    name: prefix.isEmpty ? name : '$prefix/$name',
    mode: _readTarNumber(block, 100, 8, label: 'mode'),
    userId: _readTarNumber(block, 108, 8, label: 'user ID'),
    groupId: _readTarNumber(block, 116, 8, label: 'group ID'),
    size: _readTarNumber(block, 124, 12, label: 'size'),
    modifiedSeconds: _readTarNumber(block, 136, 12, label: 'modification time'),
    typeFlag: block[156],
    linkName: _readTarText(block, 157, 100),
    userName: _readTarText(block, 265, 32),
    groupName: _readTarText(block, 297, 32),
    deviceMajor: _readTarNumber(block, 329, 8, label: 'device major'),
    deviceMinor: _readTarNumber(block, 337, 8, label: 'device minor'),
  );
}

/// Whether [block] carries the POSIX ustar magic, which is `ustar` and a NUL.
bool _isPosixUstar(Uint8List block) => block[257] == 0x75 && block[258] == 0x73 && block[259] == 0x74 && block[260] == 0x61 && block[261] == 0x72 && block[262] == 0;

/// Reads one NUL- or space-terminated TAR text field.
String _readTarText(Uint8List bytes, int offset, int length) {
  int end = offset;
  final int limit = offset + length;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  while (end > offset && bytes[end - 1] == 0x20) {
    end--;
  }
  final Uint8List value = Uint8List.sublistView(bytes, offset, end);
  try {
    return utf8.decode(value);
  } on FormatException {
    return latin1.decode(value);
  }
}

/// Reads an octal or GNU base-256 TAR number.
int _readTarNumber(Uint8List bytes, int offset, int length, {required String label}) {
  if ((bytes[offset] & 0x80) != 0) {
    // Base-256 fields hold a two's-complement integer whose most significant
    // bit is the base-256 marker and whose next bit carries the sign. Negative
    // values are read through their one's complement so that no intermediate
    // result has to represent 2^(8 * length - 1).
    final bool negative = (bytes[offset] & 0x40) != 0;
    int magnitude = negative ? (~bytes[offset]) & 0x7f : bytes[offset] & 0x7f;
    for (int index = 1; index < length; index++) {
      final int byte = negative ? (~bytes[offset + index]) & 0xff : bytes[offset + index];
      if (magnitude > (_maximumTarNumber - byte) ~/ 256) {
        throw ZCodecException('TAR $label field exceeds the supported range');
      }
      magnitude = magnitude * 256 + byte;
    }
    return negative ? -magnitude - 1 : magnitude;
  }
  int start = offset;
  final int end = offset + length;
  while (start < end && (bytes[start] == 0 || bytes[start] == 0x20)) {
    start++;
  }
  int value = 0;
  bool foundDigit = false;
  for (int index = start; index < end; index++) {
    final int byte = bytes[index];
    if (byte == 0 || byte == 0x20) {
      break;
    }
    if (byte < 0x30 || byte > 0x37) {
      throw ZCodecException('Invalid TAR $label field');
    }
    foundDigit = true;
    value = value * 8 + byte - 0x30;
  }
  return foundDigit ? value : 0;
}

/// Writes one complete ustar header for [entry].
Uint8List _writeTarHeader(
  TarEntry entry, {
  required String storedName,
  required String storedLinkName,
  required int storedSize,
  required int modifiedSeconds,
  String? storedUserName,
  String? storedGroupName,
  int? typeFlag,
  _TarPathFields? pathFields,
}) {
  final Uint8List block = Uint8List(_tarBlockSize);
  final _TarPathFields path = pathFields ?? _splitTarPath(storedName);
  _writeTarBytes(block, 0, 100, path.name);
  _writeTarNumber(block, 100, 8, entry.mode);
  _writeTarNumber(block, 108, 8, entry.userId);
  _writeTarNumber(block, 116, 8, entry.groupId);
  _writeTarNumber(block, 124, 12, storedSize);
  _writeTarNumber(block, 136, 12, modifiedSeconds);
  for (int index = 148; index < 156; index++) {
    block[index] = 0x20;
  }
  block[156] = typeFlag ?? entry.typeFlag;
  _writeTarText(block, 157, 100, storedLinkName);
  _writeTarBytes(block, 257, 6, const <int>[0x75, 0x73, 0x74, 0x61, 0x72, 0]);
  _writeTarBytes(block, 263, 2, const <int>[0x30, 0x30]);
  _writeTarText(block, 265, 32, storedUserName ?? entry.userName);
  _writeTarText(block, 297, 32, storedGroupName ?? entry.groupName);
  _writeTarNumber(block, 329, 8, entry.deviceMajor);
  _writeTarNumber(block, 337, 8, entry.deviceMinor);
  _writeTarBytes(block, 345, 155, path.prefix);
  int checksum = 0;
  for (final int byte in block) {
    checksum += byte;
  }
  final String checksumText = checksum.toRadixString(8).padLeft(6, '0');
  _writeTarBytes(block, 148, 6, ascii.encode(checksumText));
  block[154] = 0;
  block[155] = 0x20;
  return block;
}

/// Writes [value] as octal when possible and GNU base-256 otherwise.
void _writeTarNumber(Uint8List target, int offset, int length, int value) {
  if (value >= 0) {
    final String octal = value.toRadixString(8);
    if (octal.length <= length - 1) {
      final String padded = octal.padLeft(length - 1, '0');
      _writeTarBytes(target, offset, length - 1, ascii.encode(padded));
      target[offset + length - 1] = 0;
      return;
    }
  }
  if (value < -_maximumTarNumber - 1 || value > _maximumTarNumber) {
    throw RangeError.range(value, -_maximumTarNumber - 1, _maximumTarNumber, 'value', 'TAR number does not fit its field');
  }
  // Arithmetic shifting writes the two's-complement representation directly,
  // sign-extending a negative value through the leading bytes of the field.
  int encoded = value;
  for (int index = length - 1; index >= 0; index--) {
    target[offset + index] = encoded & 0xff;
    encoded >>= 8;
  }
  target[offset] |= 0x80;
}

/// Writes UTF-8 [value] into a fixed-width TAR field.
void _writeTarText(Uint8List target, int offset, int length, String value) {
  final Uint8List encoded = Uint8List.fromList(utf8.encode(value));
  if (encoded.length > length) {
    throw ZCodecException('TAR text field exceeds $length bytes');
  }
  _writeTarBytes(target, offset, length, encoded);
}

/// Copies [value] into a fixed-width field at [offset].
void _writeTarBytes(Uint8List target, int offset, int length, List<int> value) {
  if (value.length > length) {
    throw ZCodecException('TAR field exceeds $length bytes');
  }
  target.setRange(offset, offset + value.length, value);
}
