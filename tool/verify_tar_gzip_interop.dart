import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcodec/zcodec.dart';

/// Verifies TAR/GZIP tools and optionally a source archive passed by path.
Future<void> main(List<String> arguments) async {
  final Directory temporary = await Directory.systemTemp.createTemp('zcodec-tar-gzip-');
  try {
    await _verifyZCodecOutput(temporary);
    await _verifyExternalOutput(temporary);
    if (arguments.isNotEmpty) {
      await _verifySourceArchive(File(arguments.single));
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Decodes a real-world `.tar.gz` [archive] and checks for regular content.
Future<void> _verifySourceArchive(File archive) async {
  final Uint8List tarBytes = const GzipCodec().decode(
    await archive.readAsBytes(),
    maxOutputBytes: 2 * 1024 * 1024 * 1024,
  );
  final TarArchive decoded = const TarDecoder().decode(tarBytes);
  if (decoded.entries.isEmpty || !decoded.entries.any((entry) => entry.type == TarEntryType.regular && entry.data.isNotEmpty)) {
    throw StateError('${archive.path} did not contain a nonempty regular TAR entry');
  }
}

/// Checks that GNU tar and gzip accept archives emitted by ZCodec.
Future<void> _verifyZCodecOutput(Directory temporary) async {
  final String longName = '${'nested/' * 40}payload.txt';
  final TarArchive archive = TarArchive(
    entries: <TarEntry>[
      TarEntry(name: 'directory/', type: TarEntryType.directory),
      TarEntry(name: 'directory/hello.txt', data: utf8.encode('hello from ZCodec')),
      TarEntry(name: longName, data: utf8.encode('long PAX path')),
      TarEntry(name: 'link', type: TarEntryType.symbolicLink, linkName: 'directory/hello.txt'),
    ],
  );
  final Uint8List tarBytes = const TarEncoder().encode(archive);
  final File tarFile = File('${temporary.path}/zcodec.tar');
  await tarFile.writeAsBytes(tarBytes);
  await _run('tar', <String>['-tf', tarFile.path]);

  final File gzipFile = File('${temporary.path}/zcodec.tar.gz');
  await gzipFile.writeAsBytes(const GzipCodec().encode(tarBytes, name: 'zcodec.tar', headerChecksum: true));
  await _run('gzip', <String>['-t', gzipFile.path]);
  await _run('tar', <String>['-tzf', gzipFile.path]);
}

/// Checks that ZCodec accepts ustar, GNU, PAX, and GZIP command output.
Future<void> _verifyExternalOutput(Directory temporary) async {
  final Directory source = Directory('${temporary.path}/source');
  await source.create();
  await File('${source.path}/hello.txt').writeAsString('hello from external tar');
  final Directory nested = Directory('${source.path}/${'nested/' * 25}');
  await nested.create(recursive: true);
  await File('${nested.path}/payload.txt').writeAsString('long external path');
  await Link('${source.path}/link').create('hello.txt');

  for (final String format in <String>['ustar', 'gnu', 'pax']) {
    final File archive = File('${temporary.path}/external-$format.tar');
    final List<String> members = format == 'ustar' ? <String>['hello.txt', 'link'] : <String>['.'];
    await _run('tar', <String>['--format=$format', '-cf', archive.path, '-C', source.path, ...members]);
    final TarArchive decoded = const TarDecoder().decode(await archive.readAsBytes());
    final TarEntry hello = decoded.entries.firstWhere((entry) => entry.name.endsWith('hello.txt'));
    if (utf8.decode(hello.data) != 'hello from external tar') {
      throw StateError('ZCodec did not decode the external $format TAR archive correctly');
    }
  }

  final File input = File('${temporary.path}/gzip-input.txt');
  await input.writeAsString('external gzip payload');
  final ProcessResult result = await Process.run('gzip', <String>['-c', input.path], stdoutEncoding: null);
  if (result.exitCode != 0 || result.stdout is! List<int>) {
    throw ProcessException('gzip', <String>['-c', input.path], '${result.stderr}', result.exitCode);
  }
  final Uint8List compressed = Uint8List.fromList(result.stdout as List<int>);
  if (utf8.decode(const GzipCodec().decode(compressed)) != 'external gzip payload') {
    throw StateError('ZCodec did not decode the external GZIP file correctly');
  }
}

/// Runs [executable] with [arguments] and rejects a nonzero exit code.
Future<void> _run(String executable, List<String> arguments) async {
  final ProcessResult result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(executable, arguments, '${result.stdout}\n${result.stderr}', result.exitCode);
  }
}
