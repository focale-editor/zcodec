import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  group('DeflateCodec', () {
    const DeflateCodec codec = DeflateCodec();

    test('round-trips empty, repetitive, and binary data at every level', () {
      final List<Uint8List> values = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(utf8.encode('abcabcabcabcabcabc')),
        Uint8List.fromList(<int>[for (int index = 0; index < 4096; index++) (index * 31) & 0xff]),
      ];
      for (int level = 0; level <= 9; level++) {
        for (final Uint8List value in values) {
          expect(codec.decode(codec.encode(value, level: level)), orderedEquals(value));
        }
      }
    });

    test('splits stored data larger than one DEFLATE block', () {
      final Uint8List value = Uint8List.fromList(<int>[for (int index = 0; index < 70000; index++) index & 0xff]);
      expect(codec.decode(codec.encode(value, level: 0)), orderedEquals(value));
    });

    test('rejects trailing bytes and output beyond a limit', () {
      final Uint8List encoded = codec.encode(utf8.encode('bounded output'));
      expect(() => codec.decode(<int>[...encoded, 0]), throwsA(isA<ZCodecException>()));
      expect(() => codec.decode(encoded, maxOutputBytes: 4), throwsA(isA<ZCodecException>()));
    });
  });

  group('ZlibCodec', () {
    const ZlibCodec codec = ZlibCodec();

    test('emits the canonical empty stream', () {
      expect(codec.encode(const <int>[]), orderedEquals(<int>[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]));
    });

    test('decodes a dynamic-Huffman stream made by Python zlib', () {
      final Uint8List encoded = base64.decode(
        'eNrtyssRgjAUAMBWXgVUkwZAg38D0ahQvbTBzJ530znH3C6HWwy1fJ8xll9c22N6RfnkGu+N7/26xLGcukiyLMuyLMuyLMuyLMuyLMuyLMuyLMuyLMuyvM/8B4ZBny0=',
      );
      final Uint8List expected = Uint8List.fromList(utf8.encode('The quick brown fox jumps over the lazy dog. ' * 200));
      expect(codec.decode(encoded), orderedEquals(expected));
    });

    test('validates Adler-32 and the output limit', () {
      final Uint8List encoded = codec.encode(utf8.encode('checksum'));
      encoded[encoded.length - 1] ^= 1;
      expect(() => codec.decode(encoded), throwsA(isA<ZCodecException>()));
      expect(() => codec.decode(codec.encode(utf8.encode('too large')), maxOutputBytes: 2), throwsA(isA<ZCodecException>()));
    });
  });

  group('ZIP', () {
    const ZipEncoder encoder = ZipEncoder();
    const ZipDecoder decoder = ZipDecoder();

    test('round-trips stored and compressed entries with metadata', () {
      final DateTime modified = DateTime(2026, 8, 22, 12, 34, 56);
      final ZipArchive source = ZipArchive(
        comment: 'projet',
        entries: <ZipEntry>[
          ZipEntry(name: 'manifest.json', data: utf8.encode('{"format":"focale"}'), modified: modified, comment: 'metadata'),
          ZipEntry(name: 'raster/image.png', data: <int>[137, 80, 78, 71], compression: ZipCompression.store, modified: modified),
        ],
      );
      final ZipArchive decoded = decoder.decode(encoder.encode(source));
      expect(decoded.comment, 'projet');
      expect(decoded.entries.map((entry) => entry.name), <String>['manifest.json', 'raster/image.png']);
      expect(utf8.decode(decoded.find('manifest.json')!.data), '{"format":"focale"}');
      expect(decoded.find('manifest.json')!.comment, 'metadata');
      expect(decoded.find('manifest.json')!.modified, modified);
      expect(decoded.find('raster/image.png')!.data, orderedEquals(<int>[137, 80, 78, 71]));
    });

    test('decodes a UTF-8 archive made by Python zipfile', () {
      final Uint8List fixture = base64.decode(
        'UEsDBBQAAAAIAFWoFl1INYmoFQAAABMAAAANAAAAbWFuaWZlc3QuanNvbqtWSssvyk0sUbJSSstPTsxJVaoFAFBLAwQUAAAICABVqBZdtUKtmAcAAAAFAAAAEAAAAHJhc3Rlci9jYWbDqS50eHRLTkw7vBIAUEsBAhQDFAAAAAgAVagWXUg1iagVAAAAEwAAAA0AAAAAAAAAAAAAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwECFAMUAAAICABVqBZdtUKtmAcAAAAFAAAAEAAAAAAAAAAAAAAAgAFAAAAAcmFzdGVyL2NhZsOpLnR4dFBLBQYAAAAAAgACAHkAAAB1AAAABwBmaXh0dXJl',
      );
      final ZipArchive archive = decoder.decode(fixture);
      expect(archive.comment, 'fixture');
      expect(utf8.decode(archive.find('manifest.json')!.data), '{"format":"focale"}');
      expect(utf8.decode(archive.find('raster/café.txt')!.data), 'café');
    });

    test('detects a damaged stored entry when its data is requested', () {
      final Uint8List encoded = encoder.encode(
        ZipArchive(
          entries: <ZipEntry>[
            ZipEntry(name: 'x', data: <int>[1, 2, 3], compression: ZipCompression.store),
          ],
        ),
      );
      encoded[31] ^= 1;
      final ZipEntry entry = decoder.decode(encoded).entries.single;
      expect(() => entry.data, throwsA(isA<ZCodecException>()));
    });

    test('enforces central-directory limits before inflation', () {
      final Uint8List encoded = encoder.encode(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'large', data: Uint8List(32))],
        ),
      );
      expect(() => const ZipDecoder(limits: ZipLimits(maxEntryBytes: 16)).decode(encoded), throwsA(isA<ZCodecException>()));
      expect(() => const ZipDecoder(limits: ZipLimits(maxEntries: 0)).decode(encoded), throwsA(isA<ZCodecException>()));
    });

    test('identifies paths unsafe for direct extraction', () {
      expect(ZipEntry(name: '../outside', data: const <int>[]).hasSafePath, isFalse);
      expect(ZipEntry(name: 'raster/image.png', data: const <int>[]).hasSafePath, isTrue);
    });

    test('writes stored streams without buffering the complete entry', () async {
      final _CollectingSink output = _CollectingSink();
      final ZipStreamWriter writer = ZipStreamWriter(output);
      writer.add(ZipEntry(name: 'manifest.json', data: utf8.encode('{}')));
      await writer.addStoredStream(
        name: 'raster/image.png',
        data: Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4, 5],
        ]),
        size: 5,
      );
      writer.close(comment: 'streamed');
      output.close();

      final ZipArchive archive = decoder.decode(output.takeBytes());
      expect(archive.comment, 'streamed');
      expect(utf8.decode(archive.find('manifest.json')!.data), '{}');
      expect(archive.find('raster/image.png')!.data, orderedEquals(<int>[1, 2, 3, 4, 5]));
    });

    test('stream writer combines encrypted buffered entries and ZIP64 descriptors', () async {
      final _CollectingSink output = _CollectingSink();
      final ZipStreamWriter writer = ZipStreamWriter(
        output,
        passwordProvider: (name) => 'stream password',
        randomBytes: Uint8List.new,
        forceZip64: true,
      );
      writer.add(ZipEntry(name: 'secret.txt', data: utf8.encode('hidden'), encryption: ZipEncryption.aes192));
      await writer.addStoredStream(
        name: 'payload.bin',
        data: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        size: 4,
      );
      writer.close();
      output.close();

      final ZipArchive archive = ZipDecoder(passwordProvider: (name) => 'stream password').decode(output.takeBytes());
      expect(utf8.decode(archive.find('secret.txt')!.data), 'hidden');
      expect(archive.find('payload.bin')!.data, orderedEquals(<int>[1, 2, 3, 4]));
    });

    test('round-trips ZipCrypto and every WinZip AES key size', () {
      for (final ZipEncryption encryption in ZipEncryption.values.skip(1)) {
        final Uint8List encoded = encoder.encode(
          ZipArchive(
            entries: <ZipEntry>[
              ZipEntry(name: '${encryption.name}.txt', data: utf8.encode('secret payload'), encryption: encryption),
            ],
          ),
          passwordProvider: (name) => 'correct horse battery staple',
          randomBytes: (length) => Uint8List.fromList(<int>[for (int index = 0; index < length; index++) index]),
        );
        final ZipArchive archive = ZipDecoder(passwordProvider: (name) => 'correct horse battery staple').decode(encoded);
        expect(utf8.decode(archive.entries.single.data), 'secret payload');
        expect(archive.entries.single.encryption, encryption);
      }
    });

    test('rejects wrong passwords and modified AES ciphertext', () {
      final Uint8List encoded = encoder.encode(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'secret.txt', data: utf8.encode('classified'), encryption: ZipEncryption.aes256)],
        ),
        passwordProvider: (name) => 'right',
        randomBytes: Uint8List.new,
      );
      expect(
        () => ZipDecoder(passwordProvider: (name) => 'wrong').decode(encoded).entries.single.data,
        throwsA(isA<ZCodecException>()),
      );
      encoded[30 + 'secret.txt'.length + 11 + 18] ^= 1;
      expect(
        () => ZipDecoder(passwordProvider: (name) => 'right').decode(encoded).entries.single.data,
        throwsA(isA<ZCodecException>()),
      );
    });

    test('writes and reads forced ZIP64 records and entry extra fields', () {
      final Uint8List encoded = encoder.encode(
        ZipArchive(
          entries: <ZipEntry>[
            ZipEntry(name: 'large-metadata.bin', data: <int>[1, 2, 3]),
          ],
        ),
        forceZip64: true,
      );

      expect(encoded, containsAllInOrder(<int>[0x50, 0x4b, 0x06, 0x06]));
      final ZipArchive archive = decoder.decode(encoded);
      expect(archive.entries.single.data, orderedEquals(<int>[1, 2, 3]));
    });

    test('writes and reads encrypted entries spanning split ZIP volumes', () {
      final Uint8List large = Uint8List.fromList(<int>[for (int index = 0; index < 150000; index++) (index * 149 + index ~/ 251) & 0xff]);
      final List<Uint8List> volumes = encoder.encodeVolumes(
        ZipArchive(
          comment: 'split archive',
          entries: <ZipEntry>[
            ZipEntry(
              name: 'large.bin',
              data: large,
              compression: ZipCompression.store,
              encryption: ZipEncryption.aes256,
            ),
            ZipEntry(name: 'tail.txt', data: utf8.encode('end'), encryption: ZipEncryption.zipCrypto),
          ],
        ),
        volumeSize: 65536,
        passwordProvider: (name) => 'volume password',
        randomBytes: Uint8List.new,
      );

      expect(volumes.length, greaterThan(1));
      expect(volumes.every((volume) => volume.length <= 65536), isTrue);
      expect(volumes.first.take(4), orderedEquals(<int>[0x50, 0x4b, 0x07, 0x08]));
      final ZipArchive archive = ZipDecoder(passwordProvider: (name) => 'volume password').decodeVolumes(volumes);
      expect(archive.volumeCount, volumes.length);
      expect(archive.comment, 'split archive');
      expect(archive.find('large.bin')!.data, orderedEquals(large));
      expect(utf8.decode(archive.find('tail.txt')!.data), 'end');
    });

    test('combines forced ZIP64 records with split volumes', () {
      final Uint8List large = Uint8List.fromList(<int>[for (int index = 0; index < 70000; index++) index & 0xff]);
      final List<Uint8List> volumes = encoder.encodeVolumes(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'zip64.bin', data: large, compression: ZipCompression.store)],
        ),
        volumeSize: 65536,
        forceZip64: true,
      );

      expect(volumes.length, greaterThan(1));
      expect(decoder.decodeVolumes(volumes).entries.single.data, orderedEquals(large));
    });

    test('reads a central directory distributed over several volumes', () {
      final List<Uint8List> volumes = encoder.encodeVolumes(
        ZipArchive(
          entries: <ZipEntry>[
            for (int index = 0; index < 2000; index++) ZipEntry(name: 'entry-$index', data: const <int>[], compression: ZipCompression.store),
          ],
        ),
        volumeSize: 65536,
      );

      final ZipArchive archive = decoder.decodeVolumes(volumes);
      expect(volumes.length, greaterThan(2));
      expect(archive.entries.length, 2000);
      expect(archive.find('entry-1999')!.data, isEmpty);
      expect(() => decoder.decodeVolumes(volumes.sublist(1)), throwsA(isA<ZCodecException>()));
    });
  });
}

/// Collects writer chunks for in-memory stream tests.
final class _CollectingSink implements Sink<List<int>> {
  /// Accumulated chunks.
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Creates an empty collecting sink.
  _CollectingSink();

  /// Adds one output [chunk].
  @override
  void add(List<int> chunk) => _bytes.add(chunk);

  /// Marks the test sink closed without discarding its bytes.
  @override
  void close() {}

  /// Returns all chunks as one byte buffer.
  Uint8List takeBytes() => _bytes.takeBytes();
}
