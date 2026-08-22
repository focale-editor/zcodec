import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcodec/src/crypto.dart';

void main() {
  test('SHA-1 matches the FIPS known-answer vector', () {
    expect(_hex(sha1(utf8.encode('abc'))), 'a9993e364706816aba3e25717850c26c9cd0d89d');
  });

  test('HMAC-SHA1 matches RFC 2202', () {
    expect(_hex(hmacSha1(List<int>.filled(20, 0x0b), utf8.encode('Hi There'))), 'b617318655057264e28bc0b6fb378c8ef146be00');
  });

  test('PBKDF2-HMAC-SHA1 matches RFC 6070', () {
    expect(
      _hex(pbkdf2Sha1(utf8.encode('password'), utf8.encode('salt'), iterations: 1, length: 20)),
      '0c60c80f961f0e71f3a9b524af6012062fe037a6',
    );
  });

  test('AES supports the FIPS 197 key sizes', () {
    final List<int> plaintext = _bytes('00112233445566778899aabbccddeeff');
    expect(_hex(AesCipher(_bytes('000102030405060708090a0b0c0d0e0f')).encryptBlock(plaintext)), '69c4e0d86a7b0430d8cdb78070b4c55a');
    expect(_hex(AesCipher(_bytes('000102030405060708090a0b0c0d0e0f1011121314151617')).encryptBlock(plaintext)), 'dda97ca4864cdfe06eaf70a0ec0d7191');
    expect(_hex(AesCipher(_bytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')).encryptBlock(plaintext)), '8ea2b7ca516745bfeafc49904b496089');
  });
}

/// Decodes an even-length hexadecimal [value].
List<int> _bytes(String value) => <int>[for (int offset = 0; offset < value.length; offset += 2) int.parse(value.substring(offset, offset + 2), radix: 16)];

/// Encodes [bytes] as lowercase hexadecimal text.
String _hex(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
