part of '../tar.dart';

/// Size in bytes of every TAR header and padding block.
const int _tarBlockSize = 512;

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

/// Holds name and prefix bytes selected for a ustar header.
final class _TarPathFields {
  /// Name-field bytes, limited to 100 bytes.
  final Uint8List name;

  /// Prefix-field bytes, limited to 155 bytes.
  final Uint8List prefix;

  /// Whether a PAX path override is required.
  final bool requiresPax;

  /// Creates a split ustar path representation.
  const _TarPathFields({required this.name, required this.prefix, required this.requiresPax});
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
  final String prefix = _readTarText(block, 345, 155);
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
    final int bitCount = length * 8 - 1;
    int value = bytes[offset] & 0x7f;
    for (int index = 1; index < length; index++) {
      value = value * 256 + bytes[offset + index];
    }
    if ((bytes[offset] & 0x40) != 0) {
      value -= 1 << bitCount;
    }
    return value;
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
}) {
  final Uint8List block = Uint8List(_tarBlockSize);
  final _TarPathFields path = _splitTarPath(storedName);
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
  final int bitCount = length * 8 - 1;
  final int minimum = -(1 << (bitCount - 1));
  final int maximum = (1 << (bitCount - 1)) - 1;
  if (value < minimum || value > maximum) {
    throw RangeError.range(value, minimum, maximum, 'value', 'TAR number does not fit its field');
  }
  int encoded = value < 0 ? value + (1 << bitCount) : value;
  for (int index = length - 1; index >= 0; index--) {
    target[offset + index] = encoded & 0xff;
    encoded ~/= 256;
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

/// Splits [path] into the ustar name and prefix fields when possible.
_TarPathFields _splitTarPath(String path) {
  final Uint8List whole = Uint8List.fromList(utf8.encode(path));
  if (whole.length <= 100) {
    return _TarPathFields(name: whole, prefix: Uint8List(0), requiresPax: false);
  }
  for (int index = path.length - 1; index > 0; index--) {
    if (path.codeUnitAt(index) != 0x2f) {
      continue;
    }
    final Uint8List prefix = Uint8List.fromList(utf8.encode(path.substring(0, index)));
    final Uint8List name = Uint8List.fromList(utf8.encode(path.substring(index + 1)));
    if (prefix.length <= 155 && name.isNotEmpty && name.length <= 100) {
      return _TarPathFields(name: name, prefix: prefix, requiresPax: false);
    }
  }
  final Uint8List fallback = whole.length <= 100 ? whole : Uint8List.fromList(utf8.encode(_tarBaseName(path)));
  return _TarPathFields(
    name: fallback.length <= 100 ? fallback : Uint8List.fromList(ascii.encode('PaxPath')),
    prefix: Uint8List(0),
    requiresPax: true,
  );
}

/// Encodes [headers] as POSIX PAX length-prefixed records.
Uint8List _encodePaxHeaders(Map<String, String> headers) {
  final BytesBuilder output = BytesBuilder(copy: false);
  for (final MapEntry<String, String> header in headers.entries) {
    if (header.key.isEmpty || header.key.contains('=') || header.key.contains('\n') || header.value.contains('\u0000')) {
      throw ZCodecException('Invalid PAX header key or value: ${header.key}');
    }
    final Uint8List body = Uint8List.fromList(utf8.encode('${header.key}=${header.value}\n'));
    int length = body.length + 2;
    while (true) {
      final int actual = body.length + length.toString().length + 1;
      if (actual == length) {
        break;
      }
      length = actual;
    }
    output
      ..add(ascii.encode('$length '))
      ..add(body);
  }
  return output.takeBytes();
}

/// Parses POSIX PAX length-prefixed [data].
Map<String, String> _parsePaxHeaders(Uint8List data) {
  final Map<String, String> result = <String, String>{};
  int offset = 0;
  while (offset < data.length) {
    final int recordStart = offset;
    int space = offset;
    while (space < data.length && data[space] != 0x20) {
      if (data[space] < 0x30 || data[space] > 0x39) {
        throw const ZCodecException('Invalid PAX record length');
      }
      space++;
    }
    if (space == offset || space == data.length) {
      throw const ZCodecException('Truncated PAX record length');
    }
    final int length = int.parse(ascii.decode(Uint8List.sublistView(data, offset, space)));
    final int end = recordStart + length;
    if (length <= space - recordStart + 2 || end > data.length || data[end - 1] != 0x0a) {
      throw const ZCodecException('Invalid PAX record bounds');
    }
    final Uint8List content = Uint8List.sublistView(data, space + 1, end - 1);
    final int equals = content.indexOf(0x3d);
    if (equals <= 0) {
      throw const ZCodecException('Invalid PAX key-value record');
    }
    final String key = utf8.decode(Uint8List.sublistView(content, 0, equals));
    final String value = utf8.decode(Uint8List.sublistView(content, equals + 1));
    result[key] = value;
    offset = end;
  }
  return result;
}

/// Decodes a GNU long-name or long-link metadata payload.
String _decodeGnuLongText(Uint8List data) {
  int end = data.indexOf(0);
  if (end < 0) {
    end = data.length;
  }
  while (end > 0 && data[end - 1] == 0x0a) {
    end--;
  }
  final Uint8List value = Uint8List.sublistView(data, 0, end);
  try {
    return utf8.decode(value);
  } on FormatException {
    return latin1.decode(value);
  }
}

/// Converts a PAX decimal timestamp to a UTC [DateTime].
DateTime _decodePaxTime(String value) {
  final double seconds = double.parse(value);
  if (!seconds.isFinite) {
    throw const ZCodecException('Invalid non-finite PAX timestamp');
  }
  return DateTime.fromMicrosecondsSinceEpoch((seconds * 1000000).round(), isUtc: true);
}

/// Converts [value] to the shortest practical PAX timestamp.
String _encodePaxTime(DateTime value) {
  final int microseconds = value.toUtc().microsecondsSinceEpoch;
  final bool negative = microseconds < 0;
  final int magnitude = microseconds.abs();
  final int seconds = magnitude ~/ 1000000;
  final int remainder = magnitude.remainder(1000000);
  if (remainder == 0) {
    return negative ? '-$seconds' : '$seconds';
  }
  final String fraction = remainder.toString().padLeft(6, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$seconds.$fraction';
}

/// Returns the final path component of [path].
String _tarBaseName(String path) {
  final List<String> components = path.split('/');
  for (int index = components.length - 1; index >= 0; index--) {
    if (components[index].isNotEmpty) {
      return components[index];
    }
  }
  return 'entry';
}

/// Validates a nonempty TAR path without imposing extraction policy.
void _validateTarPath(String path, {required String label}) {
  if (path.isEmpty || path.contains('\u0000')) {
    throw ArgumentError.value(path, label, 'TAR paths must be nonempty and must not contain NUL');
  }
}

/// Whether [path] is relative and contains no parent traversal component.
bool _hasSafeTarPath(String path) {
  if (path.startsWith('/') || path.startsWith(r'\')) {
    return false;
  }
  final List<String> components = path.replaceAll(r'\', '/').split('/');
  return !components.contains('..') && (components.isEmpty || !components.first.contains(':'));
}

/// Returns [length] rounded up to the next TAR block boundary.
int _tarPaddedLength(int length) => ((length + _tarBlockSize - 1) ~/ _tarBlockSize) * _tarBlockSize;
