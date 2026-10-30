part of 'package:zcodec/src/zstd.dart';

/// Standard Zstandard frame signature.
const int _zstdMagic = 0xfd2fb528;

/// Maximum encoded and decoded block size specified by RFC 8878.
const int _zstdBlockBytes = 128 * 1024;

/// Literal-length extra-bit widths from RFC 8878 table 16.
const List<int> _zstdLiteralBits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

/// Match-length extra-bit widths from RFC 8878 table 17.
final List<int> _zstdMatchBits = List.unmodifiable([...List<int>.filled(32, 0), 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);

/// Expands contiguous length ranges into their initial values.
List<int> _zstdBaselines(List<int> widths, int first) {
  final List<int> values = [];
  int next = first;
  for (final int width in widths) {
    values.add(next);
    next += 1 << width;
  }
  return List.unmodifiable(values);
}

/// Minimum literal length for each code.
final List<int> _zstdLiteralBase = _zstdBaselines(_zstdLiteralBits, 0);

/// Minimum match length for each code.
final List<int> _zstdMatchBase = _zstdBaselines(_zstdMatchBits, 3);

/// Predefined literal-length probabilities from RFC 8878 section 3.1.1.3.2.2.
final _ZstdEntropyTable _zstdLiteralTable = _ZstdEntropyTable(
  accuracy: 6,
  probabilities: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1],
);

/// Predefined match-length probabilities from RFC 8878 section 3.1.1.3.2.2.
final _ZstdEntropyTable _zstdMatchTable = _ZstdEntropyTable(
  accuracy: 6,
  probabilities: [1, 4, 3, 2, 2, 2, 2, 2, 2, ...List<int>.filled(37, 1), ...List<int>.filled(7, -1)],
);

/// Predefined offset probabilities from RFC 8878 section 3.1.1.3.2.2.
final _ZstdEntropyTable _zstdOffsetTable = _ZstdEntropyTable(
  accuracy: 5,
  probabilities: [1, 1, 1, 1, 1, 1, 2, 2, 2, ...List<int>.filled(15, 1), -1, -1, -1, -1, -1],
);
