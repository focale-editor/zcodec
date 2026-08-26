part of 'package:zcodec/src/crypto.dart';

/// Number of bytes in one AES block.
const int _aesBlockSize = 16;

/// Encrypts 16-byte blocks with AES-128, AES-192, or AES-256.
///
/// Only the forward direction is implemented because WinZip AES uses counter
/// mode, where decryption reuses the encryption key stream.
///
/// The state is held in four 32-bit column words rather than sixteen bytes, so
/// a round applies `ShiftRows`, `SubBytes`, and `MixColumns` in one pass over
/// four integers and never allocates.
final class AesCipher {
  /// Expanded round-key words.
  final Uint32List _roundKeys;

  /// Number of AES transformation rounds.
  final int _rounds;

  /// Encrypted column words of the most recent block.
  final Uint32List _state = Uint32List(4);

  /// Creates an AES cipher from a 16-, 24-, or 32-byte [key].
  factory AesCipher(List<int> key) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'AES keys must contain 16, 24, or 32 bytes');
    }
    return AesCipher._(_expandKey(key), key.length ~/ 4 + 6);
  }

  /// Creates a cipher from an expanded key schedule.
  AesCipher._(this._roundKeys, this._rounds);

  /// Encrypts exactly one 16-byte [block].
  Uint8List encryptBlock(List<int> block) {
    if (block.length != _aesBlockSize) {
      throw ArgumentError.value(block.length, 'block', 'AES blocks must contain 16 bytes');
    }
    _encrypt(
      (block[0] << 24) | (block[1] << 16) | (block[2] << 8) | block[3],
      (block[4] << 24) | (block[5] << 16) | (block[6] << 8) | block[7],
      (block[8] << 24) | (block[9] << 16) | (block[10] << 8) | block[11],
      (block[12] << 24) | (block[13] << 16) | (block[14] << 8) | block[15],
    );
    final Uint8List output = Uint8List(_aesBlockSize);
    for (int column = 0; column < 4; column++) {
      final int word = _state[column];
      output[column * 4] = (word >>> 24) & 0xff;
      output[column * 4 + 1] = (word >>> 16) & 0xff;
      output[column * 4 + 2] = (word >>> 8) & 0xff;
      output[column * 4 + 3] = word & 0xff;
    }
    return output;
  }

  /// XORs [input] with the WinZip AES little-endian CTR key stream.
  ///
  /// The counter starts at one and is stored least significant byte first,
  /// which is the convention WinZip chose for AE-1 and AE-2 entries.
  Uint8List cryptWinZipCtr(List<int> input) {
    final Uint8List output = Uint8List(input.length);
    for (int offset = 0; offset < input.length; offset += _aesBlockSize) {
      // The counter never exceeds 64 bits in practice, so only the first two
      // words of the counter block can be nonzero.
      final int counter = offset ~/ _aesBlockSize + 1;
      _encrypt(_reverseWordBytes(counter & 0xffffffff), _reverseWordBytes(counter ~/ 0x100000000), 0, 0);
      final int end = input.length - offset < _aesBlockSize ? input.length : offset + _aesBlockSize;
      for (int index = offset; index < end; index++) {
        final int position = index - offset;
        output[index] = input[index] ^ ((_state[position >>> 2] >>> (24 - 8 * (position & 3))) & 0xff);
      }
    }
    return output;
  }

  /// Applies every AES round to the four column words of one block.
  void _encrypt(int first, int second, int third, int fourth) {
    int s0 = first ^ _roundKeys[0];
    int s1 = second ^ _roundKeys[1];
    int s2 = third ^ _roundKeys[2];
    int s3 = fourth ^ _roundKeys[3];
    for (int round = 1; round < _rounds; round++) {
      final int offset = round * 4;
      final int t0 = _mixedColumn(s0, s1, s2, s3) ^ _roundKeys[offset];
      final int t1 = _mixedColumn(s1, s2, s3, s0) ^ _roundKeys[offset + 1];
      final int t2 = _mixedColumn(s2, s3, s0, s1) ^ _roundKeys[offset + 2];
      final int t3 = _mixedColumn(s3, s0, s1, s2) ^ _roundKeys[offset + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
    }
    final int offset = _rounds * 4;
    _state[0] = _substitutedColumn(s0, s1, s2, s3) ^ _roundKeys[offset];
    _state[1] = _substitutedColumn(s1, s2, s3, s0) ^ _roundKeys[offset + 1];
    _state[2] = _substitutedColumn(s2, s3, s0, s1) ^ _roundKeys[offset + 2];
    _state[3] = _substitutedColumn(s3, s0, s1, s2) ^ _roundKeys[offset + 3];
  }
}

