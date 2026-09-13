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
  if (bytes is Uint8List) {
    return _crc32UpdateBytes(state, bytes);
  }
  int result = state;
  for (int index = 0; index < bytes.length; index++) {
    result = _crcTable[(result ^ bytes[index]) & 0xff] ^ (result >>> 8);
  }
  return result;
}

/// Advances [state] over a typed buffer using the slicing-by-8 technique.
///
/// Each iteration folds eight bytes through eight derived tables. The two
/// halves are combined as 32-bit words so that every operation stays exact on
/// the Web.
int _crc32UpdateBytes(int state, Uint8List bytes) {
  final Uint32List table = _crcTable;
  int result = state;
  int index = 0;
  for (; index + 8 <= bytes.length; index += 8) {
    final int low = result ^ (bytes[index] | (bytes[index + 1] << 8) | (bytes[index + 2] << 16) | (bytes[index + 3] << 24));
    final int high = bytes[index + 4] | (bytes[index + 5] << 8) | (bytes[index + 6] << 16) | (bytes[index + 7] << 24);
    result =
        table[1792 + (low & 0xff)] ^
        table[1536 + ((low >>> 8) & 0xff)] ^
        table[1280 + ((low >>> 16) & 0xff)] ^
        table[1024 + (low >>> 24)] ^
        table[768 + (high & 0xff)] ^
        table[512 + ((high >>> 8) & 0xff)] ^
        table[256 + ((high >>> 16) & 0xff)] ^
        table[high >>> 24];
  }
  for (; index < bytes.length; index++) {
    result = table[(result ^ bytes[index]) & 0xff] ^ (result >>> 8);
  }
  return result;
}

/// Precomputed CRC-32 transition tables for slicing-by-8.
///
/// The first 256 entries are the classic byte table. Entries `256 * k + n`
/// advance the state of byte `n` through `k` further zero bytes.
final Uint32List _crcTable = _buildCrcTable();

/// Builds the eight concatenated CRC-32 tables.
Uint32List _buildCrcTable() {
  final Uint32List table = Uint32List(256 * 8);
  for (int index = 0; index < 256; index++) {
    int value = index;
    for (int bit = 0; bit < 8; bit++) {
      value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value;
  }
  for (int index = 256; index < table.length; index++) {
    final int previous = table[index - 256];
    table[index] = table[previous & 0xff] ^ (previous >>> 8);
  }
  return table;
}
