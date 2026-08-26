part of 'package:zcodec/src/codecs.dart';

/// Default compression effort shared by every ZCodec compressor.
///
/// It matches the zlib default: a balance between speed and ratio.
const int defaultCompressionLevel = 6;

/// Rejects a compression [level] outside the RFC 1951 range of 0 through 9.
///
/// Codecs keep `const` constructors, so an out-of-range level is reported when
/// a conversion runs rather than when the codec is created.
void validateCompressionLevel(int level) {
  if (level < 0 || level > 9) {
    throw RangeError.range(level, 0, 9, 'level');
  }
}
