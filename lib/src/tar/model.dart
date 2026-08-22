part of '../tar.dart';

/// Selects the semantic type of a TAR entry.
enum TarEntryType {
  /// A regular file.
  regular,

  /// A hard link whose target is stored in [TarEntry.linkName].
  hardLink,

  /// A symbolic link whose target is stored in [TarEntry.linkName].
  symbolicLink,

  /// A character device.
  characterDevice,

  /// A block device.
  blockDevice,

  /// A directory.
  directory,

  /// A FIFO special file.
  fifo,

  /// A POSIX contiguous file.
  contiguous,

  /// An unrecognized vendor-specific entry type.
  unknown,
}

/// Bounds resource use while parsing an untrusted TAR archive.
final class TarLimits {
  /// Maximum number of materialized archive entries.
  final int maxEntries;

  /// Maximum stored size accepted for any individual entry.
  final int maxEntryBytes;

  /// Maximum sum of all stored entry sizes.
  final int maxTotalBytes;

  /// Maximum size accepted for one PAX or GNU metadata payload.
  final int maxMetadataBytes;

  /// Creates TAR parsing limits suitable for ordinary source archives.
  const TarLimits({
    this.maxEntries = 100000,
    this.maxEntryBytes = 1024 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.maxMetadataBytes = 16 * 1024 * 1024,
  }) : assert(maxEntries >= 0, 'maxEntries must not be negative'),
       assert(maxEntryBytes >= 0, 'maxEntryBytes must not be negative'),
       assert(maxTotalBytes >= 0, 'maxTotalBytes must not be negative'),
       assert(maxMetadataBytes >= 0, 'maxMetadataBytes must not be negative');
}

/// Represents one file-system object described by a TAR archive.
final class TarEntry {
  /// Entry path, conventionally using forward slashes.
  final String name;

  /// Semantic entry type.
  final TarEntryType type;

  /// Raw TAR typeflag byte retained for unknown vendor extensions.
  final int typeFlag;

  /// Stored entry bytes.
  final Uint8List data;

  /// POSIX permission and special mode bits.
  final int mode;

  /// Numeric owner identifier.
  final int userId;

  /// Numeric group identifier.
  final int groupId;

  /// Last modification timestamp.
  final DateTime modified;

  /// Optional textual owner name.
  final String userName;

  /// Optional textual group name.
  final String groupName;

  /// Link target for hard-link and symbolic-link entries.
  final String linkName;

  /// Major device number for device entries.
  final int deviceMajor;

  /// Minor device number for device entries.
  final int deviceMinor;

  /// Effective PAX records associated with this entry.
  final Map<String, String> paxHeaders;

  /// Creates a TAR entry backed by copies of [data] and [paxHeaders].
  TarEntry({
    required this.name,
    List<int> data = const <int>[],
    this.type = TarEntryType.regular,
    int? typeFlag,
    this.mode = 0x1a4,
    this.userId = 0,
    this.groupId = 0,
    DateTime? modified,
    this.userName = '',
    this.groupName = '',
    this.linkName = '',
    this.deviceMajor = 0,
    this.deviceMinor = 0,
    Map<String, String> paxHeaders = const <String, String>{},
  }) : typeFlag = typeFlag ?? _typeFlagFor(type),
       data = Uint8List.fromList(data),
       modified = modified ?? DateTime.now(),
       paxHeaders = Map<String, String>.unmodifiable(paxHeaders) {
    _validateTarPath(name, label: 'entry name');
    if (this.typeFlag < 0 || this.typeFlag > 255) {
      throw RangeError.range(this.typeFlag, 0, 255, 'typeFlag');
    }
    if (mode < 0 || userId < 0 || groupId < 0 || deviceMajor < 0 || deviceMinor < 0) {
      throw ArgumentError('TAR numeric metadata must not be negative');
    }
    if ((type == TarEntryType.hardLink || type == TarEntryType.symbolicLink) && linkName.isEmpty) {
      throw ArgumentError.value(linkName, 'linkName', 'TAR link entries require a target');
    }
  }

  /// Creates a decoded entry backed directly by an archive data slice.
  TarEntry._decoded({
    required this.name,
    required this.type,
    required this.typeFlag,
    required this.data,
    required this.mode,
    required this.userId,
    required this.groupId,
    required this.modified,
    required this.userName,
    required this.groupName,
    required this.linkName,
    required this.deviceMajor,
    required this.deviceMinor,
    required Map<String, String> paxHeaders,
  }) : paxHeaders = Map<String, String>.unmodifiable(paxHeaders);

  /// Whether this entry denotes a directory.
  bool get isDirectory => type == TarEntryType.directory;

  /// Whether [name] is relative and cannot escape an extraction root.
  bool get hasSafePath => _hasSafeTarPath(name);

  /// Whether [linkName] is an extraction-safe relative link target.
  bool get hasSafeLinkTarget => linkName.isEmpty || _hasSafeTarPath(linkName);
}

/// Contains entries in their physical TAR order.
final class TarArchive {
  /// Materialized archive entries.
  final List<TarEntry> entries;

  /// Creates an archive from [entries].
  TarArchive({Iterable<TarEntry> entries = const <TarEntry>[]}) : entries = List<TarEntry>.unmodifiable(entries);

  /// Finds the first entry whose path equals [name].
  TarEntry? find(String name) {
    for (final TarEntry entry in entries) {
      if (entry.name == name) {
        return entry;
      }
    }
    return null;
  }
}
