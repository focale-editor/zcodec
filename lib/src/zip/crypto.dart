part of 'package:zcodec/src/zip.dart';

/// Implements the traditional PKWARE ZipCrypto byte stream.
final class _ZipCryptoCipher {
  /// First evolving 32-bit key.
  int _first = 305419896;

  /// Second evolving 32-bit key.
  int _second = 591751049;

  /// Third evolving 32-bit key.
  int _third = 878082192;

  /// Creates and initializes a cipher from a UTF-8 [password].
  _ZipCryptoCipher(String password) {
    utf8.encode(password).forEach(_update);
  }

  /// Encrypts [plain] and updates the keys with its plaintext bytes.
  Uint8List encrypt(List<int> plain) {
    final Uint8List encrypted = Uint8List(plain.length);
    for (int index = 0; index < plain.length; index++) {
      final int byte = plain[index] & 0xff;
      encrypted[index] = byte ^ _nextByte();
      _update(byte);
    }
    return encrypted;
  }

  /// Decrypts [encrypted] and updates the keys with recovered bytes.
  Uint8List decrypt(List<int> encrypted) {
    final Uint8List plain = Uint8List(encrypted.length);
    for (int index = 0; index < encrypted.length; index++) {
      final int byte = (encrypted[index] & 0xff) ^ _nextByte();
      plain[index] = byte;
      _update(byte);
    }
    return plain;
  }

  /// Returns the next pseudo-random stream byte.
  int _nextByte() {
    final int temporary = _third | 2;
    return ((temporary * (temporary ^ 1)) >>> 8) & 0xff;
  }

  /// Updates all keys with one plaintext [byte].
  void _update(int byte) {
    _first = crc32UpdateByte(_first, byte);
    _second = ((_second + (_first & 0xff)) * 134775813 + 1) & 0xffffffff;
    _third = crc32UpdateByte(_third, (_second >>> 24) & 0xff);
  }
}

/// Number of bytes in the truncated HMAC-SHA1 authentication code.
const int _authenticationCodeLength = 10;

/// PBKDF2 iteration count mandated by the WinZip AES specification.
const int _winZipAesIterations = 1000;

/// Contains a complete WinZip AES encrypted payload.
final class _WinZipAesPayload {
  /// Salt, password verifier, ciphertext, and authentication code.
  final Uint8List bytes;

  /// Creates a completed encrypted payload.
  const _WinZipAesPayload(this.bytes);
}

/// Encrypts compressed bytes using the WinZip AES AE-2 format.
_WinZipAesPayload _encryptWinZipAes({
  required List<int> compressed,
  required String password,
  required int keyLength,
  required Uint8List Function(int length) randomBytes,
}) {
  final int saltLength = keyLength ~/ 2;
  final Uint8List salt = randomBytes(saltLength);
  if (salt.length != saltLength) {
    throw StateError('The random byte provider returned ${salt.length} bytes; expected $saltLength');
  }
  final Uint8List derived = pbkdf2Sha1(utf8.encode(password), salt, iterations: _winZipAesIterations, length: keyLength * 2 + 2);
  final Uint8List encryptionKey = Uint8List.sublistView(derived, 0, keyLength);
  final Uint8List authenticationKey = Uint8List.sublistView(derived, keyLength, keyLength * 2);
  final Uint8List verifier = Uint8List.sublistView(derived, keyLength * 2);
  final Uint8List encrypted = AesCipher(encryptionKey).cryptWinZipCtr(compressed);
  final Uint8List authentication = Uint8List.sublistView(hmacSha1(authenticationKey, encrypted), 0, _authenticationCodeLength);
  final int authenticationOffset = salt.length + 2 + encrypted.length;
  final Uint8List result = Uint8List(authenticationOffset + _authenticationCodeLength)
    ..setRange(0, salt.length, salt)
    ..setRange(salt.length, salt.length + 2, verifier)
    ..setRange(salt.length + 2, authenticationOffset, encrypted)
    ..setRange(authenticationOffset, authenticationOffset + _authenticationCodeLength, authentication);
  return _WinZipAesPayload(result);
}

/// Decrypts and authenticates one WinZip AES AE-1 or AE-2 payload.
///
/// The payload is read through views, so only the plaintext is allocated.
Uint8List _decryptWinZipAes({required Uint8List payload, required String password, required int keyLength}) {
  final int saltLength = keyLength ~/ 2;
  if (payload.length < saltLength + 2 + _authenticationCodeLength) {
    throw const ZCodecException('Truncated WinZip AES payload');
  }
  final Uint8List salt = Uint8List.sublistView(payload, 0, saltLength);
  final Uint8List derived = pbkdf2Sha1(utf8.encode(password), salt, iterations: _winZipAesIterations, length: keyLength * 2 + 2);
  final Uint8List verifier = Uint8List.sublistView(derived, keyLength * 2);
  if (!_constantTimeEquals(verifier, Uint8List.sublistView(payload, saltLength, saltLength + 2))) {
    throw const ZCodecException('Incorrect ZIP password');
  }
  final Uint8List authenticationKey = Uint8List.sublistView(derived, keyLength, keyLength * 2);
  final int encryptedEnd = payload.length - _authenticationCodeLength;
  final Uint8List encrypted = Uint8List.sublistView(payload, saltLength + 2, encryptedEnd);
  final Uint8List expectedAuthentication = Uint8List.sublistView(hmacSha1(authenticationKey, encrypted), 0, _authenticationCodeLength);
  if (!_constantTimeEquals(expectedAuthentication, Uint8List.sublistView(payload, encryptedEnd))) {
    throw const ZCodecException('Invalid WinZip AES authentication code');
  }
  return AesCipher(Uint8List.sublistView(derived, 0, keyLength)).cryptWinZipCtr(encrypted);
}

/// Compares byte sequences without content-dependent early returns.
bool _constantTimeEquals(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  int difference = 0;
  for (int index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
