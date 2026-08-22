import 'dart:typed_data';

/// Computes a SHA-1 digest without relying on a platform cryptography API.
Uint8List sha1(List<int> input) {
  final int paddedLength = ((input.length + 9 + 63) ~/ 64) * 64;
  final Uint8List padded = Uint8List(paddedLength)..setRange(0, input.length, input);
  padded[input.length] = 0x80;
  final int bitLength = input.length * 8;
  for (int index = 0; index < 8; index++) {
    padded[padded.length - 1 - index] = (bitLength ~/ (1 << (index * 8))) & 0xff;
  }
  int first = 0x67452301;
  int second = 0xefcdab89;
  int third = 0x98badcfe;
  int fourth = 0x10325476;
  int fifth = 0xc3d2e1f0;
  final Uint32List words = Uint32List(80);
  for (int offset = 0; offset < padded.length; offset += 64) {
    for (int index = 0; index < 16; index++) {
      final int wordOffset = offset + index * 4;
      words[index] = (padded[wordOffset] << 24) | (padded[wordOffset + 1] << 16) | (padded[wordOffset + 2] << 8) | padded[wordOffset + 3];
    }
    for (int index = 16; index < 80; index++) {
      words[index] = _rotateLeft(words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16], 1);
    }
    int a = first;
    int b = second;
    int c = third;
    int d = fourth;
    int e = fifth;
    for (int index = 0; index < 80; index++) {
      late final int function;
      late final int constant;
      if (index < 20) {
        function = (b & c) | ((~b) & d);
        constant = 0x5a827999;
      } else if (index < 40) {
        function = b ^ c ^ d;
        constant = 0x6ed9eba1;
      } else if (index < 60) {
        function = (b & c) | (b & d) | (c & d);
        constant = 0x8f1bbcdc;
      } else {
        function = b ^ c ^ d;
        constant = 0xca62c1d6;
      }
      final int temporary = (_rotateLeft(a, 5) + function + e + constant + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    first = (first + a) & 0xffffffff;
    second = (second + b) & 0xffffffff;
    third = (third + c) & 0xffffffff;
    fourth = (fourth + d) & 0xffffffff;
    fifth = (fifth + e) & 0xffffffff;
  }
  final ByteData digest = ByteData(20)
    ..setUint32(0, first)
    ..setUint32(4, second)
    ..setUint32(8, third)
    ..setUint32(12, fourth)
    ..setUint32(16, fifth);
  return digest.buffer.asUint8List();
}

/// Computes HMAC-SHA1 for [message] with [key].
Uint8List hmacSha1(List<int> key, List<int> message) {
  final Uint8List normalizedKey = Uint8List(64);
  final List<int> sourceKey = key.length > 64 ? sha1(key) : key;
  normalizedKey.setRange(0, sourceKey.length, sourceKey);
  final Uint8List inner = Uint8List(64 + message.length);
  final Uint8List outer = Uint8List(64 + 20);
  for (int index = 0; index < 64; index++) {
    inner[index] = normalizedKey[index] ^ 0x36;
    outer[index] = normalizedKey[index] ^ 0x5c;
  }
  inner.setRange(64, inner.length, message);
  outer.setRange(64, outer.length, sha1(inner));
  return sha1(outer);
}

/// Derives [length] bytes using PBKDF2-HMAC-SHA1.
Uint8List pbkdf2Sha1(List<int> password, List<int> salt, {required int iterations, required int length}) {
  if (iterations <= 0) {
    throw RangeError.value(iterations, 'iterations', 'Must be positive');
  }
  if (length < 0) {
    throw RangeError.value(length, 'length', 'Must not be negative');
  }
  final Uint8List output = Uint8List(length);
  final Uint8List blockInput = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
  int outputOffset = 0;
  for (int block = 1; outputOffset < length; block++) {
    blockInput[salt.length] = (block >>> 24) & 0xff;
    blockInput[salt.length + 1] = (block >>> 16) & 0xff;
    blockInput[salt.length + 2] = (block >>> 8) & 0xff;
    blockInput[salt.length + 3] = block & 0xff;
    Uint8List intermediate = hmacSha1(password, blockInput);
    final Uint8List combined = Uint8List.fromList(intermediate);
    for (int iteration = 1; iteration < iterations; iteration++) {
      intermediate = hmacSha1(password, intermediate);
      for (int index = 0; index < combined.length; index++) {
        combined[index] ^= intermediate[index];
      }
    }
    final int count = (length - outputOffset).clamp(0, combined.length);
    output.setRange(outputOffset, outputOffset + count, combined);
    outputOffset += count;
  }
  return output;
}

/// Encrypts 16-byte blocks with AES-128, AES-192, or AES-256.
final class AesCipher {
  /// Expanded round-key words.
  final Uint32List _roundKeys;

  /// Number of AES transformation rounds.
  final int _rounds;

  /// Creates an AES cipher from a 16-, 24-, or 32-byte [key].
  AesCipher(List<int> key) : _rounds = key.length ~/ 4 + 6, _roundKeys = _expandKey(key) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'AES keys must contain 16, 24, or 32 bytes');
    }
  }

  /// Encrypts exactly one 16-byte [block].
  Uint8List encryptBlock(List<int> block) {
    if (block.length != 16) {
      throw ArgumentError.value(block.length, 'block', 'AES blocks must contain 16 bytes');
    }
    Uint8List state = Uint8List.fromList(block);
    _addRoundKey(state, 0);
    for (int round = 1; round < _rounds; round++) {
      state = _shiftRows(state);
      _substitute(state);
      _mixColumns(state);
      _addRoundKey(state, round);
    }
    state = _shiftRows(state);
    _substitute(state);
    _addRoundKey(state, _rounds);
    return state;
  }

  /// XORs [input] with the WinZip AES little-endian CTR key stream.
  Uint8List cryptWinZipCtr(List<int> input) {
    final Uint8List output = Uint8List(input.length);
    int counter = 1;
    for (int offset = 0; offset < input.length; offset += 16) {
      final Uint8List counterBlock = Uint8List(16);
      int value = counter++;
      for (int index = 0; index < 16 && value != 0; index++) {
        counterBlock[index] = value & 0xff;
        value ~/= 256;
      }
      final Uint8List keyStream = encryptBlock(counterBlock);
      final int count = (input.length - offset).clamp(0, 16);
      for (int index = 0; index < count; index++) {
        output[offset + index] = input[offset + index] ^ keyStream[index];
      }
    }
    return output;
  }

  /// XORs one round key into [state].
  void _addRoundKey(Uint8List state, int round) {
    for (int column = 0; column < 4; column++) {
      final int word = _roundKeys[round * 4 + column];
      state[column * 4] ^= (word >>> 24) & 0xff;
      state[column * 4 + 1] ^= (word >>> 16) & 0xff;
      state[column * 4 + 2] ^= (word >>> 8) & 0xff;
      state[column * 4 + 3] ^= word & 0xff;
    }
  }
}

