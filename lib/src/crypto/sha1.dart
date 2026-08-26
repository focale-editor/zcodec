part of 'package:zcodec/src/crypto.dart';

/// Number of bytes in one SHA-1 compression block.
const int _sha1BlockSize = 64;

/// Number of bytes in a SHA-1 digest.
const int _sha1DigestSize = 20;

/// SHA-1 initial chaining values.
const List<int> _sha1InitialState = <int>[0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];

/// Computes a SHA-1 digest without relying on a platform cryptography API.
Uint8List sha1(List<int> input) => (Sha1()..add(input)).close();

/// Computes HMAC-SHA1 for [message] with [key].
Uint8List hmacSha1(List<int> key, List<int> message) => HmacSha1(key).convert(message);

/// Derives [length] bytes using PBKDF2-HMAC-SHA1.
///
/// The HMAC key schedule depends only on [password], so it is expanded once
/// and reused across every iteration.
Uint8List pbkdf2Sha1(List<int> password, List<int> salt, {required int iterations, required int length}) {
  if (iterations <= 0) {
    throw RangeError.value(iterations, 'iterations', 'Must be positive');
  }
  if (length < 0) {
    throw RangeError.value(length, 'length', 'Must not be negative');
  }
  final HmacSha1 hmac = HmacSha1(password);
  final Uint8List output = Uint8List(length);
  final Uint8List blockInput = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
  int outputOffset = 0;
  for (int block = 1; outputOffset < length; block++) {
    blockInput[salt.length] = (block >>> 24) & 0xff;
    blockInput[salt.length + 1] = (block >>> 16) & 0xff;
    blockInput[salt.length + 2] = (block >>> 8) & 0xff;
    blockInput[salt.length + 3] = block & 0xff;
    Uint8List intermediate = hmac.convert(blockInput);
    final Uint8List combined = Uint8List.fromList(intermediate);
    for (int iteration = 1; iteration < iterations; iteration++) {
      intermediate = hmac.convert(intermediate);
      for (int index = 0; index < _sha1DigestSize; index++) {
        combined[index] ^= intermediate[index];
      }
    }
    final int count = length - outputOffset < _sha1DigestSize ? length - outputOffset : _sha1DigestSize;
    output.setRange(outputOffset, outputOffset + count, combined);
    outputOffset += count;
  }
  return output;
}

/// Computes a SHA-1 digest incrementally.
final class Sha1 {
  /// Current chaining values.
  final Uint32List _state = Uint32List(5);

  /// Partial block awaiting compression.
  final Uint8List _block = Uint8List(_sha1BlockSize);

  /// Expanded message schedule reused by every compression.
  final Uint32List _schedule = Uint32List(80);

  /// Number of bytes buffered in [_block].
  int _blockLength = 0;

  /// Total number of message bytes absorbed.
  int _messageLength = 0;

  /// Creates a digest positioned at the SHA-1 initial state.
  Sha1() {
    reset();
  }

  /// Restarts from [state], which is assumed to already cover [processedBytes].
  void resetTo(Uint32List state, int processedBytes) {
    _state.setAll(0, state);
    _blockLength = 0;
    _messageLength = processedBytes;
  }

  /// Restarts from the SHA-1 initial state.
  void reset() => resetTo(Uint32List.fromList(_sha1InitialState), 0);

  /// Absorbs [data].
  void add(List<int> data) {
    final int length = data.length;
    _messageLength += length;
    int offset = 0;
    while (offset < length) {
      if (_blockLength == 0 && data is Uint8List && length - offset >= _sha1BlockSize) {
        _compress(data, offset);
        offset += _sha1BlockSize;
        continue;
      }
      final int wanted = _sha1BlockSize - _blockLength;
      final int count = length - offset < wanted ? length - offset : wanted;
      _block.setRange(_blockLength, _blockLength + count, data, offset);
      _blockLength += count;
      offset += count;
      if (_blockLength == _sha1BlockSize) {
        _compress(_block, 0);
        _blockLength = 0;
      }
    }
  }

