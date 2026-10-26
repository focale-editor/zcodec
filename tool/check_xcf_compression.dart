/// Exercises every supplied XCF through both codecs and native reference tools.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/zcodec.dart';

/// Reads an existing corpus, writing only temporary compressed files and reports.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/check_xcf_compression.dart /path/to/xcf-corpus');
    exitCode = 64;
    return;
  }
  final Directory temporary = Directory.systemTemp.createTempSync('zcodec-xcf-');
  final List<Map<String, Object>> report = [];
  try {
    final List<File> files = Directory(arguments.single).listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.xcf')).toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final File file in files) {
      final Uint8List raw = file.readAsBytesSync();
      final String hash = _hash(raw);
      for (final (String command, ByteCodec codec) in [('bzip2', const Bzip2Codec()), ('xz', const XzCodec())]) {
        final Stopwatch watch = Stopwatch()..start();
        final Uint8List encoded = codec.encode(raw);
        final int encodeUs = watch.elapsedMicroseconds;
        watch.reset();
        final Uint8List decoded = codec.decode(encoded);
        final int decodeUs = watch.elapsedMicroseconds;
        if (_hash(decoded) != hash) {
          throw StateError('Round-trip mismatch: ${file.path}');
        }
        final File compressed = File('${temporary.path}/encoded')..writeAsBytesSync(encoded);
        final ProcessResult native = await Process.run(command, ['-dc', compressed.path], stdoutEncoding: null);
        if (native.exitCode != 0 || _hash(native.stdout as List<int>) != hash) {
          throw StateError('Native decode mismatch: ${file.path}: ${native.stderr}');
        }
        final ProcessResult nativeEncoded = await Process.run(command, ['-c', file.path], stdoutEncoding: null);
        if (nativeEncoded.exitCode != 0 || _hash(codec.decode(nativeEncoded.stdout as List<int>)) != hash) {
          throw StateError('Native encode mismatch: ${file.path}');
        }
        report.add({
          'file': file.path.substring(arguments.single.length + 1),
          'codec': command,
          'sha256': hash,
          'raw_bytes': raw.length,
          'encoded_bytes': encoded.length,
          'native_encoded_bytes': (nativeEncoded.stdout as List<int>).length,
          'encode_us': encodeUs,
          'decode_us': decodeUs,
        });
      }
    }
    File('build/xcf-compression-report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('${files.length} XCF files, ${report.length} independent codec round-trips passed');
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// Computes a compact exact-byte fingerprint.
String _hash(List<int> bytes) => (Sha256()..add(bytes)).close().map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