/// Expands an AES key into its encryption round keys.
Uint32List _expandKey(List<int> key) {
  if (key.length != 16 && key.length != 24 && key.length != 32) {
    return Uint32List(0);
  }
  final int keyWords = key.length ~/ 4;
  final int rounds = keyWords + 6;
  final Uint32List words = Uint32List(4 * (rounds + 1));
  for (int index = 0; index < keyWords; index++) {
    final int offset = index * 4;
    words[index] = (key[offset] << 24) | (key[offset + 1] << 16) | (key[offset + 2] << 8) | key[offset + 3];
  }
  for (int index = keyWords; index < words.length; index++) {
    int temporary = words[index - 1];
    if (index % keyWords == 0) {
      temporary = _substituteWord(_rotateWord(temporary)) ^ (_rcon[index ~/ keyWords] << 24);
    } else if (keyWords > 6 && index % keyWords == 4) {
      temporary = _substituteWord(temporary);
    }
    words[index] = words[index - keyWords] ^ temporary;
  }
  return words;
}

/// Applies the AES substitution box to every byte in [state].
void _substitute(Uint8List state) {
  for (int index = 0; index < state.length; index++) {
    state[index] = _sBox[state[index]];
  }
}

/// Applies the AES substitution box to a 32-bit [word].
int _substituteWord(int word) => (_sBox[(word >>> 24) & 0xff] << 24) | (_sBox[(word >>> 16) & 0xff] << 16) | (_sBox[(word >>> 8) & 0xff] << 8) | _sBox[word & 0xff];

/// Rotates an AES key-schedule word by one byte.
int _rotateWord(int word) => ((word << 8) | (word >>> 24)) & 0xffffffff;

/// Shifts AES state rows to the left by their row number.
Uint8List _shiftRows(Uint8List state) {
  final Uint8List shifted = Uint8List(16);
  for (int row = 0; row < 4; row++) {
    for (int column = 0; column < 4; column++) {
      shifted[row + column * 4] = state[row + ((column + row) & 3) * 4];
    }
  }
  return shifted;
}

/// Mixes each AES state column in the Rijndael finite field.
void _mixColumns(Uint8List state) {
  for (int column = 0; column < 4; column++) {
    final int offset = column * 4;
    final int first = state[offset];
    final int second = state[offset + 1];
    final int third = state[offset + 2];
    final int fourth = state[offset + 3];
    final int combined = first ^ second ^ third ^ fourth;
    state[offset] = first ^ combined ^ _multiplyByX(first ^ second);
    state[offset + 1] = second ^ combined ^ _multiplyByX(second ^ third);
    state[offset + 2] = third ^ combined ^ _multiplyByX(third ^ fourth);
    state[offset + 3] = fourth ^ combined ^ _multiplyByX(fourth ^ first);
  }
}

