import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/zcodec.dart';

import 'benchmark_platform.dart' if (dart.library.io) 'benchmark_platform_io.dart' as platform;

/// Prevents benchmark results from becoming unused computations.
int _consumed = 0;

/// Measures fixed, reproducible corpora on the VM or compiled JavaScript.
///
/// Two warm-up runs precede seven measured runs. Use --json for machine-readable
/// output, --filter=text to select cases, or --memory=64 for a separate RSS run.
void main(List<String> arguments) {
  final bool json = arguments.contains('--json');
  final String filter = arguments.where((value) => value.startsWith('--filter=')).map((value) => value.substring(9)).firstOrNull ?? '';
  final String? memory = arguments.where((value) => value.startsWith('--memory=')).firstOrNull;
  if (memory != null) {
    _memory(int.parse(memory.substring(9)));
    return;
  }
  print(json ? jsonEncode(<String, Object>{'runtime': platform.runtime, 'warmups': 2, 'runs': 7}) : platform.runtime);
  final Uint8List text = _sampleData(2 * 1024 * 1024);
  final Random random = Random(1729);
  final Uint8List binary = Uint8List.fromList(List<int>.generate(2 * 1024 * 1024, (_) => random.nextInt(256)));
  final Map<String, Uint8List> corpora = <String, Uint8List>{'text': text, 'random': binary, 'repeated': Uint8List(binary.length), 'predicted': _predictedImage(1024, 2048)};
  final List<_Case> cases = <_Case>[];
  for (final MapEntry<String, Uint8List> corpus in corpora.entries) {
    for (final int level in <int>[0, 1, 6, 9]) {
      cases.add(_Case('${corpus.key}/deflate-$level', corpus.value.length, () => DeflateCodec(level: level).encode(corpus.value)));
    }
    final Uint8List compressed = const DeflateCodec().encode(corpus.value);
    cases.add(_Case('${corpus.key}/inflate', corpus.value.length, () => const DeflateCodec().decode(compressed)));
    final Uint8List zlibCompressed = const ZlibCodec().encode(corpus.value);
    cases.add(_Case('${corpus.key}/zlib-inflate', corpus.value.length, () => const ZlibCodec().decode(zlibCompressed)));
    cases.add(_Case('${corpus.key}/zlib-inflate-chunked', corpus.value.length, () => _decodeInChunks(const ZlibDecoder(), zlibCompressed)));
    if (platform.hasNativeEncoder) {
      cases.add(_Case('${corpus.key}/native-deflate-6', corpus.value.length, () => platform.nativeEncode(corpus.value)));
      final Uint8List fixed = platform.nativeEncode(corpus.value, fixed: true);
      cases.add(_Case('${corpus.key}/inflate-native-fixed', corpus.value.length, () => const DeflateCodec().decode(fixed)));
    }
  }
  final Uint8List key = Uint8List.fromList(List<int>.generate(32, (index) => index));
  final Uint8List aesInput = Uint8List.sublistView(binary, 0, 512 * 1024);
  final ZipArchive encrypted = ZipArchive(
    entries: <ZipEntry>[ZipEntry(name: 'payload.bin', data: binary, encryption: ZipEncryption.aes256)],
  );
  // A deterministic salt makes benchmark output reproducible; it is not an
  // example of salt generation for application archives.
  final ZipCodec zip = ZipCodec(passwordProvider: (_) => 'benchmark', randomBytes: Uint8List.new);
  final ZipArchive many = ZipArchive(
    entries: <ZipEntry>[
      for (int index = 0; index < 1000; index++) ZipEntry(name: 'entry-$index.txt', data: text.sublist(0, 128)),
    ],
  );
  final TarArchive deep = TarArchive(entries: <TarEntry>[TarEntry(name: '${'dir/' * 4096}file')]);
  final Uint8List tinyMember = const GzipCodec().encode(<int>[65]);
  final BytesBuilder members = BytesBuilder();
  for (int index = 0; index < 1000; index++) {
    members.add(tinyMember);
  }
  final Uint8List gzipMembers = members.takeBytes();
  cases.addAll(<_Case>[
    _Case('text/gzip-6', text.length, () => const GzipCodec().encode(text)),
    _Case('crc32', binary.length, () => crc32(binary)),
    _Case('adler32', binary.length, () => adler32(binary)),
    _Case('aes-256', aesInput.length, () => AesCipher(key).cryptWinZipCtr(aesInput)),
    _Case('pbkdf2-sha1-1000', 0, () => pbkdf2Sha1(key, key, iterations: 1000, length: 66)),
    _Case('zip/aes-single', binary.length, () => zip.encode(encrypted)),
    _Case('zip/aes-volumes', binary.length, () => zip.encodeVolumes(encrypted, volumeSize: 65536)),
    _Case('zip/1000-entries', 128000, () => const ZipCodec().encode(many)),
    _Case('tar/deep-path', 0, () => const TarCodec().encode(deep)),
    _Case('gzip/1000-tiny-members', 1000, () => const GzipMemberCodec().decode(gzipMembers)),
  ]);
  for (final _Case item in cases) {
    if (item.name.contains(filter)) {
      _report(item, json: json);
    }
  }
  print(json ? jsonEncode(<String, int>{'consumed': _consumed}) : 'Result fingerprint: $_consumed');
}

