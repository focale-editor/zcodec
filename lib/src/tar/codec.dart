part of 'package:zcodec/src/tar.dart';

/// Encodes and decodes TAR archives in pure Dart.
///
/// TAR stores no compression of its own, so a `.tar.gz` file is this codec
/// fused with [GzipCodec]:
///
/// ```dart
/// final archive = const TarCodec().decode(const GzipCodec().decode(bytes));
/// ```
final class TarCodec extends BinaryCodec<TarArchive> {
  /// Resource limits applied while parsing untrusted archives.
  final TarLimits limits;

  /// Whether every physical header checksum is validated.
  final bool verifyChecksum;

  /// Creates a TAR codec.
  const TarCodec({this.limits = const TarLimits(), this.verifyChecksum = true});

  @override
  TarEncoder get encoder => const TarEncoder();

  @override
  TarDecoder get decoder => TarDecoder(limits: limits, verifyChecksum: verifyChecksum);
}
