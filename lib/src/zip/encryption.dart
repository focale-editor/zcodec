part of 'package:zcodec/src/zip.dart';

/// Describes a compressed payload after optional password encryption.
final class _EncryptedPayload {
  /// Bytes stored in the ZIP data area.
  final Uint8List bytes;

  /// Compression method written in headers.
  final int headerMethod;

  /// General-purpose ZIP flags.
  final int flags;

  /// Encryption-specific extra fields.
  final Uint8List extra;

  /// CRC value written to headers.
  final int headerChecksum;

  /// Creates a prepared ZIP payload.
  const _EncryptedPayload({
    required this.bytes,
    required this.headerMethod,
    required this.flags,
    required this.extra,
    required this.headerChecksum,
  });
}

/// Encrypts one compressed entry and prepares its header metadata.
_EncryptedPayload _encryptPayload({
  required Uint8List compressed,
  required ZipEncryption encryption,
  required String? password,
  required int checksum,
  required int actualMethod,
  required ZipRandomBytes randomBytes,
}) {
  if (encryption == ZipEncryption.none) {
    return _EncryptedPayload(bytes: compressed, headerMethod: actualMethod, flags: 0x0800, extra: Uint8List(0), headerChecksum: checksum);
  }
  if (password == null) {
    throw const ZCodecException('A password provider is required for encrypted ZIP entries');
  }
  if (encryption == ZipEncryption.zipCrypto) {
    final Uint8List header = randomBytes(12);
    if (header.length != 12) {
      throw StateError('The random byte provider returned ${header.length} bytes; expected 12');
    }
    header[11] = (checksum >>> 24) & 0xff;
    final _ZipCryptoCipher cipher = _ZipCryptoCipher(password);
    return _EncryptedPayload(
      bytes: joinBytes(cipher.encrypt(header), cipher.encrypt(compressed)),
      headerMethod: actualMethod,
      flags: 0x0801,
      extra: Uint8List(0),
      headerChecksum: checksum,
    );
  }
  final int keyLength = _aesKeyLength(encryption);
  final int strength = keyLength == 16
      ? 1
      : keyLength == 24
      ? 2
      : 3;
  final _WinZipAesPayload payload = _encryptWinZipAes(
    compressed: compressed,
    password: password,
    keyLength: keyLength,
    randomBytes: randomBytes,
  );
  final ByteWriter extra = ByteWriter()
    ..writeUint16(0x9901)
    ..writeUint16(7)
    ..writeUint16(2)
    ..writeByte(0x41)
    ..writeByte(0x45)
    ..writeByte(strength)
    ..writeUint16(actualMethod);
  return _EncryptedPayload(bytes: payload.bytes, headerMethod: 99, flags: 0x0801, extra: extra.takeBytes(), headerChecksum: 0);
}

/// Returns the AES key length represented by [encryption].
int _aesKeyLength(ZipEncryption encryption) => switch (encryption) {
  ZipEncryption.aes128 => 16,
  ZipEncryption.aes192 => 24,
  ZipEncryption.aes256 => 32,
  ZipEncryption.none || ZipEncryption.zipCrypto => throw StateError('$encryption does not use AES'),
};

/// Random source reused by every generated encryption header.
///
/// Creating a `Random.secure` seeds from the platform entropy source, which is
/// far too expensive to repeat for every entry.
final Random _secureRandom = Random.secure();

/// Generates [length] bytes using the Dart SDK secure random source.
Uint8List _secureRandomBytes(int length) {
  final Uint8List bytes = Uint8List(length);
  for (int index = 0; index < length; index++) {
    bytes[index] = _secureRandom.nextInt(256);
  }
  return bytes;
}
