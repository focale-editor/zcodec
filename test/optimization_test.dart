import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/deflate.dart' show buildDeflateHuffmanLengths;
import 'package:zcodec/src/io.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  group('DEFLATE block encoding', () {
    test('length-limited Huffman codes obey Kraft and minimize small alphabets', () {
      for (final List<int> values in <List<int>>[
        <int>[10000, 100, 10, 1, 1],
        <int>[1000, 10, 1, 1],
        <int>[1, 1, 1, 1, 1],
      ]) {
        final Uint8List lengths = buildDeflateHuffmanLengths(Uint32List.fromList(values), 3);
        int best = 1 << 30;
        void enumerate(int index, int used, int cost) {
          if (index == values.length) {
            if (used == 8) {
              best = min(best, cost);
            }
            return;
          }
          for (int length = 1; length <= 3; length++) {
            final int next = used + (1 << (3 - length));
            if (next <= 8) {
              enumerate(index + 1, next, cost + values[index] * length);
            }
          }
        }

        enumerate(0, 0, 0);
        expect(List<int>.generate(values.length, (index) => values[index] * lengths[index]).reduce((first, second) => first + second), best);
      }
      for (final int limit in <int>[7, 15]) {
        final Uint8List lengths = buildDeflateHuffmanLengths(Uint32List.fromList(<int>[for (int index = 0; index < 20; index++) 1 << index]), limit);
        expect(lengths.every((length) => length > 0 && length <= limit), isTrue);
        expect(lengths.fold<int>(0, (sum, length) => sum + (1 << (limit - length))), 1 << limit);
      }
    });
    test('uses the dedicated length-258 code', () {
      final Uint8List input = Uint8List(259)..fillRange(0, 259, 65);
      expect(const DeflateCodec().encode(input), orderedEquals(<int>[115, 28, 5, 0]));
    });

    test('keeps matches at distance 32768 across ring and block boundaries', () {
      final Uint8List dictionary = _randomBytes(32768);
      final Uint8List input = Uint8List(32768 * 8);
      for (int offset = 0; offset < input.length; offset += dictionary.length) {
        input.setRange(offset, offset + dictionary.length, dictionary);
      }
      for (final int level in <int>[1, 6, 9]) {
        final Uint8List compressed = DeflateCodec(level: level).encode(input);
        expect(compressed.length, lessThan(40000));
        expect(const DeflateCodec().decode(compressed), orderedEquals(input));
      }
    });

    test('switches dictionary keys between small- and large-alphabet blocks', () {
      final Random random = Random(11);
      final Uint8List input = Uint8List(65535 * 6 + 1000);
      for (int index = 0; index < input.length; index++) {
        final int region = index ~/ 65535;
        input[index] = switch (region % 3) {
          0 => random.nextInt(256),
          1 => (index % 7) + random.nextInt(3),
          _ => index >= 40 && random.nextInt(4) != 0 ? input[index - 40] : random.nextInt(256),
        };
      }
      for (final int level in <int>[3, 4, 6, 9]) {
        final Uint8List compressed = DeflateCodec(level: level).encode(input);
        expect(const DeflateCodec().decode(compressed), orderedEquals(input), reason: 'level=$level');
        final _Collector output = _Collector();
        final ByteConversionSink encoder = DeflateEncoder(level: level).startChunkedConversion(output);
        for (int offset = 0; offset < input.length; offset += 30001) {
          encoder.add(Uint8List.sublistView(input, offset, min(offset + 30001, input.length)));
        }
        encoder.close();
        expect(const DeflateCodec().decode(output.takeBytes()), orderedEquals(input), reason: 'chunked level=$level');
      }
    });

    test('bit writer round-trips fields of every width through the bit reader', () {
      final Random random = Random(13);
      final List<int> widths = List<int>.generate(5000, (_) => random.nextInt(17));
      final List<int> values = <int>[for (final int width in widths) random.nextInt(1 << 16) & ((1 << width) - 1)];
      final BitWriter writer = BitWriter();
      for (int index = 0; index < widths.length; index++) {
        writer.writeBits(values[index], widths[index]);
      }
      // Pending bits taken out by a bulk writer must continue the stream.
      final ({int bits, int count}) pending = writer.takePendingBits();
      final Uint8List head = writer.takeCompleteBytes();
      writer
        ..writeBits(pending.bits & 0xff, min(pending.count, 8))
        ..writeBits(pending.bits >>> 8, max(pending.count - 8, 0))
        ..writeBits(0x5a5, 11);
      final BitReader reader = BitReader(joinBytes(head, writer.takeBytes()));
      for (int index = 0; index < widths.length; index++) {
        expect(reader.readBits(widths[index]), values[index], reason: 'field $index');
      }
      expect(reader.readBits(11), 0x5a5);
    });

    test('uses dynamic trees and recovers compression after random regions', () {
      final Uint8List input = Uint8List(65535 * 4);
      input.setRange(0, 65535, _randomBytes(65535));
      input.setRange(65535 * 2, 65535 * 3, _randomBytes(65535));
      final Uint8List compressed = const DeflateCodec().encode(input);
      expect((compressed.first >>> 1) & 3, 0);
      expect(compressed.length, lessThan(140000));
      expect(const DeflateCodec().decode(compressed), orderedEquals(input));
      final Uint8List repeated = const DeflateCodec().encode(Uint8List(65535));
      expect((repeated.first >>> 1) & 3, 2);
      expect(repeated.length, lessThan(100));
    });

    test('compacts sparse output buffers including empty streams', () {
      for (final int size in <int>[0, 1, 32, 8193, 1048577]) {
        final Uint8List decoded = const DeflateCodec().decode(const DeflateCodec().encode(Uint8List(size)));
        expect(decoded.length, size);
        expect(decoded.buffer.lengthInBytes, lessThanOrEqualTo(size + size ~/ 4));
      }
      final Uint8List member = const GzipCodec().encode(<int>[65]);
      final BytesBuilder input = BytesBuilder();
      for (int count = 0; count < 1000; count++) {
        input.add(member);
      }
      final List<GzipMember> members = const GzipMemberCodec().decode(input.takeBytes());
      expect(members.fold<int>(0, (sum, member) => sum + member.data.buffer.lengthInBytes), 1000);
    });
  });

  group('DEFLATE decoding', () {
    test('decodes codes longer than the root lookup table', () {
      // Fibonacci frequencies push optimal Huffman codes to the 15-bit limit.
      final Uint32List frequencies = Uint32List(24);
      final List<int> symbols = <int>[];
      for (int symbol = 0; symbol < frequencies.length; symbol++) {
        frequencies[symbol] = symbol < 2 ? 1 : frequencies[symbol - 1] + frequencies[symbol - 2];
        symbols.addAll(List<int>.filled(frequencies[symbol], symbol * 11));
      }
      expect(buildDeflateHuffmanLengths(frequencies, 15).reduce(max), 15);
      symbols.shuffle(Random(3));
      final Uint8List input = Uint8List.fromList(symbols);
      final Uint8List compressed = const DeflateCodec().encode(input);
      expect(const DeflateCodec().decode(compressed), orderedEquals(input));
      for (final int chunkSize in <int>[1000, compressed.length]) {
        expect(_decodeInChunks(const DeflateDecoder(), compressed, chunkSize), orderedEquals(input));
      }
    });

    test('rejects malformed tokens with and without trailing input', () {
      final Map<String, void Function(BitWriter)> tokens = <String, void Function(BitWriter)>{
        'Reserved DEFLATE length symbol': (writer) => _writeFixedLiteral(writer, 286),
        'Reserved DEFLATE distance symbol': (writer) {
          _writeFixedLiteral(writer, 257);
          writer.writeBits(_reverse(30, 5), 5);
        },
        'Invalid DEFLATE back-reference distance': (writer) {
          _writeFixedLiteral(writer, 257);
          writer.writeBits(_reverse(10, 5), 5);
          writer.writeBits(0, 4);
        },
      };
      for (final MapEntry<String, void Function(BitWriter)> token in tokens.entries) {
        for (final int padding in <int>[0, 64]) {
          final BitWriter writer = BitWriter()
            ..writeBits(1, 1)
            ..writeBits(1, 2);
          for (int index = 0; index < 20; index++) {
            _writeFixedLiteral(writer, 97);
          }
          token.value(writer);
          _writeFixedLiteral(writer, 256);
          writer
            ..alignToByte()
            ..writeBytes(Uint8List(padding));
          final Uint8List bytes = writer.takeBytes();
          final Matcher rejected = throwsA(isA<ZCodecException>().having((error) => error.message, 'message', token.key));
          expect(() => const DeflateCodec().decoder.convertPrefix(bytes), rejected, reason: 'padding=$padding');
          expect(() => _decodeInChunks(const DeflateDecoder(), bytes, bytes.length), rejected, reason: 'padding=$padding');
        }
      }
    });

    test('enforces exact output limits on every decoding path', () {
      final Random random = Random(5);
      final Map<String, Uint8List> inputs = <String, Uint8List>{
        'zeros': Uint8List(200000),
        'random': _randomBytes(200000),
        'text': Uint8List.fromList(utf8.encode(List<String>.generate(30000, (_) => 'word${random.nextInt(500)} ').join())),
      };
      for (final MapEntry<String, Uint8List> input in inputs.entries) {
        final Uint8List data = input.value;
        final Uint8List compressed = const DeflateCodec().encode(data);
        expect(DeflateCodec(maxOutputBytes: data.length).decode(compressed), orderedEquals(data), reason: input.key);
        expect(() => DeflateCodec(maxOutputBytes: data.length - 1).decode(compressed), throwsA(isA<ZCodecException>()), reason: input.key);
        expect(_decodeInChunks(DeflateDecoder(maxOutputBytes: data.length), compressed, 4096), orderedEquals(data), reason: input.key);
        expect(() => _decodeInChunks(DeflateDecoder(maxOutputBytes: data.length - 1), compressed, 4096), throwsA(isA<ZCodecException>()), reason: input.key);
      }
    });

    test('incremental output is independent of input chunk boundaries', () {
      final Random random = Random(9);
      final Uint8List input = Uint8List(150000);
      for (int index = 0; index < input.length; index++) {
        input[index] = index % 50000 < 10000 ? random.nextInt(256) : (index % 31 == 0 ? random.nextInt(4) : input[index - 1 - random.nextInt(8)]);
      }
      for (final int level in <int>[0, 1, 6]) {
        final Uint8List compressed = DeflateCodec(level: level).encode(input);
        for (final int chunkSize in <int>[1, 9, 10, 11, 1023, 1024, 1025, 65536, compressed.length]) {
          final _Collector output = _Collector();
          final ByteConversionSink decoder = const DeflateDecoder().startChunkedConversion(output);
          for (int offset = 0; offset < compressed.length; offset += chunkSize) {
            decoder.add(Uint8List.sublistView(compressed, offset, min(offset + chunkSize, compressed.length)));
          }
          decoder.close();
          // A chunk ends at the first token boundary past 64 KiB.
          expect(output.largestChunk, lessThan(65536 + 258));
          expect(output.takeBytes(), orderedEquals(input), reason: 'level=$level, chunkSize=$chunkSize');
        }
      }
    });
  });

  group('Checksums', () {
    test('match bitwise references for typed buffers, views, and lists', () {
      expect(crc32(ascii.encode('123456789')), 0xcbf43926);
      expect(adler32(ascii.encode('Wikipedia')), 0x11e60398);
      for (final int length in <int>[0, 1, 7, 8, 9, 15, 16, 17, 5551, 5552, 5553, 100000]) {
        final Uint8List bytes = _randomBytes(length + 3);
        final Uint8List view = Uint8List.sublistView(bytes, 3);
        final List<int> list = List<int>.of(view);
        for (final List<int> input in <List<int>>[Uint8List.fromList(view), view, list]) {
          expect(crc32(input), _referenceCrc32(view), reason: 'length=$length, ${input.runtimeType}');
          expect(adler32(input), _referenceAdler32(view), reason: 'length=$length, ${input.runtimeType}');
        }
        final Crc32Accumulator accumulator = Crc32Accumulator();
        for (int offset = 0; offset < length; offset += 13) {
          accumulator.add(Uint8List.sublistView(view, offset, min(offset + 13, length)));
        }
        expect(accumulator.value, _referenceCrc32(view), reason: 'length=$length');
      }
    });
  });

  group('Incremental byte codecs', () {
    final List<ByteCodec> codecs = <ByteCodec>[
      const DeflateCodec(),
      const DeflateCodec(level: 0),
      const ZlibCodec(),
      const GzipCodec(
        header: GzipHeader(name: 'café.bin', comment: 'metadata', extra: <int>[1, 2, 3], headerChecksum: true),
      ),
    ];
    for (final ByteCodec codec in codecs) {
      final String label = '${codec.runtimeType}/${codec.encoder is DeflateEncoder ? (codec.encoder as DeflateEncoder).level : 6}';
      test('$label preserves framing through Stream.transform, including empty input', () async {
        for (final Uint8List input in <Uint8List>[Uint8List(0), _randomBytes(1000)]) {
          final BytesBuilder compressed = BytesBuilder();
          await Stream<List<int>>.fromIterable(input.isEmpty ? <List<int>>[] : <List<int>>[input]).transform(codec.encoder).forEach(compressed.add);
          final Uint8List bytes = compressed.takeBytes();
          expect(bytes, orderedEquals(codec.encode(input)));
          final BytesBuilder decoded = BytesBuilder();
          await Stream<List<int>>.fromIterable(<List<int>>[
            for (final int byte in bytes) <int>[byte],
          ]).transform(codec.decoder).forEach(decoded.add);
          expect(decoded.takeBytes(), orderedEquals(input));
        }
      });

      test('$label emits before close and is independent of input chunking', () {
        final Uint8List input = _randomBytes(180000);
        final _Collector output = _Collector();
        final ByteConversionSink encoder = codec.encoder.startChunkedConversion(output);
        encoder.add(Uint8List.sublistView(input, 0, 70000));
        expect(output.length, greaterThan(100));
        encoder.addSlice(input, 70000, input.length, true);
        encoder.close();
        expect(output.closed, isTrue);
        final Uint8List compressed = output.takeBytes();
        expect(compressed, orderedEquals(codec.encode(input)));
        expect(codec.decode(compressed), orderedEquals(input));

        final _Collector decoded = _Collector();
        final ByteConversionSink decoder = codec.decoder.startChunkedConversion(decoded);
        decoder.add(Uint8List.sublistView(compressed, 0, compressed.length ~/ 2));
        expect(decoded.length, greaterThan(0));
        decoder.add(Uint8List.sublistView(compressed, compressed.length ~/ 2));
        decoder.close();
        expect(decoded.takeBytes(), orderedEquals(input));
        expect(() => decoder.add(<int>[0]), throwsStateError);
      });

      test('$label resumes at every byte boundary and rejects truncation', () {
        final Uint8List input = Uint8List.fromList(utf8.encode('abc xyz abc abc xyz ' * 120));
        final Uint8List compressed = codec.encode(input);
        final _Collector output = _Collector();
        final ByteConversionSink decoder = codec.decoder.startChunkedConversion(output);
        for (final int byte in compressed) {
          decoder.add(<int>[byte]);
        }
        decoder.close();
        decoder.close();
        expect(output.takeBytes(), orderedEquals(input));
        for (int end = 0; end < compressed.length; end++) {
          final ByteConversionSink partial = codec.decoder.startChunkedConversion(_Collector());
          expect(() {
            partial.add(Uint8List.sublistView(compressed, 0, end));
            partial.close();
          }, throwsA(isA<ZCodecException>()));
        }
      });

      test('$label copies buffered input before a caller reuses it', () {
        final Uint8List input = _randomBytes(1000);
        final Uint8List expected = Uint8List.fromList(input);
        final _Collector output = _Collector();
        final ByteConversionSink encoder = codec.encoder.startChunkedConversion(output);
        encoder.add(input);
        input.fillRange(0, input.length, 0);
        encoder.close();
        expect(codec.decode(output.takeBytes()), orderedEquals(expected));
      });

      test('$label propagates truncated-stream errors through Stream.transform', () async {
        final Uint8List compressed = codec.encode(<int>[1, 2, 3]);
        await expectLater(
          Stream<List<int>>.value(compressed.sublist(0, compressed.length - 1)).transform(codec.decoder).toList(),
          throwsA(isA<ZCodecException>()),
        );
      });
    }

    test('limits remain cumulative across output chunks and gzip members', () {
      for (final ByteCodec codec in <ByteCodec>[const DeflateCodec(maxOutputBytes: 100000), const ZlibCodec(maxOutputBytes: 100000), const GzipCodec(maxOutputBytes: 100000)]) {
        final Uint8List compressed = codec.encode(Uint8List(200000));
        final _Collector output = _Collector();
        final ByteConversionSink decoder = codec.decoder.startChunkedConversion(output);
        expect(() {
          decoder.add(compressed);
          decoder.close();
        }, throwsA(isA<ZCodecException>()));
        expect(output.length, lessThanOrEqualTo(100000));
      }
      final Uint8List compressed = const GzipMemberCodec().encode(<GzipMember>[GzipMember(data: Uint8List(60000)), GzipMember(data: Uint8List(60000))]);
      for (final GzipCodec codec in <GzipCodec>[const GzipCodec(maxOutputBytes: 100000), const GzipCodec(maxMembers: 1)]) {
        final ByteConversionSink decoder = codec.decoder.startChunkedConversion(_Collector());
        expect(() {
          decoder.add(compressed);
          decoder.close();
        }, throwsA(isA<ZCodecException>()));
      }
    });

    test('gzip concatenation preserves CRC checks across long optional fields', () {
      final Uint8List bytes = const GzipMemberCodec().encode(<GzipMember>[
        GzipMember(
          data: <int>[1, 2, 3],
          header: GzipHeader(name: 'n' * 4000, comment: 'c' * 4000, extra: Uint8List(1024), headerChecksum: true),
        ),
        GzipMember(data: Uint8List(0)),
        GzipMember(data: <int>[4, 5, 6]),
      ]);
      final _Collector output = _Collector();
      final ByteConversionSink decoder = const GzipCodec().decoder.startChunkedConversion(output);
      for (int offset = 0; offset < bytes.length; offset += 17) {
        decoder.addSlice(bytes, offset, min(offset + 17, bytes.length), false);
      }
      decoder.close();
      expect(output.takeBytes(), orderedEquals(<int>[1, 2, 3, 4, 5, 6]));
      bytes[bytes.length - 8] ^= 1;
      expect(() => const GzipCodec().decoder.startChunkedConversion(_Collector()).add(bytes), throwsA(isA<ZCodecException>()));
    });

    test('incremental Adler-32 matches a complete checksum', () {
      final Uint8List input = _randomBytes(20000);
      final Adler32Accumulator accumulator = Adler32Accumulator();
      for (int offset = 0; offset < input.length; offset += 37) {
        accumulator.add(Uint8List.sublistView(input, offset, min(offset + 37, input.length)));
      }
      expect(accumulator.value, adler32(input));
    });
  });

  group('ZIP output', () {
    test('prepares encrypted split payloads once and estimates the exact fit', () {
      int passwords = 0;
      int salts = 0;
      final ZipCodec codec = ZipCodec(
        passwordProvider: (_) {
          passwords++;
          return 'secret';
        },
        randomBytes: (length) {
          salts++;
          return Uint8List(length);
        },
        forceZip64: true,
      );
      final ZipArchive archive = ZipArchive(
        entries: <ZipEntry>[ZipEntry(name: 'entry', data: _randomBytes(150000), encryption: ZipEncryption.aes256)],
      );
      final List<Uint8List> volumes = codec.encodeVolumes(archive, volumeSize: 65536);
      expect(volumes.length, greaterThan(1));
      expect(passwords, 1);
      expect(salts, 1);
      expect(codec.decodeVolumes(volumes).entries.single.data, orderedEquals(archive.entries.single.data));
      final Uint8List single = codec.encode(archive);
      final List<Uint8List> exactFit = codec.encodeVolumes(archive, volumeSize: single.length);
      expect(exactFit.length, 1);
      expect(exactFit.single, orderedEquals(single));
    });

    test('uses an asynchronous consumer to pause the source', () async {
      final _SlowConsumer sink = _SlowConsumer();
      final ZipStreamWriter writer = ZipStreamWriter(sink);
      int produced = 0;
      int ahead = 0;
      Stream<List<int>> source() async* {
        for (int index = 0; index < 16; index++) {
          produced++;
          ahead = max(ahead, produced - sink.consumed);
          yield Uint8List(4096)..fillRange(0, 4096, index);
        }
      }

      final Future<void> writing = writer.addStoredStream(name: 'stream', data: source(), size: 65536);
      expect(writer.close, throwsStateError);
      await writing;
      expect(sink.streamCalls, 1);
      expect(ahead, lessThanOrEqualTo(1));
      writer.close();
      await sink.close();
      final Uint8List restored = const ZipCodec().decode(sink.output.takeBytes()).entries.single.data;
      expect(restored.length, 65536);
      for (int index = 0; index < 16; index++) {
        expect(restored[index * 4096], index);
      }
    });

    test('custom flush callback bounds a plain buffering sink', () async {
      final _FlushingSink sink = _FlushingSink();
      final ZipStreamWriter writer = ZipStreamWriter(sink, flush: sink.flush);
      await writer.addStoredStream(name: 'stream', data: Stream<List<int>>.fromIterable(Iterable<Uint8List>.generate(32, (_) => Uint8List(4096))), size: 32 * 4096);
      expect(sink.peak, lessThanOrEqualTo(4096));
      expect(sink.pending, 0);
      writer.close();
      sink.close();
    });

    test('a failed stored stream cannot be finalized as a valid archive', () async {
      final ZipStreamWriter writer = ZipStreamWriter(_Collector());
      await expectLater(writer.addStoredStream(name: 'bad', data: Stream<List<int>>.value(<int>[1, 2]), size: 1), throwsA(isA<ZCodecException>()));
      expect(writer.close, throwsStateError);
    });
  });

  test('TAR handles deep paths and multibyte ustar boundaries', () {
    final List<String> names = <String>['${'dir/' * 4096}file', '${'é' * 77}/${'é' * 50}', '${'é' * 78}/${'é' * 50}', '${'d/' * 300}file///'];
    final TarArchive archive = TarArchive(entries: <TarEntry>[for (final String name in names) TarEntry(name: name)]);
    expect(const TarCodec().decode(const TarCodec().encode(archive)).entries.map((entry) => entry.name), orderedEquals(names));
  });
}

