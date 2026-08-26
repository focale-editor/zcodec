part of 'package:zcodec/src/checksums.dart';

/// Computes the CRC-32 checksum used by GZIP and ZIP.
int crc32(List<int> bytes) => (_crc32Update(0xffffffff, bytes) ^ 0xffffffff) & 0xffffffff;

/// Accumulates a CRC-32 checksum over several byte chunks.
final class Crc32Accumulator {
  /// In-progress CRC state before its final XOR.
  int _state = 0xffffffff;

  /// Creates an accumulator at the standard CRC-32 initial value.
  Crc32Accumulator();

  /// Current finalized checksum, which leaves the accumulator usable.
  int get value => (_state ^ 0xffffffff) & 0xffffffff;

  /// Incorporates [bytes] into the checksum.
  void add(List<int> bytes) => _state = _crc32Update(_state, bytes);
}

/// Advances a raw CRC-32 [state] by one [byte].
int crc32UpdateByte(int state, int byte) => _crcTable[(state ^ byte) & 0xff] ^ (state >>> 8);

/// Advances a raw CRC-32 [state] by every byte of [bytes].
int _crc32Update(int state, List<int> bytes) {
  int result = state;
  for (int index = 0; index < bytes.length; index++) {
    result = _crcTable[(result ^ bytes[index]) & 0xff] ^ (result >>> 8);
  }
  return result;
}

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