/// One benchmark action with a known amount of useful input.
final class _Case {
  /// Human-readable scenario identifier.
  final String name;

  /// Uncompressed input or output bytes represented by the action.
  final int bytes;

  /// Computation whose result is consumed after each timing.
  final Object Function() action;

  /// Creates a scenario.
  const _Case(this.name, this.bytes, this.action);
}

/// Decodes [bytes] from 64 KiB input chunks, keeping every output chunk.
List<Uint8List> _decodeInChunks(Converter<List<int>, List<int>> decoder, Uint8List bytes) {
  List<Uint8List> output = <Uint8List>[];
  final Sink<List<int>> sink = decoder.startChunkedConversion(ChunkedConversionSink<List<int>>.withCallback((chunks) => output = List<Uint8List>.from(chunks)));
  for (int offset = 0; offset < bytes.length; offset += 65536) {
    sink.add(Uint8List.sublistView(bytes, offset, min(offset + 65536, bytes.length)));
  }
  sink.close();
  return output;
}

/// Builds 8-bit image rows after horizontal prediction, as PSD and TIFF store them.
///
/// Smooth gradients with slight noise leave small differences, a small
/// alphabet on which three-byte hash chains degenerate.
Uint8List _predictedImage(int width, int height) {
  final Random random = Random(8);
  final Uint8List data = Uint8List(width * height);
  for (int row = 0; row < height; row++) {
    int previous = 0;
    for (int column = 0; column < width; column++) {
      final double value = 0.5 + 0.25 * sin(column / 97) + 0.2 * cos(row / 131) + random.nextDouble() * 0.02;
      final int sample = (value * 255).toInt();
      data[row * width + column] = (sample - previous) & 0xff;
      previous = sample;
    }
  }
  return data;
}

/// Builds a seeded semi-compressible text corpus.
Uint8List _sampleData(int length) {
  const List<String> words = <String>['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta'];
  final Random random = Random(7);
  final BytesBuilder builder = BytesBuilder();
  while (builder.length < length) {
    builder.add('${words[random.nextInt(words.length)]} ${random.nextInt(1000)}\n'.codeUnits);
  }
  return builder.takeBytes();
}

/// Measures a scenario without including fixture construction or validation.
void _report(_Case item, {required bool json}) {
  final List<int> durations = <int>[];
  Object result = 0;
  for (int run = 0; run < 9; run++) {
    final Stopwatch watch = Stopwatch()..start();
    result = item.action();
    watch.stop();
    _consumed ^= _resultSize(result);
    if (run >= 2) {
      durations.add(watch.elapsedMicroseconds);
    }
  }
  durations.sort();
  final int median = durations[3];
  final int outputBytes = _resultSize(result);
  final int? retained = result is List<GzipMember> ? result.fold<int>(0, (sum, member) => sum + member.data.buffer.lengthInBytes) : null;
  final Map<String, Object?> row = <String, Object?>{
    'case': item.name,
    'bytes': item.bytes,
    'min_ms': durations.first / 1000,
    'median_ms': median / 1000,
    'max_ms': durations.last / 1000,
    'MBps': item.bytes == 0 ? null : item.bytes / max(1, median),
    'output_bytes': result is int ? null : outputBytes,
    'retained_bytes': ?retained,
  };
  if (json) {
    print(jsonEncode(row));
  } else {
    final String throughput = item.bytes == 0 ? '' : '  ${(item.bytes / max(1, median)).toStringAsFixed(1)} MB/s';
    final String size = result is int ? '' : '  $outputBytes bytes';
    print('${item.name.padRight(30)} ${(median / 1000).toStringAsFixed(3).padLeft(10)} ms$throughput$size${retained == null ? '' : '  retained=$retained'}');
  }
}

/// Fingerprints scalar results and counts output payloads.
int _resultSize(Object result) {
  if (result is int) {
    return result;
  }
  if (result is Uint8List) {
    return result.length;
  }
  if (result is List<Uint8List>) {
    return result.fold<int>(0, (sum, bytes) => sum + bytes.length);
  }
  if (result is List<GzipMember>) {
    return result.fold<int>(0, (sum, member) => sum + member.data.length);
  }
  throw StateError('Unknown benchmark result type: ${result.runtimeType}');
}

/// Runs in a fresh process so maximum RSS belongs to one large-buffer case.
void _memory(int mebibytes) {
  RangeError.checkValueInInterval(mebibytes, 1, 1024, 'mebibytes');
  final Uint8List data = Uint8List(mebibytes * 1024 * 1024)..fillRange(0, mebibytes * 1024 * 1024, 65);
  final int? before = platform.currentRss;
  final Stopwatch watch = Stopwatch()..start();
  final Uint8List compressed = const DeflateCodec().encode(data);
  watch.stop();
  print(
    jsonEncode(<String, Object?>{
      'case': 'memory',
      'input_bytes': data.length,
      'output_bytes': compressed.length,
      'milliseconds': watch.elapsedMicroseconds / 1000,
      'rss_before': before,
      'rss_after': platform.currentRss,
      'max_rss': platform.maxRss,
      'last_input_byte': data.last,
    }),
  );
}
