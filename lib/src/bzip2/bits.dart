part of 'package:zcodec/src/bzip2.dart';

/// Signals that a transactional block parse needs more input.
final class _NeedBzipInput implements Exception {
  /// Creates an incomplete-input marker.
  const _NeedBzipInput();
}

/// Reads BZIP2's most-significant-bit-first fields.
final class _BzipReader {
  /// Pending encoded bytes.
  final Uint8List bytes;

  /// Exclusive available byte boundary.
  final int end;

  /// Absolute bit position in [bytes].
  int position;

  /// Creates a reader at an arbitrary bit boundary.
  _BzipReader(this.bytes, this.end, this.position);

  /// Reads up to 32 bits with identical VM and JavaScript results.
  int read(int count) {
    if (position + count > end * 8) {
      throw const _NeedBzipInput();
    }
    int value = 0;
    int remaining = count;
    while (remaining > 0) {
      final int take = remaining.clamp(0, 8 - (position & 7));
      value = value * (1 << take) + ((bytes[position ~/ 8] >> (8 - (position & 7) - take)) & ((1 << take) - 1));
      position += take;
      remaining -= take;
    }
    return value;
  }
}

/// Writes MSB-first fields while preserving partial bytes between blocks.
final class _BzipWriter {
  /// Destination of complete encoded bytes.
  final Sink<List<int>> output;

  /// Complete bytes awaiting delivery.
  final BytesBuilder bytes = BytesBuilder();

  /// Incomplete byte accumulator.
  int value = 0;

  /// Number of populated bits in [value].
  int bits = 0;

  /// Creates a bit writer.
  _BzipWriter(this.output);

  /// Appends one unsigned field.
  void write(int count, int number) {
    for (int shift = count - 1; shift >= 0; shift--) {
      value = (value << 1) | ((number >>> shift) & 1);
      if (++bits == 8) {
        bytes.addByte(value);
        value = bits = 0;
      }
    }
  }

  /// Delivers completed bytes without changing bit alignment.
  void flush() {
    if (bytes.isNotEmpty) {
      output.add(bytes.takeBytes());
    }
  }

  /// Pads the final byte with zero bits.
  void finish() {
    if (bits > 0) {
      write(8 - bits, 0);
    }
    flush();
  }
}

/// BZIP2 uses the non-reflected CRC-32 polynomial, unlike GZIP.
final Uint32List _bzipCrcTable = Uint32List.fromList(
  List.generate(256, (index) {
    int value = index << 24;
    for (int bit = 0; bit < 8; bit++) {
      value = ((value << 1) ^ (value & 0x80000000 != 0 ? 0x04c11db7 : 0)) & 0xffffffff;
    }
    return value;
  }),
);

/// Advances a non-finalized BZIP2 checksum.
int _bzipUpdate(int crc, int byte) => (((crc << 8) & 0xffffffff) ^ _bzipCrcTable[((crc >>> 24) ^ byte) & 255]) & 0xffffffff;

/// Folds one finalized block checksum into the member checksum.
int _bzipCombine(int combined, int block) => (((combined << 1) | (combined >>> 31)) ^ block) & 0xffffffff;
