part of 'package:zcodec/src/gzip.dart';

/// Maximum number of GZIP members decoded from one file by default.
const int defaultMaxGzipMembers = 10000;

/// Encodes and decodes RFC 1952 GZIP files in pure Dart.
///
/// Encoding produces a single member; decoding concatenates the payload of
/// every member, which is how GZIP files built with `cat` are meant to be
/// read. Use [GzipMemberCodec] to keep each member and its metadata.
final class GzipCodec extends ByteCodec {
  /// Compression effort from 0 through 9.
  final int level;

  /// Metadata written to the encoded member header.
  final GzipHeader header;

  /// Optional ceiling on the total number of decoded bytes.
  final int? maxOutputBytes;

  /// Maximum number of members accepted from one file.
  final int maxMembers;

  /// Creates a GZIP codec.
  const GzipCodec({
    this.level = defaultCompressionLevel,
    this.header = const GzipHeader(),
    this.maxOutputBytes,
    this.maxMembers = defaultMaxGzipMembers,
  });

  @override
  GzipEncoder get encoder => GzipEncoder(level: level, header: header);

  @override
  GzipDecoder get decoder => GzipDecoder(maxOutputBytes: maxOutputBytes, maxMembers: maxMembers);
}

/// Compresses bytes into one GZIP member.
final class GzipEncoder extends ByteEncoder {
  /// Compression effort from 0 through 9.
  final int level;

  /// Metadata written to the member header.
  final GzipHeader header;

  /// Creates a GZIP encoder.
  const GzipEncoder({this.level = defaultCompressionLevel, this.header = const GzipHeader()});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    validateCompressionLevel(level);
    header.validate();
    return _GzipEncodingSink(sink, level, header);
  }

  @override
  Uint8List convert(List<int> input) {
    validateCompressionLevel(level);
    header.validate();
    final ByteWriter output = ByteWriter();
    _encodeMember(output, GzipMember._decoded(data: asBytes(input), header: header), level);
    return output.takeBytes();
  }
}

/// Decompresses every member of a GZIP file and concatenates the results.
final class GzipDecoder extends ByteDecoder {
  /// Optional ceiling on the total number of decoded bytes.
  final int? maxOutputBytes;

  /// Maximum number of members accepted from one file.
  final int maxMembers;

  /// Creates a GZIP decoder.
  const GzipDecoder({this.maxOutputBytes, this.maxMembers = defaultMaxGzipMembers});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _GzipDecodingSink(sink, maxOutputBytes, maxMembers);

  @override
  Uint8List convert(List<int> input) {
    if (maxOutputBytes != null && maxOutputBytes! < 0) {
      throw RangeError.value(maxOutputBytes!, 'maxOutputBytes', 'Must not be negative');
    }
    if (maxMembers <= 0) {
      throw RangeError.value(maxMembers, 'maxMembers', 'Must be positive');
    }
    final Uint8List bytes = asBytes(input);
    if (bytes.isEmpty) {
      throw const ZCodecException('A GZIP file must contain at least one member');
    }
    final BytesBuilder output = BytesBuilder();
    int offset = 0;
    int count = 0;
    int total = 0;
    while (offset < bytes.length) {
      if (count++ >= maxMembers) {
        throw ZCodecException('GZIP file exceeds the $maxMembers-member limit');
      }
      final _DecodedGzipMember decoded = _decodeMember(bytes, offset, maxOutputBytes == null ? null : maxOutputBytes! - total);
      offset = decoded.nextOffset;
      if (count == 1 && offset == bytes.length) {
        return decoded.member.data;
      }
      total += decoded.member.data.length;
      output.add(decoded.member.data);
    }
    return output.takeBytes();
  }
}