/// Applies `ShiftRows` and `SubBytes` to one column.
///
/// Row `r` of the result comes from the column `r` positions to the right,
/// which is exactly what shifting row `r` left by `r` produces.
int _substitutedColumn(int row0, int row1, int row2, int row3) => (_sBox[(row0 >>> 24) & 0xff] << 24) | (_sBox[(row1 >>> 16) & 0xff] << 16) | (_sBox[(row2 >>> 8) & 0xff] << 8) | _sBox[row3 & 0xff];

/// Applies `ShiftRows`, `SubBytes`, and `MixColumns` to one column.
int _mixedColumn(int row0, int row1, int row2, int row3) {
  final int first = _sBox[(row0 >>> 24) & 0xff];
  final int second = _sBox[(row1 >>> 16) & 0xff];
  final int third = _sBox[(row2 >>> 8) & 0xff];
  final int fourth = _sBox[row3 & 0xff];
  final int combined = first ^ second ^ third ^ fourth;
  return ((first ^ combined ^ _multiplyByX(first ^ second)) << 24) |
      ((second ^ combined ^ _multiplyByX(second ^ third)) << 16) |
      ((third ^ combined ^ _multiplyByX(third ^ fourth)) << 8) |
      (fourth ^ combined ^ _multiplyByX(fourth ^ first));
}

/// Reverses the byte order of a 32-bit [word].
int _reverseWordBytes(int word) => ((word & 0xff) << 24) | ((word & 0xff00) << 8) | ((word >>> 8) & 0xff00) | ((word >>> 24) & 0xff);

/// Expands an AES key into its encryption round keys.
Uint32List _expandKey(List<int> key) {
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

/// Applies the AES substitution box to a 32-bit [word].
int _substituteWord(int word) => (_sBox[(word >>> 24) & 0xff] << 24) | (_sBox[(word >>> 16) & 0xff] << 16) | (_sBox[(word >>> 8) & 0xff] << 8) | _sBox[word & 0xff];

/// Rotates an AES key-schedule word by one byte.
int _rotateWord(int word) => ((word << 8) | (word >>> 24)) & 0xffffffff;

/// Multiplies one byte by x in the AES finite field.
int _multiplyByX(int value) => ((value << 1) ^ (value >= 0x80 ? 0x11b : 0)) & 0xff;

/// AES round constants indexed by key-schedule round.
const List<int> _rcon = <int>[0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d, 0x9a];

/// AES substitution box, derived from the Rijndael specification.
///
/// Each entry is the multiplicative inverse of its index in GF(2^8) followed
/// by the specified affine transformation. Generating it keeps the definition
/// verifiable instead of relying on 256 transcribed constants.
final Uint8List _sBox = _buildSubstitutionBox();

/// Builds the AES substitution box.
Uint8List _buildSubstitutionBox() {
  final Uint8List box = Uint8List(256);
  // `power` walks the powers of three and `inverse` walks the powers of its
  // reciprocal, so the two stay multiplicative inverses of each other.
  int power = 1;
  int inverse = 1;
  do {
    power = (power ^ (power << 1) ^ (power >= 0x80 ? 0x11b : 0)) & 0xff;
    inverse ^= (inverse << 1) & 0xff;
    inverse ^= (inverse << 2) & 0xff;
    inverse ^= (inverse << 4) & 0xff;
    if (inverse >= 0x80) {
      inverse ^= 0x09;
    }
    inverse &= 0xff;
    box[power] = (inverse ^ _rotateByte(inverse, 1) ^ _rotateByte(inverse, 2) ^ _rotateByte(inverse, 3) ^ _rotateByte(inverse, 4) ^ 0x63) & 0xff;
  } while (power != 1);
  box[0] = 0x63;
  return box;
}

/// Rotates the bits of one byte left by [count].
int _rotateByte(int value, int count) => ((value << count) | (value >>> (8 - count))) & 0xff;