/// Builds deterministic binary input with few useful matches.
Uint8List _randomBytes(int length) {
  final Random random = Random(42);
  return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
}

/// Decodes [bytes] through [decoder] in chunks of [chunkSize] bytes.
Uint8List _decodeInChunks(Converter<List<int>, List<int>> decoder, Uint8List bytes, int chunkSize) {
  final _Collector output = _Collector();
  final Sink<List<int>> sink = decoder.startChunkedConversion(output);
  for (int offset = 0; offset < bytes.length; offset += chunkSize) {
    sink.add(Uint8List.sublistView(bytes, offset, min(offset + chunkSize, bytes.length)));
  }
  sink.close();
  return output.takeBytes();
}

/// Writes one fixed-Huffman literal/length [symbol].
void _writeFixedLiteral(BitWriter writer, int symbol) {
  final ({int code, int length}) fixed = switch (symbol) {
    <= 143 => (code: 0x30 + symbol, length: 8),
    <= 255 => (code: 0x190 + symbol - 144, length: 9),
    <= 279 => (code: symbol - 256, length: 7),
    _ => (code: 0xc0 + symbol - 280, length: 8),
  };
  writer.writeBits(_reverse(fixed.code, fixed.length), fixed.length);
}

/// Reverses the lowest [length] bits of [value], as Huffman codes are stored.
int _reverse(int value, int length) {
  int reversed = 0;
  for (int bit = 0; bit < length; bit++) {
    reversed = (reversed << 1) | ((value >>> bit) & 1);
  }
  return reversed;
}

