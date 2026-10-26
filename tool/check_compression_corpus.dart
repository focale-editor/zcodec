/// Checks pinned upstream corpora against independent command-line decoders.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/zcodec.dart';

/// Runs the downloaded reference corpus without changing its files.
Future<void> main() async {
  final Map<String, dynamic> manifest = jsonDecode(File('tool/compression_corpus_manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final Map<String, Map<String, dynamic>> pinned = {for (final dynamic entry in manifest['files'] as List<dynamic>) '${entry['format']}/${entry['file']}': entry as Map<String, dynamic>};
  final List<Map<String, Object?>> results = [];
  final List<(String, String)> roots = [('xz', 'build/corpus/xz-reference/tests/files'), ('bzip2', 'build/corpus/bzip2-reference')];
  int failed = 0;
  for (final (String command, String root) in roots) {
    final List<File> files =
        Directory(root).listSync(recursive: true).whereType<File>().where((file) => command == 'xz' ? file.path.endsWith('.xz') : file.path.endsWith('.bz2') || file.path.endsWith('.bz2.bad')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final File file in files) {
      final String name = file.path.substring(root.length + 1);
      final bool invalid = name.startsWith('bad-') || name.startsWith('unsupported-') || name.endsWith('.bad');
      final Uint8List encoded = file.readAsBytesSync();
      final Map<String, dynamic>? pin = pinned['$command/$name'];
      if (pin == null || pin['size'] != encoded.length || pin['sha256'] != _hash(encoded)) {
        throw StateError('Unpinned or changed corpus input: $command/$name');
      }
      final ByteCodec codec = command == 'xz'
          ? const XzCodec(maxOutputBytes: 128 * 1024 * 1024)
          : Bzip2Codec(
              maxOutputBytes: name == 'commons-compress/zip64support.tar.bz2' ? 8 * 1024 * 1024 : 128 * 1024 * 1024,
              allowTrailingBytes: name == 'lbzip2/trash.bz2' || name == 'lbzip2/gap.bz2',
            );
      String status = '';
      String? detail;
      final Stopwatch watch = Stopwatch()..start();
      try {
        final Uint8List decoded = codec.decode(encoded);
        if (invalid) {
          status = 'FAIL accepted-invalid';
        } else {
          final ProcessResult native = await Process.run(command, ['-dc', file.path], stdoutEncoding: null);
          final Uint8List expected = Uint8List.fromList(native.stdout as List<int>);
          final String actualHash = _hash(decoded);
          if (native.exitCode != 0 || decoded.length != expected.length || actualHash != _hash(expected)) {
            status = 'FAIL decoded-mismatch';
          } else {
            status = 'pass';
            detail = '${decoded.length} bytes; sha256=$actualHash';
          }
        }
      } on ZCodecException catch (error) {
        detail = error.message;
        if (invalid) {
          status = 'rejected-invalid';
        } else if (command == 'bzip2' && name == 'commons-compress/zip64support.tar.bz2' && error.message == 'BZIP2 decoded output exceeds the configured limit') {
          status = 'output-limit';
        } else {
          status = 'FAIL rejected-valid';
        }
      } catch (error) {
        detail = error.toString();
        status = 'FAIL unexpected-exception';
      }
      if (status.startsWith('FAIL')) {
        failed++;
      }
      results.add({'format': command, 'file': name, 'encoded_sha256': _hash(encoded), 'status': status, 'detail': detail, 'milliseconds': watch.elapsedMilliseconds});
      stdout.writeln('$status $command/$name${status.startsWith('FAIL') ? ': $detail' : ''}');
    }
  }
  if (results.length != pinned.length) {
    throw StateError('Missing corpus files: ${results.length}/${pinned.length}');
  }
  File('build/compression-corpus-report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  stdout.writeln('${results.length} corpus cases; $failed failures');
  exitCode = failed == 0 ? 0 : 1;
}

/// Hex-encodes a digest for compact exact-byte comparisons and provenance.
String _hash(List<int> bytes) => (Sha256()..add(bytes)).close().map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
