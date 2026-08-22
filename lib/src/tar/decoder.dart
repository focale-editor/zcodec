part of '../tar.dart';

/// Parses POSIX ustar, GNU long-name, and PAX TAR archives.
final class TarDecoder {
  /// Resource limits applied before entry payloads are exposed.
  final TarLimits limits;

  /// Creates a TAR decoder using [limits] for untrusted archives.
  const TarDecoder({this.limits = const TarLimits()});

  /// Decodes [input], optionally validating every physical header checksum.
  TarArchive decode(List<int> input, {bool verifyChecksum = true}) {
    final Uint8List bytes = input is Uint8List ? input : Uint8List.fromList(input);
    try {
      return _decode(bytes, verifyChecksum: verifyChecksum);
    } on ZCodecException {
      rethrow;
    } on Object catch (error) {
      throw ZCodecException('Invalid TAR archive: $error');
    }
  }

  /// Parses one validated TAR byte buffer.
  TarArchive _decode(Uint8List bytes, {required bool verifyChecksum}) {
    if (bytes.length < _tarBlockSize || bytes.length % _tarBlockSize != 0) {
      throw const ZCodecException('TAR archive length is not a multiple of 512 bytes');
    }
    final List<TarEntry> entries = <TarEntry>[];
    final Map<String, String> globalPax = <String, String>{};
    Map<String, String> localPax = <String, String>{};
    String? longName;
    String? longLink;
    int totalSize = 0;
    int offset = 0;
    while (offset < bytes.length) {
      final Uint8List block = Uint8List.sublistView(bytes, offset, offset + _tarBlockSize);
      if (_isZeroTarBlock(block)) {
        if (localPax.isNotEmpty || longName != null || longLink != null) {
          throw const ZCodecException('TAR archive ends after unattached metadata');
        }
        for (int index = offset; index < bytes.length; index++) {
          if (bytes[index] != 0) {
            throw const ZCodecException('Unexpected data after the TAR end marker');
          }
        }
        return TarArchive(entries: entries);
      }
      final _TarHeader header = _parseTarHeader(bytes, offset, verifyChecksum: verifyChecksum);
      offset += _tarBlockSize;
      if (header.typeFlag == 0x78 || header.typeFlag == 0x67 || header.typeFlag == 0x4c || header.typeFlag == 0x4b) {
        if (header.size < 0 || header.size > limits.maxMetadataBytes) {
          throw ZCodecException('TAR metadata exceeds the ${limits.maxMetadataBytes}-byte limit');
        }
        final Uint8List metadata = _readTarPayload(bytes, offset, header.size);
        offset += _tarPaddedLength(header.size);
        if (header.typeFlag == 0x78) {
          localPax.addAll(_parsePaxHeaders(metadata));
        } else if (header.typeFlag == 0x67) {
          _applyPaxRecords(globalPax, _parsePaxHeaders(metadata));
        } else if (header.typeFlag == 0x4c) {
          longName = _decodeGnuLongText(metadata);
        } else {
          longLink = _decodeGnuLongText(metadata);
        }
        continue;
      }
      if (header.typeFlag == 0x53) {
        throw const ZCodecException('Legacy GNU sparse TAR entries are not supported');
      }
      if (header.mode < 0 || header.deviceMajor < 0 || header.deviceMinor < 0) {
        throw const ZCodecException('TAR mode and device numbers must not be negative');
      }
      if (entries.length >= limits.maxEntries) {
        throw ZCodecException('TAR archive exceeds the ${limits.maxEntries}-entry limit');
      }
      final Map<String, String> pax = Map<String, String>.from(globalPax);
      _applyPaxRecords(pax, localPax);
      if (pax.keys.any((key) => key.startsWith('GNU.sparse.'))) {
        throw const ZCodecException('GNU sparse PAX entries are not supported');
      }
      final String name = pax['path'] ?? longName ?? header.name;
      _validateTarPath(name, label: 'entry name');
      final String linkName = pax['linkpath'] ?? longLink ?? header.linkName;
      if (linkName.contains('\u0000')) {
        throw const ZCodecException('TAR link target contains NUL');
      }
      final int size = _readPaxInteger(pax, 'size') ?? header.size;
      final int userId = _readPaxInteger(pax, 'uid') ?? header.userId;
      final int groupId = _readPaxInteger(pax, 'gid') ?? header.groupId;
      if (size < 0 || userId < 0 || groupId < 0) {
        throw const ZCodecException('TAR size and owner identifiers must not be negative');
      }
      if (size > limits.maxEntryBytes) {
        throw ZCodecException('TAR entry exceeds the ${limits.maxEntryBytes}-byte limit');
      }
      if (size > limits.maxTotalBytes - totalSize) {
        throw ZCodecException('TAR archive exceeds the ${limits.maxTotalBytes}-byte stored-size limit');
      }
      final Uint8List data = _readTarPayload(bytes, offset, size);
      offset += _tarPaddedLength(size);
      totalSize += size;
      final DateTime modified = pax.containsKey('mtime') ? _decodePaxTime(pax['mtime']!) : DateTime.fromMillisecondsSinceEpoch(header.modifiedSeconds * 1000, isUtc: true);
      entries.add(
        TarEntry._decoded(
          name: name,
          type: _entryTypeFor(header.typeFlag),
          typeFlag: header.typeFlag,
          data: data,
          mode: header.mode,
          userId: userId,
          groupId: groupId,
          modified: modified,
          userName: pax['uname'] ?? header.userName,
          groupName: pax['gname'] ?? header.groupName,
          linkName: linkName,
          deviceMajor: header.deviceMajor,
          deviceMinor: header.deviceMinor,
          paxHeaders: pax,
        ),
      );
      localPax = <String, String>{};
      longName = null;
      longLink = null;
    }
    throw const ZCodecException('TAR archive is missing its zero-block end marker');
  }

  /// Returns a zero-copy payload view at [offset] with the declared [size].
  Uint8List _readTarPayload(Uint8List bytes, int offset, int size) {
    if (size < 0 || offset < 0 || offset > bytes.length || size > bytes.length - offset) {
      throw const ZCodecException('Truncated TAR entry payload');
    }
    final int padded = _tarPaddedLength(size);
    if (padded > bytes.length - offset) {
      throw const ZCodecException('Truncated TAR entry padding');
    }
    return Uint8List.sublistView(bytes, offset, offset + size);
  }

  /// Applies [updates], treating empty PAX values as deletions.
  void _applyPaxRecords(Map<String, String> target, Map<String, String> updates) {
    for (final MapEntry<String, String> update in updates.entries) {
      if (update.value.isEmpty) {
        target.remove(update.key);
      } else {
        target[update.key] = update.value;
      }
    }
  }

  /// Reads optional decimal PAX integer [key].
  int? _readPaxInteger(Map<String, String> headers, String key) {
    final String? value = headers[key];
    if (value == null) {
      return null;
    }
    final int? parsed = int.tryParse(value);
    if (parsed == null) {
      throw ZCodecException('Invalid PAX $key value');
    }
    return parsed;
  }
}
