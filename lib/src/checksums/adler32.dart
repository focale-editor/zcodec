part of 'package:zcodec/src/checksums.dart';

/// Largest prime below 65536, the Adler-32 modulus.
const int _adlerModulus = 65521;

/// Longest run that cannot overflow the running sums before reduction.
const int _adlerBlock = 5552;

/// Computes the Adler-32 checksum used by zlib streams.
int adler32(List<int> bytes) => (Adler32Accumulator()..add(bytes)).value;

/// Accumulates Adler-32 across independently delivered byte chunks.
final class Adler32Accumulator {
  /// First modular sum.
  int _first = 1;

  /// Second modular sum.
  int _second = 0;

  /// Creates an accumulator with the canonical empty checksum.
  Adler32Accumulator();

  /// Current checksum without resetting the accumulator.
  int get value => ((_second << 16) | _first) & 0xffffffff;

  /// Incorporates all [bytes] without overflowing the portable integer range.
  void add(List<int> bytes) {
    int first = _first;
    int second = _second;
    int offset = 0;
    while (offset < bytes.length) {
      final int end = offset + _adlerBlock <= bytes.length ? offset + _adlerBlock : bytes.length;
      for (; offset < end; offset++) {
        first += bytes[offset] & 0xff;
        second += first;
      }
      first %= _adlerModulus;
      second %= _adlerModulus;
    }
    _first = first;
    _second = second;
  }
}
