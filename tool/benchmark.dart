import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/zcodec.dart';

/// Measures the throughput of the compression and cryptography primitives.
///
/// Every case is run several times and the fastest run is reported, so that a
/// warm-up compilation or a garbage collection does not dominate the result.
void main() {
  final Uint8List data = _sampleData(2 * 1024 * 1024);
  final Uint8List deflated = const DeflateCodec().encode(data);
  final Uint8List dynamicStream = Uint8List.fromList(ZLibCodec(raw: true, level: 9).encode(data));
  final Uint8List key = Uint8List.fromList(<int>[for (int index = 0; index < 32; index++) index]);
  final Uint8List aesInput = Uint8List.sublistView(data, 0, 512 * 1024);

  _report('deflate encode level 6', data.length, () => const DeflateCodec().encode(data));
  _report('deflate encode level 1', data.length, () => const DeflateCodec(level: 1).encode(data));
  _report('deflate decode fixed', data.length, () => const DeflateCodec().decode(deflated));
  _report('deflate decode dynamic', data.length, () => const DeflateCodec().decode(dynamicStream));
  _report('gzip encode', data.length, () => const GzipCodec().encode(data));
  _report('crc32', data.length, () => crc32(data));
  _report('adler32', data.length, () => adler32(data));
  _report('aes-256 winzip ctr', aesInput.length, () => AesCipher(key).cryptWinZipCtr(aesInput));
  _report('pbkdf2-sha1 1000 iterations', 0, () => pbkdf2Sha1(key, key, iterations: 1000, length: 66));
  exit(0);
}

/// Builds semi-compressible sample data of about [length] bytes.
Uint8List _sampleData(int length) {
  const List<String> words = <String>['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta'];
  final Random random = Random(7);
  final BytesBuilder builder = BytesBuilder();
  while (builder.length < length) {
    builder.add('${words[random.nextInt(words.length)]} ${random.nextInt(1000)}\n'.codeUnits);
  }
  return builder.takeBytes();
}

/// Runs [action] repeatedly and prints its fastest duration.
void _report(String name, int bytes, void Function() action) {
  int best = 1 << 62;
  for (int run = 0; run < 7; run++) {
    final Stopwatch watch = Stopwatch()..start();
    action();
    watch.stop();
    best = watch.elapsedMicroseconds < best ? watch.elapsedMicroseconds : best;
  }
  final String throughput = bytes == 0 ? '' : ' (${(bytes / best).toStringAsFixed(1)} MB/s)';
  stdout.writeln('${name.padRight(28)} ${(best / 1000).toStringAsFixed(1).padLeft(8)} ms$throughput');
}
