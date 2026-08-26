part of 'package:zcodec/src/tar.dart';

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
///
/// The seconds and the fraction are parsed separately: a PAX timestamp can
/// carry more significant digits than a double keeps, so parsing it as a
/// floating-point number would quietly shift recent timestamps.
DateTime _decodePaxTime(String value) {
  final int separator = value.indexOf('.');
  final String secondsText = separator < 0 ? value : value.substring(0, separator);
  final int? seconds = int.tryParse(secondsText);
  if (seconds == null) {
    throw const ZCodecException('Invalid PAX timestamp');
  }
  int microseconds = 0;
  if (separator >= 0) {
    final String fraction = value.substring(separator + 1);
    if (fraction.isEmpty || !_isDecimalText(fraction)) {
      throw const ZCodecException('Invalid PAX timestamp');
    }
    // Sub-microsecond digits are dropped because DateTime cannot hold them.
    microseconds = int.parse(fraction.padRight(6, '0').substring(0, 6));
  }
  final bool negative = secondsText.startsWith('-');
  return DateTime.fromMicrosecondsSinceEpoch(seconds * 1000000 + (negative ? -microseconds : microseconds), isUtc: true);
}

/// Whether [value] contains only decimal digits.
bool _isDecimalText(String value) {
  for (int index = 0; index < value.length; index++) {
    final int unit = value.codeUnitAt(index);
    if (unit < 0x30 || unit > 0x39) {
      return false;
    }
  }
  return true;
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
