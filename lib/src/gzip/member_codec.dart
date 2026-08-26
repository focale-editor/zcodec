part of 'package:zcodec/src/gzip.dart';

/// Encodes and decodes GZIP files while preserving per-member metadata.
///
/// Use [GzipCodec] when only the concatenated payload matters.
final class GzipMemberCodec extends BinaryCodec<List<GzipMember>> {
  /// Compression effort from 0 through 9.
  final int level;

  /// Optional ceiling on the total number of decoded bytes.
  final int? maxOutputBytes;

  /// Maximum number of members accepted from one file.
  final int maxMembers;

  /// Creates a GZIP member codec.
  const GzipMemberCodec({this.level = defaultCompressionLevel, this.maxOutputBytes, this.maxMembers = defaultMaxGzipMembers});

  @override
  GzipMemberEncoder get encoder => GzipMemberEncoder(level: level);

  @override
  GzipMemberDecoder get decoder => GzipMemberDecoder(maxOutputBytes: maxOutputBytes, maxMembers: maxMembers);
}

/// Serializes GZIP members into one concatenated GZIP file.
final class GzipMemberEncoder extends BinaryEncoder<List<GzipMember>> {
  /// Compression effort from 0 through 9.
  final int level;

  /// Creates a GZIP member encoder.
  const GzipMemberEncoder({this.level = defaultCompressionLevel});

  @override
  Uint8List convert(List<GzipMember> input) {
    validateCompressionLevel(level);
    if (input.isEmpty) {
      throw ArgumentError.value(input, 'input', 'A GZIP file must contain at least one member');
    }
    final ByteWriter output = ByteWriter();
    for (final GzipMember member in input) {
      _encodeMember(output, member, level);
    }
    return output.takeBytes();
  }
}

/// Parses every member of a GZIP file.
final class GzipMemberDecoder extends BinaryDecoder<List<GzipMember>> {
  /// Optional ceiling on the total number of decoded bytes.
  final int? maxOutputBytes;

  /// Maximum number of members accepted from one file.
  final int maxMembers;

  /// Creates a GZIP member decoder.
  const GzipMemberDecoder({this.maxOutputBytes, this.maxMembers = defaultMaxGzipMembers});

  @override
  List<GzipMember> convert(List<int> input) {
    final int? maximum = maxOutputBytes;
    if (maximum != null && maximum < 0) {
      throw RangeError.value(maximum, 'maxOutputBytes', 'Must not be negative');
    }
    if (maxMembers <= 0) {
      throw RangeError.value(maxMembers, 'maxMembers', 'Must be positive');
    }
    final Uint8List bytes = asBytes(input);
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
        final _DecodedGzipMember decoded = _decodeMember(bytes, offset, maximum == null ? null : maximum - totalOutput);
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
}
