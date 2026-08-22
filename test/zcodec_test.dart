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
