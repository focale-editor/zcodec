part of 'package:zcodec/src/crypto.dart';

/// Incremental SHA-256 for XZ block integrity, independent of platform APIs.
final class Sha256 {
  /// Initial SHA-256 chaining values.
  final Uint32List _state = Uint32List.fromList([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);

  /// Pending input block.
  final Uint8List _block = Uint8List(64);

  /// Reused message schedule.
  final Uint32List _schedule = Uint32List(64);

  /// Pending byte count.
  int _used = 0;

  /// Total message length in bytes.
  int _length = 0;

  /// Whether the digest has been finalized.
  bool _closed = false;

  /// Creates a fresh digest.
  Sha256();

  /// Adds bytes without retaining caller-owned storage.
  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('SHA-256 is already finalized');
    }
    _length += bytes.length;
    int cursor = 0;
    while (cursor < bytes.length) {
      final int count = (bytes.length - cursor).clamp(0, 64 - _used);
      _block.setRange(_used, _used + count, bytes, cursor);
      _used += count;
      cursor += count;
      if (_used == 64) {
        _compress();
        _used = 0;
      }
    }
  }

  /// Applies padding and returns the 32-byte digest.
  Uint8List close() {
    if (_closed) {
      throw StateError('SHA-256 is already finalized');
    }
    _closed = true;
    _block[_used++] = 128;
    if (_used > 56) {
      _block.fillRange(_used, 64, 0);
      _compress();
      _used = 0;
    }
    _block.fillRange(_used, 56, 0);
    int bits = _length * 8;
    for (int i = 63; i >= 56; i--) {
      _block[i] = bits & 255;
      bits ~/= 256;
    }
    _compress();
    final ByteData result = ByteData(32);
    for (int i = 0; i < 8; i++) {
      result.setUint32(i * 4, _state[i]);
    }
    return result.buffer.asUint8List();
  }

  /// Compresses one complete 512-bit message block.
  void _compress() {
    final ByteData data = ByteData.sublistView(_block);
    for (int i = 0; i < 16; i++) {
      _schedule[i] = data.getUint32(i * 4);
    }
    for (int i = 16; i < 64; i++) {
      final int a = _schedule[i - 15];
      final int b = _schedule[i - 2];
      final int s0 = _sha256Rotate(a, 7) ^ _sha256Rotate(a, 18) ^ (a >>> 3);
      final int s1 = _sha256Rotate(b, 17) ^ _sha256Rotate(b, 19) ^ (b >>> 10);
      _schedule[i] = (_schedule[i - 16] + s0 + _schedule[i - 7] + s1) & 0xffffffff;
    }
    int a = _state[0];
    int b = _state[1];
    int c = _state[2];
    int d = _state[3];
    int e = _state[4];
    int f = _state[5];
    int g = _state[6];
    int h = _state[7];
    for (int i = 0; i < 64; i++) {
      final int s1 = _sha256Rotate(e, 6) ^ _sha256Rotate(e, 11) ^ _sha256Rotate(e, 25);
      final int choice = (e & f) ^ ((~e) & g);
      final int t1 = (h + s1 + choice + _sha256Constants[i] + _schedule[i]) & 0xffffffff;
      final int s0 = _sha256Rotate(a, 2) ^ _sha256Rotate(a, 13) ^ _sha256Rotate(a, 22);
      final int majority = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    final List<int> working = [a, b, c, d, e, f, g, h];
    for (int i = 0; i < 8; i++) {
      _state[i] = (_state[i] + working[i]) & 0xffffffff;
    }
  }
}

/// Rotates an unsigned word, avoiding signed JavaScript shifts.
int _sha256Rotate(int value, int count) => ((value >>> count) | (value << (32 - count))) & 0xffffffff;

/// Fractional cube roots of the first 64 primes, prescribed by SHA-256.
const List<int> _sha256Constants = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];
