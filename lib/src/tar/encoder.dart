part of 'package:zcodec/src/tar.dart';

/// Serializes POSIX ustar archives with automatic PAX extensions.
///
/// A PAX metadata entry is emitted only for the fields that do not fit the
/// classic ustar header, so archives stay readable by plain ustar tools
/// whenever possible.
final class TarEncoder extends BinaryEncoder<TarArchive> {
  /// Creates a stateless TAR encoder.
  const TarEncoder();

  /// Encodes [input] and terminates it with two zero blocks.
  @override
  Uint8List convert(TarArchive input) {
    final ByteWriter output = ByteWriter();
    for (final TarEntry entry in input.entries) {
      _encodeEntry(output, entry);
    }
    output.writeZeroes(_tarBlockSize * 2);
    return output.takeBytes();
  }

  /// Writes one [entry], preceded by a PAX header when required.
  void _encodeEntry(ByteWriter output, TarEntry entry) {
    final _TarPathFields path = _splitTarPath(entry.name);
    final Uint8List encodedLink = Uint8List.fromList(utf8.encode(entry.linkName));
    final Uint8List encodedUser = Uint8List.fromList(utf8.encode(entry.userName));
    final Uint8List encodedGroup = Uint8List.fromList(utf8.encode(entry.groupName));
    final int modifiedMicroseconds = entry.modified.toUtc().microsecondsSinceEpoch;
    final int modifiedSeconds = modifiedMicroseconds ~/ 1000000;
    final Map<String, String> pax = Map<String, String>.from(entry.paxHeaders);
    if (path.requiresPax || pax.containsKey('path')) {
      pax['path'] = entry.name;
    }
    if (encodedLink.length > 100 || pax.containsKey('linkpath')) {
      pax['linkpath'] = entry.linkName;
    }
    if (encodedUser.length > 32 || pax.containsKey('uname')) {
      pax['uname'] = entry.userName;
    }
    if (encodedGroup.length > 32 || pax.containsKey('gname')) {
      pax['gname'] = entry.groupName;
    }
    if (entry.data.length > 0x1ffffffff || pax.containsKey('size')) {
      pax['size'] = '${entry.data.length}';
    }
    if (entry.userId > 0x1fffff || pax.containsKey('uid')) {
      pax['uid'] = '${entry.userId}';
    }
    if (entry.groupId > 0x1fffff || pax.containsKey('gid')) {
      pax['gid'] = '${entry.groupId}';
    }
    if (modifiedMicroseconds.remainder(1000000) != 0 || modifiedSeconds < 0 || pax.containsKey('mtime')) {
      pax['mtime'] = _encodePaxTime(entry.modified);
    }
    if (pax.isNotEmpty) {
      _writePaxEntry(output, entry, pax);
    }
    final String storedLink = encodedLink.length <= 100 ? entry.linkName : '';
    output.writeBytes(
      _writeTarHeader(
        entry,
        storedName: entry.name,
        storedLinkName: storedLink,
        storedSize: entry.data.length,
        modifiedSeconds: modifiedSeconds,
        storedUserName: encodedUser.length <= 32 ? entry.userName : '',
        storedGroupName: encodedGroup.length <= 32 ? entry.groupName : '',
        pathFields: path,
      ),
    );
    _writeTarPayload(output, entry.data);
  }

  /// Writes one local PAX metadata entry for [owner].
  void _writePaxEntry(ByteWriter output, TarEntry owner, Map<String, String> headers) {
    final Uint8List payload = _encodePaxHeaders(headers);
    final String headerName = 'PaxHeaders/${_tarBaseName(owner.name)}';
    final TarEntry metadata = TarEntry(
      name: headerName,
      type: TarEntryType.unknown,
      typeFlag: 0x78,
      mode: owner.mode,
      userId: owner.userId,
      groupId: owner.groupId,
      modified: owner.modified,
    );
    output.writeBytes(
      _writeTarHeader(
        metadata,
        storedName: headerName,
        storedLinkName: '',
        storedSize: payload.length,
        modifiedSeconds: owner.modified.toUtc().millisecondsSinceEpoch ~/ 1000,
        typeFlag: 0x78,
      ),
    );
    _writeTarPayload(output, payload);
  }

  /// Writes [payload] followed by zero padding through a block boundary.
  void _writeTarPayload(ByteWriter output, Uint8List payload) {
    output.writeBytes(payload);
    output.writeZeroes(_tarPaddedLength(payload.length) - payload.length);
  }
}
