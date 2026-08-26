part of 'package:zcodec/src/zip.dart';

/// Encodes and decodes ZIP archives in pure Dart.
///
/// ```dart
/// final bytes = const ZipCodec().encode(archive);
/// final decoded = const ZipCodec().decode(bytes);
/// ```
///
/// ZIP64 records are selected automatically when a count, size, offset, or
/// disk number reaches its classic ZIP limit.
final class ZipCodec extends BinaryCodec<ZipArchive> {
  /// Compression effort from 0 through 9 for DEFLATE entries.
  final int level;

  /// Resource limits applied while parsing untrusted archives.
  final ZipLimits limits;

  /// Password lookup consulted for encrypted entries.
  final ZipPasswordProvider? passwordProvider;

  /// Random-byte source used for encryption headers and salts.
  final ZipRandomBytes? randomBytes;

  /// Whether every entry and end record uses ZIP64.
  final bool forceZip64;

  /// Creates a ZIP codec.
  const ZipCodec({
    this.level = defaultCompressionLevel,
    this.limits = const ZipLimits(),
    this.passwordProvider,
    this.randomBytes,
    this.forceZip64 = false,
  });

  @override
  ZipEncoder get encoder => ZipEncoder(level: level, passwordProvider: passwordProvider, randomBytes: randomBytes, forceZip64: forceZip64);

  @override
  ZipDecoder get decoder => ZipDecoder(limits: limits, passwordProvider: passwordProvider);

  /// Encodes [archive] into ordered split ZIP volumes of [volumeSize] bytes.
  List<Uint8List> encodeVolumes(ZipArchive archive, {required int volumeSize}) => encoder.convertToVolumes(archive, volumeSize: volumeSize);

  /// Decodes ordered split or spanned ZIP [volumes].
  ZipArchive decodeVolumes(List<List<int>> volumes) => decoder.convertVolumes(volumes);
}