  /// Applies the SHA-1 padding and returns the digest.
  Uint8List close() {
    final int messageLength = _messageLength;
    _block[_blockLength++] = 0x80;
    if (_blockLength > _sha1BlockSize - 8) {
      _block.fillRange(_blockLength, _sha1BlockSize, 0);
      _compress(_block, 0);
      _blockLength = 0;
    }
    _block.fillRange(_blockLength, _sha1BlockSize - 8, 0);
    int bitLength = messageLength * 8;
    for (int index = _sha1BlockSize - 1; index >= _sha1BlockSize - 8; index--) {
      _block[index] = bitLength & 0xff;
      bitLength ~/= 256;
    }
    _compress(_block, 0);
    final ByteData digest = ByteData(_sha1DigestSize);
    for (int index = 0; index < 5; index++) {
      digest.setUint32(index * 4, _state[index]);
    }
    return digest.buffer.asUint8List();
  }

  /// Returns a copy of the current chaining values.
  Uint32List get state => Uint32List.fromList(_state);

  /// Compresses one 64-byte block starting at [offset].
  void _compress(Uint8List input, int offset) {
    final Uint32List words = _schedule;
    for (int index = 0; index < 16; index++) {
      final int wordOffset = offset + index * 4;
      words[index] = (input[wordOffset] << 24) | (input[wordOffset + 1] << 16) | (input[wordOffset + 2] << 8) | input[wordOffset + 3];
    }
    for (int index = 16; index < 80; index++) {
      words[index] = _rotateLeft(words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16], 1);
    }
    int a = _state[0];
    int b = _state[1];
    int c = _state[2];
    int d = _state[3];
    int e = _state[4];
    for (int index = 0; index < 20; index++) {
      final int temporary = (_rotateLeft(a, 5) + ((b & c) | ((~b) & d)) + e + 0x5a827999 + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    for (int index = 20; index < 40; index++) {
      final int temporary = (_rotateLeft(a, 5) + (b ^ c ^ d) + e + 0x6ed9eba1 + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    for (int index = 40; index < 60; index++) {
      final int temporary = (_rotateLeft(a, 5) + ((b & c) | (b & d) | (c & d)) + e + 0x8f1bbcdc + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    for (int index = 60; index < 80; index++) {
      final int temporary = (_rotateLeft(a, 5) + (b ^ c ^ d) + e + 0xca62c1d6 + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    _state[0] += a;
    _state[1] += b;
    _state[2] += c;
    _state[3] += d;
    _state[4] += e;
  }
}

/// Computes HMAC-SHA1 digests that all share one key.
final class HmacSha1 {
  /// Chaining values after absorbing the inner padded key.
  final Uint32List _innerState;

  /// Chaining values after absorbing the outer padded key.
  final Uint32List _outerState;

  /// Digest reused for the inner and outer passes.
  final Sha1 _digest = Sha1();

  /// Creates an HMAC generator bound to [key].
  factory HmacSha1(List<int> key) {
    final Uint8List normalized = Uint8List(_sha1BlockSize);
    final List<int> source = key.length > _sha1BlockSize ? sha1(key) : key;
    normalized.setRange(0, source.length, source);
    final Uint8List pad = Uint8List(_sha1BlockSize);
    for (int index = 0; index < _sha1BlockSize; index++) {
      pad[index] = normalized[index] ^ 0x36;
    }
    final Uint32List innerState = (Sha1()..add(pad)).state;
    for (int index = 0; index < _sha1BlockSize; index++) {
      pad[index] = normalized[index] ^ 0x5c;
    }
    final Uint32List outerState = (Sha1()..add(pad)).state;
    return HmacSha1._(innerState, outerState);
  }

  /// Creates a generator from precomputed padded-key states.
  HmacSha1._(this._innerState, this._outerState);

  /// Returns the HMAC-SHA1 digest of [message].
  Uint8List convert(List<int> message) {
    _digest.resetTo(_innerState, _sha1BlockSize);
    _digest.add(message);
    final Uint8List inner = _digest.close();
    _digest.resetTo(_outerState, _sha1BlockSize);
    _digest.add(inner);
    return _digest.close();
  }
}

/// Rotates a 32-bit value left by [count] bits.
int _rotateLeft(int value, int count) => ((value << count) | (value >>> (32 - count))) & 0xffffffff;
