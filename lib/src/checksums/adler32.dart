part of 'package:zcodec/src/checksums.dart';

/// Largest prime below 65536, the Adler-32 modulus.
const int _adlerModulus = 65521;

/// Longest run that cannot overflow the running sums before reduction.
const int _adlerBlock = 5552;

/// Computes the Adler-32 checksum used by zlib streams.
int adler32(List<int> bytes) {
  int first = 1;
  int second = 0;
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
  return ((second << 16) | first) & 0xffffffff;
}
