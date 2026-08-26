part of 'package:zcodec/src/gzip.dart';

/// Optional metadata stored in one RFC 1952 member header.
final class GzipHeader {
  /// Original modification time, or `null` when the header stores zero.
  final DateTime? modified;

  /// Optional original file name, which must be representable as ISO-8859-1.
  final String? name;

  /// Optional human-readable comment, encoded as ISO-8859-1.
  final String? comment;

  /// Optional raw GZIP extra-field bytes.
  final List<int> extra;

  /// Operating-system identifier, where 255 means unknown.
  final int operatingSystem;

  /// Whether the member advertises probably textual data.
  final bool isText;

  /// Whether the member includes a header CRC-16.
  final bool headerChecksum;

  /// Compression-specific extra flags, or zero to derive them from the level.
  final int compressionFlags;

  /// Creates GZIP member metadata.
  const GzipHeader({
    this.modified,
    this.name,
    this.comment,
    this.extra = const <int>[],
    this.operatingSystem = 255,
    this.isText = false,
    this.headerChecksum = false,
    this.compressionFlags = 0,
  });

  /// Rejects metadata that cannot be represented in a GZIP header.
  void validate() {
    if (operatingSystem < 0 || operatingSystem > 255) {
      throw RangeError.range(operatingSystem, 0, 255, 'operatingSystem');
    }
    if (compressionFlags < 0 || compressionFlags > 255) {
      throw RangeError.range(compressionFlags, 0, 255, 'compressionFlags');
    }
    if (extra.length > 0xffff) {
      throw ArgumentError.value(extra.length, 'extra', 'A GZIP extra field cannot exceed 65535 bytes');
    }
    _encodeHeaderText(name, label: 'name');
    _encodeHeaderText(comment, label: 'comment');
  }
}

/// Represents one RFC 1952 GZIP member and its metadata.
final class GzipMember {
  /// Uncompressed member bytes.
  final Uint8List data;

  /// Metadata stored in the member header.
  final GzipHeader header;

  /// Creates a member backed by a copy of [data].
  GzipMember({required List<int> data, this.header = const GzipHeader()}) : data = Uint8List.fromList(data) {
    header.validate();
  }

  /// Creates a decoded member that adopts [data] without copying it.
  const GzipMember._decoded({required this.data, required this.header});

  /// Original modification time, or `null` when the header stores zero.
  DateTime? get modified => header.modified;

  /// Optional original file name.
  String? get name => header.name;

  /// Optional human-readable comment.
  String? get comment => header.comment;

  /// Optional raw GZIP extra-field bytes.
  List<int> get extra => header.extra;

  /// Operating-system identifier stored in the member header.
  int get operatingSystem => header.operatingSystem;

  /// Whether the member advertises probably textual data.
  bool get isText => header.isText;

  /// Whether the member includes a header CRC-16.
  bool get headerChecksum => header.headerChecksum;

  /// Compression-specific extra flags stored in the member header.
  int get compressionFlags => header.compressionFlags;
}
