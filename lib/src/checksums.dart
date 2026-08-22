import 'dart:typed_data';

/// Computes the Adler-32 checksum used by zlib streams.
int adler32(List<int> bytes) {
  const int modulus = 65521;
  int first = 1;
  int second = 0;
  int offset = 0;
  while (offset < bytes.length) {
    final int end = (offset + 5552).clamp(0, bytes.length);
    for (; offset < end; offset++) {
      first += bytes[offset] & 0xff;
      second += first;
    }
    first %= modulus;
    second %= modulus;
  }
  return ((second << 16) | first) & 0xffffffff;
}

/// Computes the CRC-32 checksum used by ZIP archives.
int crc32(List<int> bytes) {
  final Crc32Accumulator accumulator = Crc32Accumulator()..add(bytes);
  return accumulator.value;
}

/// Accumulates a CRC-32 checksum over multiple byte chunks.
final class Crc32Accumulator {
  /// In-progress CRC state before its final XOR.
  int _state = 0xffffffff;

  /// Creates an accumulator at the standard CRC-32 initial value.
  Crc32Accumulator();

  /// Current finalized checksum without consuming the accumulator.
  int get value => (_state ^ 0xffffffff) & 0xffffffff;

  /// Incorporates [bytes] into the checksum.
  void add(List<int> bytes) {
    for (final int byte in bytes) {
      _state = crc32UpdateByte(_state, byte);
    }
  }
}

/// Advances a raw CRC-32 [state] by one [byte].
int crc32UpdateByte(int state, int byte) => _crcTable[(state ^ byte) & 0xff] ^ (state >>> 8);

/// Precomputed CRC-32 state transition table.
final Uint32List _crcTable = Uint32List.fromList(<int>[
  for (int index = 0; index < 256; index++) _crcTableEntry(index),
]);

/// Computes one entry of the CRC-32 transition table.
int _crcTableEntry(int index) {
  int value = index;
  for (int bit = 0; bit < 8; bit++) {
    value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
}
