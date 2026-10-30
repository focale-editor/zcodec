part of 'package:zcodec/src/zstd.dart';

/// Compresses and decompresses RFC 8878 Zstandard frames without dependencies.
///
/// Chunked conversion buffers one input until close, like the base ByteCodec.
/// Decode accepts concatenated and skippable frames and verifies checksums.
final class ZstdCodec extends ByteCodec {
  /// Compression effort from zero (stored blocks) through nine.
  final int level;

  /// Whether the encoder includes an XXH64 content checksum.
  final bool checksum;

  /// Maximum total decoded bytes across concatenated frames.
  final int? maxOutputBytes;

  /// Maximum history window advertised by any frame.
  final int maxWindowBytes;

  /// Maximum complete encoded input size, also limiting skippable data.
  final int? maxInputBytes;

  /// Creates a reusable codec with independently bounded decoding.
  const ZstdCodec({this.level = defaultCompressionLevel, this.checksum = true, this.maxOutputBytes, this.maxWindowBytes = 128 * 1024 * 1024, this.maxInputBytes});

  @override
  ZstdEncoder get encoder => ZstdEncoder(level: level, checksum: checksum);

  @override
  ZstdDecoder get decoder => ZstdDecoder(maxOutputBytes: maxOutputBytes, maxWindowBytes: maxWindowBytes, maxInputBytes: maxInputBytes);
}

/// Compresses bytes into one Zstandard frame with an optional content checksum.
final class ZstdEncoder extends ByteEncoder {
  /// Compression effort from zero (stored blocks) through nine.
  final int level;

  /// Whether an XXH64 content checksum is emitted.
  final bool checksum;

  /// Creates a pure Dart Zstandard encoder.
  const ZstdEncoder({this.level = defaultCompressionLevel, this.checksum = true});

  @override
  Uint8List convert(List<int> input) {
    validateCompressionLevel(level);
    return _encodeZstd(bytes: asBytes(input), level: level, checksum: checksum);
  }
}

/// Decodes all Zstandard frames, rejecting malformed or truncated input.
///
/// Checksums are always verified when present. Dictionaries may be raw history
/// bytes or trained Zstandard dictionaries. No partial result is returned on
/// failure. Chunked conversion buffers input until close.
final class ZstdDecoder extends ByteDecoder {
  /// Maximum aggregate output across all concatenated frames.
  final int? maxOutputBytes;

  /// Maximum per-frame history window, in addition to dictionary storage.
  final int maxWindowBytes;

  /// Optional limit on complete compressed input.
  final int? maxInputBytes;

  /// Owned dictionary bytes, if explicitly provided.
  final Uint8List? _dictionary;

  /// Creates a decoder with an immutable optional dictionary snapshot.
  ZstdDecoder({this.maxOutputBytes, this.maxWindowBytes = 128 * 1024 * 1024, this.maxInputBytes, List<int>? dictionary})
    : _dictionary = dictionary == null ? null : Uint8List.fromList(asBytes(dictionary));

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) => _ZstdDecodingSink(decoder: this, output: sink);

  @override
  Uint8List convert(List<int> input) {
    if ((maxOutputBytes != null && maxOutputBytes! < 0) || (maxInputBytes != null && maxInputBytes! < 0) || maxWindowBytes <= 0 || maxWindowBytes > 0x80000000) {
      throw ArgumentError('Invalid Zstandard resource limits');
    }
    if (maxInputBytes case final int limit when input.length > limit) {
      throw const ZCodecException('Zstandard input exceeds the byte limit');
    }
    final ByteReader reader = ByteReader(asBytes(input));
    final _ZstdOutput output = _ZstdOutput(maximum: maxOutputBytes ?? 0x7fffffff);
    if (reader.remaining == 0) {
      throw const ZCodecException('Zstandard input contains no frame');
    }
    while (reader.remaining != 0) {
      final int magic = reader.readUint32();
      if (magic >= 0x184d2a50 && magic <= 0x184d2a5f) {
        reader.skip(reader.readUint32());
      } else if (magic == _zstdMagic) {
        _ZstdFrame(maxWindowBytes: maxWindowBytes, dictionary: _dictionary).decode(reader: reader, output: output);
      } else {
        throw const ZCodecException('Invalid Zstandard frame magic');
      }
    }
    return output.finish();
  }
}