/// Multiplies one byte by x in the AES finite field.
int _multiplyByX(int value) => ((value << 1) ^ (value >= 0x80 ? 0x11b : 0)) & 0xff;

/// Rotates a 32-bit value left by [count] bits.
int _rotateLeft(int value, int count) => ((value << count) | (value >>> (32 - count))) & 0xffffffff;

/// AES substitution box.
const List<int> _sBox = <int>[
  0x63,
  0x7c,
  0x77,
  0x7b,
  0xf2,
  0x6b,
  0x6f,
  0xc5,
  0x30,
  0x01,
  0x67,
  0x2b,
  0xfe,
  0xd7,
  0xab,
  0x76,
  0xca,
  0x82,
  0xc9,
  0x7d,
  0xfa,
  0x59,
  0x47,
  0xf0,
  0xad,
  0xd4,
  0xa2,
  0xaf,
  0x9c,
  0xa4,
  0x72,
  0xc0,
  0xb7,
  0xfd,
  0x93,
  0x26,
  0x36,
  0x3f,
  0xf7,
  0xcc,
  0x34,
  0xa5,
  0xe5,
  0xf1,
  0x71,
  0xd8,
  0x31,
  0x15,
  0x04,
  0xc7,
  0x23,
  0xc3,
  0x18,
  0x96,
  0x05,
  0x9a,
  0x07,
  0x12,
  0x80,
  0xe2,
  0xeb,
  0x27,
  0xb2,
  0x75,
  0x09,
  0x83,
  0x2c,
  0x1a,
  0x1b,
  0x6e,
  0x5a,
  0xa0,
  0x52,
  0x3b,
  0xd6,
  0xb3,
  0x29,
  0xe3,
  0x2f,
  0x84,
  0x53,
  0xd1,
  0x00,
  0xed,
  0x20,
  0xfc,
  0xb1,
  0x5b,
  0x6a,
  0xcb,
  0xbe,
  0x39,
  0x4a,
  0x4c,
  0x58,
  0xcf,
  0xd0,
  0xef,
  0xaa,
  0xfb,
  0x43,
  0x4d,
  0x33,
  0x85,
  0x45,
  0xf9,
  0x02,
  0x7f,
  0x50,
  0x3c,
  0x9f,
  0xa8,
  0x51,
  0xa3,
  0x40,
  0x8f,
  0x92,
  0x9d,
  0x38,
  0xf5,
  0xbc,
  0xb6,
  0xda,
  0x21,
  0x10,
  0xff,
  0xf3,
  0xd2,
  0xcd,
  0x0c,
  0x13,
  0xec,
  0x5f,
  0x97,
  0x44,
  0x17,
  0xc4,
  0xa7,
  0x7e,
  0x3d,
  0x64,
  0x5d,
  0x19,
  0x73,
  0x60,
  0x81,
  0x4f,
  0xdc,
  0x22,
  0x2a,
  0x90,
  0x88,
  0x46,
  0xee,
  0xb8,
  0x14,
  0xde,
  0x5e,
  0x0b,
  0xdb,
  0xe0,
  0x32,
  0x3a,
  0x0a,
  0x49,
  0x06,
  0x24,
  0x5c,
  0xc2,
  0xd3,
  0xac,
  0x62,
  0x91,
  0x95,
  0xe4,
  0x79,
  0xe7,
  0xc8,
  0x37,
  0x6d,
  0x8d,
  0xd5,
  0x4e,
  0xa9,
  0x6c,
  0x56,
  0xf4,
  0xea,
  0x65,
  0x7a,
  0xae,
  0x08,
  0xba,
  0x78,
  0x25,
  0x2e,
  0x1c,
  0xa6,
  0xb4,
  0xc6,
  0xe8,
  0xdd,
  0x74,
  0x1f,
  0x4b,
  0xbd,
  0x8b,
  0x8a,
  0x70,
  0x3e,
  0xb5,
  0x66,
  0x48,
  0x03,
  0xf6,
  0x0e,
  0x61,
  0x35,
  0x57,
  0xb9,
  0x86,
  0xc1,
  0x1d,
  0x9e,
  0xe1,
  0xf8,
  0x98,
  0x11,
  0x69,
  0xd9,
  0x8e,
  0x94,
  0x9b,
  0x1e,
  0x87,
  0xe9,
  0xce,
  0x55,
  0x28,
  0xdf,
  0x8c,
  0xa1,
  0x89,
  0x0d,
  0xbf,
  0xe6,
  0x42,
  0x68,
  0x41,
  0x99,
  0x2d,
  0x0f,
  0xb0,
  0x54,
  0xbb,
  0x16,
];

/// AES round constants indexed by key-schedule round.
const List<int> _rcon = <int>[0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d, 0x9a];
