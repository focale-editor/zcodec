part of 'package:zcodec/src/zstd.dart';

/// Modulus mask for portable XXH64 arithmetic on VM, JavaScript and Wasm.
final BigInt _zstdHashMask = (BigInt.one << 64) - BigInt.one;

/// XXH64 mixing primes defined by the algorithm specification.
final List<BigInt> _zstdHashPrimes = [
  '11400714785074694791',
  '14029467366897019727',
  '1609587929392839161',
  '9650029242287828579',
  '2870177450012600261',
].map(BigInt.parse).toList(growable: false);

/// Rotates an unsigned word without depending on the host integer width.
BigInt _zstdRotate(BigInt value, int bits) {
  final BigInt word = value & _zstdHashMask;
  return ((word << bits) | (word >> (64 - bits))) & _zstdHashMask;
}

/// Mixes one eight-byte lane into an XXH64 accumulator.
BigInt _zstdHashRound(BigInt state, BigInt lane) => (_zstdRotate(state + lane * _zstdHashPrimes[1], 31) * _zstdHashPrimes[0]) & _zstdHashMask;

/// Computes the low 32 bits of seed-zero XXH64 for a complete frame.
int _zstdChecksum(Uint8List bytes) {
  final ByteReader reader = ByteReader(bytes);

  /// Reads a full word as two exact portable 32-bit halves.
  BigInt word() => BigInt.from(reader.readUint32()) | (BigInt.from(reader.readUint32()) << 32);

  BigInt hash;
  if (bytes.length >= 32) {
    final List<BigInt> lanes = [_zstdHashPrimes[0] + _zstdHashPrimes[1], _zstdHashPrimes[1], BigInt.zero, -_zstdHashPrimes[0]];
    while (reader.remaining >= 32) {
      for (int lane = 0; lane < 4; lane++) {
        lanes[lane] = _zstdHashRound(lanes[lane], word());
      }
    }
    hash = _zstdRotate(lanes[0], 1) + _zstdRotate(lanes[1], 7) + _zstdRotate(lanes[2], 12) + _zstdRotate(lanes[3], 18);
    for (final BigInt lane in lanes) {
      hash = ((hash ^ _zstdHashRound(BigInt.zero, lane)) * _zstdHashPrimes[0] + _zstdHashPrimes[3]) & _zstdHashMask;
    }
  } else {
    hash = _zstdHashPrimes[4];
  }
  hash = (hash + BigInt.from(bytes.length)) & _zstdHashMask;
  while (reader.remaining >= 8) {
    hash = (_zstdRotate(hash ^ _zstdHashRound(BigInt.zero, word()), 27) * _zstdHashPrimes[0] + _zstdHashPrimes[3]) & _zstdHashMask;
  }
  if (reader.remaining >= 4) {
    hash = (_zstdRotate(hash ^ (BigInt.from(reader.readUint32()) * _zstdHashPrimes[0]), 23) * _zstdHashPrimes[1] + _zstdHashPrimes[2]) & _zstdHashMask;
  }
  while (reader.remaining != 0) {
    hash = (_zstdRotate(hash ^ (BigInt.from(reader.readByte()) * _zstdHashPrimes[4]), 11) * _zstdHashPrimes[0]) & _zstdHashMask;
  }
  hash = ((hash ^ (hash >> 33)) * _zstdHashPrimes[1]) & _zstdHashMask;
  hash = ((hash ^ (hash >> 29)) * _zstdHashPrimes[2]) & _zstdHashMask;
  hash ^= hash >> 32;
  return (hash & BigInt.from(0xffffffff)).toInt();
}