/// Computes CRC-32 one bit at a time.
int _referenceCrc32(List<int> bytes) {
  int crc = 0xffffffff;
  for (final int byte in bytes) {
    crc ^= byte;
    for (int bit = 0; bit < 8; bit++) {
      crc = crc.isOdd ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return crc ^ 0xffffffff;
}

/// Computes Adler-32 with a modulo after every byte.
int _referenceAdler32(List<int> bytes) {
  int first = 1;
  int second = 0;
  for (final int byte in bytes) {
    first = (first + byte) % 65521;
    second = (second + first) % 65521;
  }
  return (second << 16) | first;
}

/// Retains emitted chunks to verify data, progress, and close behavior.
final class _Collector implements Sink<List<int>> {
  /// Copied output bytes.
  final BytesBuilder _bytes = BytesBuilder();

  /// Whether close was called.
  bool closed = false;

  /// Largest emitted chunk.
  int largestChunk = 0;

  /// Number of emitted bytes.
  int get length => _bytes.length;

  /// Returns the collected bytes.
  Uint8List takeBytes() => _bytes.takeBytes();

  @override
  void add(List<int> data) {
    largestChunk = max(largestChunk, data.length);
    _bytes.add(data);
  }

  @override
  void close() => closed = true;
}

/// An output that processes one stream chunk asynchronously at a time.
final class _SlowConsumer implements Sink<List<int>>, StreamConsumer<List<int>> {
  /// Serialized bytes.
  final _Collector output = _Collector();

  /// Number of consumed source chunks.
  int consumed = 0;

  /// Number of calls to the paced consumption method.
  int streamCalls = 0;

  @override
  void add(List<int> data) => output.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    streamCalls++;
    await for (final List<int> chunk in stream) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      output.add(chunk);
      consumed++;
    }
  }

  @override
  Future<void> close() async => output.close();
}

/// Plain Sink with an explicit asynchronous drain operation.
final class _FlushingSink implements Sink<List<int>> {
  /// Number of queued bytes.
  int pending = 0;

  /// Maximum queue size observed.
  int peak = 0;

  @override
  void add(List<int> data) {
    pending += data.length;
    peak = max(peak, pending);
  }

  /// Simulates the destination accepting its pending bytes.
  Future<void> flush() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    pending = 0;
  }

  @override
  void close() {}
}
