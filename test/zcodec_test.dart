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
          expect(codec.decode(DeflateCodec(level: level).encode(value)), orderedEquals(value));
        }
      }
    });

    test('splits stored data larger than one DEFLATE block', () {
      final Uint8List value = Uint8List.fromList(<int>[for (int index = 0; index < 70000; index++) index & 0xff]);
      expect(codec.decode(const DeflateCodec(level: 0).encode(value)), orderedEquals(value));
    });

    test('rejects trailing bytes, invalid levels, and output beyond a limit', () {
      final Uint8List encoded = codec.encode(utf8.encode('bounded output'));
      expect(() => codec.decode(<int>[...encoded, 0]), throwsA(isA<ZCodecException>()));
      expect(() => const DeflateCodec(maxOutputBytes: 4).decode(encoded), throwsA(isA<ZCodecException>()));
      expect(() => const DeflateCodec(level: 10).encode(const <int>[1]), throwsA(isA<RangeError>()));
    });

    test('behaves as a dart:convert codec', () async {
      final Uint8List value = Uint8List.fromList(utf8.encode('converter contract' * 50));
      expect(codec.decoder.convert(codec.encoder.convert(value)), orderedEquals(value));
      final List<List<int>> chunks = await Stream<List<int>>.fromIterable(<List<int>>[
        value.sublist(0, 100),
        value.sublist(100),
      ]).transform(codec.encoder).transform(codec.decoder).toList();
      expect(chunks.single, orderedEquals(value));
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
      expect(() => const ZlibCodec(maxOutputBytes: 2).decode(codec.encode(utf8.encode('too large'))), throwsA(isA<ZCodecException>()));
    });
  });

  group('GzipCodec', () {
    const GzipCodec codec = GzipCodec();

    test('emits the canonical metadata-free empty member', () {
      expect(
        codec.encode(const <int>[]),
        orderedEquals(<int>[0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
    });

    test('round-trips concatenated members and optional metadata', () {
      final DateTime modified = DateTime.utc(2026, 8, 22, 12, 34, 56);
      const GzipMemberCodec memberCodec = GzipMemberCodec();
      final Uint8List encoded = memberCodec.encode(<GzipMember>[
        GzipMember(
          data: utf8.encode('first'),
          header: GzipHeader(
            modified: modified,
            name: 'café.txt',
            comment: 'métadonnées',
            extra: const <int>[1, 2, 3],
            operatingSystem: 3,
            isText: true,
            headerChecksum: true,
          ),
        ),
        GzipMember(data: utf8.encode('second')),
      ]);

      final List<GzipMember> members = memberCodec.decode(encoded);
      expect(members.length, 2);
      expect(utf8.decode(codec.decode(encoded)), 'firstsecond');
      expect(members.first.modified, modified);
      expect(members.first.name, 'café.txt');
      expect(members.first.comment, 'métadonnées');
      expect(members.first.extra, orderedEquals(<int>[1, 2, 3]));
      expect(members.first.operatingSystem, 3);
      expect(members.first.isText, isTrue);
      expect(members.first.headerChecksum, isTrue);
    });

    test('validates checksums, output limits, and member limits', () {
      final Uint8List damaged = codec.encode(utf8.encode('checksum'));
      damaged[damaged.length - 8] ^= 1;
      expect(() => codec.decode(damaged), throwsA(isA<ZCodecException>()));
      expect(() => const GzipCodec(maxOutputBytes: 16).decode(codec.encode(Uint8List(32))), throwsA(isA<ZCodecException>()));
      final Uint8List concatenated = const GzipMemberCodec().encode(<GzipMember>[
        GzipMember(data: const <int>[1]),
        GzipMember(data: const <int>[2]),
      ]);
      expect(() => const GzipCodec(maxMembers: 1).decode(concatenated), throwsA(isA<ZCodecException>()));
    });

    test('writes header metadata through the codec configuration', () {
      const GzipCodec named = GzipCodec(header: GzipHeader(name: 'payload.bin', isText: true));
      final GzipMember member = const GzipMemberCodec().decode(named.encode(utf8.encode('data'))).single;
      expect(member.name, 'payload.bin');
      expect(member.isText, isTrue);
      expect(utf8.decode(member.data), 'data');
    });
  });

  group('TAR', () {
    const TarCodec codec = TarCodec();

    test('round-trips ustar, links, and PAX metadata', () {
      final String longName = '${'nested/' * 40}payload.txt';
      final DateTime modified = DateTime.fromMicrosecondsSinceEpoch(1787402096123456, isUtc: true);
      final TarArchive source = TarArchive(
        entries: <TarEntry>[
          TarEntry(name: 'directory/', type: TarEntryType.directory, mode: 0x1ed, modified: modified),
          TarEntry(
            name: longName,
            data: utf8.encode('payload'),
            mode: 0x1a4,
            userId: 3000000,
            groupId: 4000000,
            userName: 'a-very-long-user-name-that-needs-pax',
            groupName: 'a-very-long-group-name-that-needs-pax',
            modified: modified,
            paxHeaders: const <String, String>{'comment': 'custom metadata'},
          ),
          TarEntry(name: 'link', type: TarEntryType.symbolicLink, linkName: longName, modified: modified),
        ],
      );

      final Uint8List encoded = codec.encode(source);
      final TarArchive archive = codec.decode(encoded);
      expect(encoded.length % 512, 0);
      expect(archive.entries.length, 3);
      expect(archive.find('directory/')!.isDirectory, isTrue);
      final TarEntry payload = archive.find(longName)!;
      expect(utf8.decode(payload.data), 'payload');
      expect(payload.userId, 3000000);
      expect(payload.groupId, 4000000);
      expect(payload.modified, modified);
      expect(payload.paxHeaders['comment'], 'custom metadata');
      expect(archive.find('link')!.linkName, longName);
    });

    test('validates checksums, limits, and extraction paths', () {
      final Uint8List damaged = codec.encode(
        TarArchive(
          entries: <TarEntry>[
            TarEntry(name: 'file', data: const <int>[1, 2, 3]),
          ],
        ),
      );
      damaged[0] ^= 1;
      expect(() => codec.decode(damaged), throwsA(isA<ZCodecException>()));
      final Uint8List encoded = codec.encode(
        TarArchive(
          entries: <TarEntry>[TarEntry(name: 'file', data: Uint8List(32))],
        ),
      );
      expect(() => const TarCodec(limits: TarLimits(maxEntryBytes: 16)).decode(encoded), throwsA(isA<ZCodecException>()));
      expect(TarEntry(name: '../outside', data: const <int>[]).hasSafePath, isFalse);
      expect(TarEntry(name: 'inside/file', data: const <int>[]).hasSafePath, isTrue);
      expect(TarEntry(name: 'link', type: TarEntryType.symbolicLink, linkName: '../outside').hasSafeLinkTarget, isFalse);
    });

    test('writes pre-epoch timestamps as GNU base-256 numbers', () {
      final DateTime modified = DateTime.utc(1900, 6, 15, 8, 30);
      final Uint8List encoded = codec.encode(
        TarArchive(
          entries: <TarEntry>[
            TarEntry(name: 'ancient', data: const <int>[1, 2, 3], modified: modified),
          ],
        ),
      );
      // The mtime field itself must carry the value, not only its PAX override.
      expect(encoded[136] & 0x80, 0x80);
      expect(codec.decode(encoded).entries.single.modified, modified);
    });

    test('reads the nanosecond PAX timestamps written by GNU tar', () {
      // Parsing such a record as a double rounds it up to the next microsecond.
      final Uint8List encoded = _paxTarArchive('precise', 'mtime=1787402096.123456789\n');
      final TarArchive archive = const TarCodec(verifyChecksum: false).decode(encoded);
      expect(archive.entries.single.modified, DateTime.fromMicrosecondsSinceEpoch(1787402096123456, isUtc: true));
    });

    test('ignores the GNU time fields that overlap the ustar prefix', () {
      final BytesBuilder output = BytesBuilder();
      final Uint8List header = _tarHeaderBlock('gnu.txt', 0, 0x30, gnu: true)
        // GNU tar stores atime and ctime where ustar stores its path prefix.
        ..setRange(345, 356, ascii.encode('14766646262'))
        ..setRange(357, 368, ascii.encode('14766646262'));
      output
        ..add(header)
        ..add(Uint8List(1024));
      final TarArchive archive = const TarCodec(verifyChecksum: false).decode(output.takeBytes());
      expect(archive.entries.single.name, 'gnu.txt');
    });

    test('behaves as a dart:convert codec', () {
      final TarArchive source = TarArchive(
        entries: <TarEntry>[TarEntry(name: 'hello.txt', data: utf8.encode('hello'))],
      );
      final Codec<TarArchive, List<int>> tarGzip = codec.fuse(const GzipCodec());
      expect(utf8.decode(tarGzip.decode(tarGzip.encode(source)).find('hello.txt')!.data), 'hello');
      expect(codec.decoder.convert(codec.encoder.convert(source)).entries.single.name, 'hello.txt');
    });

    test('preserves negative fractional PAX timestamps', () {
      final DateTime modified = DateTime.fromMicrosecondsSinceEpoch(-500000, isUtc: true);
      final Uint8List encoded = codec.encode(
        TarArchive(
          entries: <TarEntry>[TarEntry(name: 'historic', modified: modified)],
        ),
      );
      expect(codec.decode(encoded).entries.single.modified, modified);
    });
  });

  group('ZIP', () {
    const ZipCodec codec = ZipCodec();

    test('round-trips stored and compressed entries with metadata', () {
      final DateTime modified = DateTime(2026, 8, 22, 12, 34, 56);
      final ZipArchive source = ZipArchive(
        comment: 'projet',
        entries: <ZipEntry>[
          ZipEntry(name: 'manifest.json', data: utf8.encode('{"format":"focale"}'), modified: modified, comment: 'metadata'),
          ZipEntry(name: 'raster/image.png', data: <int>[137, 80, 78, 71], compression: ZipCompression.store, modified: modified),
        ],
      );
      final ZipArchive decoded = codec.decode(codec.encode(source));
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
      final ZipArchive archive = codec.decode(fixture);
      expect(archive.comment, 'fixture');
      expect(utf8.decode(archive.find('manifest.json')!.data), '{"format":"focale"}');
      expect(utf8.decode(archive.find('raster/café.txt')!.data), 'café');
    });

    test('detects a damaged stored entry when its data is requested', () {
      final Uint8List encoded = codec.encode(
        ZipArchive(
          entries: <ZipEntry>[
            ZipEntry(name: 'x', data: <int>[1, 2, 3], compression: ZipCompression.store),
          ],
        ),
      );
      encoded[31] ^= 1;
      final ZipEntry entry = codec.decode(encoded).entries.single;
      expect(() => entry.data, throwsA(isA<ZCodecException>()));
    });

    test('enforces central-directory limits before inflation', () {
      final Uint8List encoded = codec.encode(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'large', data: Uint8List(32))],
        ),
      );
      expect(() => const ZipCodec(limits: ZipLimits(maxEntryBytes: 16)).decode(encoded), throwsA(isA<ZCodecException>()));
      expect(() => const ZipCodec(limits: ZipLimits(maxEntries: 0)).decode(encoded), throwsA(isA<ZCodecException>()));
    });

    test('behaves as a dart:convert codec', () async {
      final ZipArchive source = ZipArchive(
        entries: <ZipEntry>[ZipEntry(name: 'hello.txt', data: utf8.encode('hello'))],
      );
      expect(codec.decoder.convert(codec.encoder.convert(source)).find('hello.txt'), isNotNull);
      final List<ZipArchive> decoded = await Stream<List<int>>.fromIterable(<List<int>>[
        codec.encode(source),
      ]).transform(codec.decoder).toList();
      expect(utf8.decode(decoded.single.find('hello.txt')!.data), 'hello');
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

      final ZipArchive archive = codec.decode(output.takeBytes());
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

      final ZipArchive archive = ZipCodec(passwordProvider: (name) => 'stream password').decode(output.takeBytes());
      expect(utf8.decode(archive.find('secret.txt')!.data), 'hidden');
      expect(archive.find('payload.bin')!.data, orderedEquals(<int>[1, 2, 3, 4]));
    });

    test('round-trips ZipCrypto and every WinZip AES key size', () {
      for (final ZipEncryption encryption in ZipEncryption.values.skip(1)) {
        final ZipCodec encrypted = ZipCodec(
          passwordProvider: (name) => 'correct horse battery staple',
          randomBytes: (length) => Uint8List.fromList(<int>[for (int index = 0; index < length; index++) index]),
        );
        final Uint8List encoded = encrypted.encode(
          ZipArchive(
            entries: <ZipEntry>[
              ZipEntry(name: '${encryption.name}.txt', data: utf8.encode('secret payload'), encryption: encryption),
            ],
          ),
        );
        final ZipArchive archive = encrypted.decode(encoded);
        expect(utf8.decode(archive.entries.single.data), 'secret payload');
        expect(archive.entries.single.encryption, encryption);
      }
    });

    test('rejects wrong passwords and modified AES ciphertext', () {
      final Uint8List encoded = ZipCodec(passwordProvider: (name) => 'right', randomBytes: Uint8List.new).encode(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'secret.txt', data: utf8.encode('classified'), encryption: ZipEncryption.aes256)],
        ),
      );
      expect(
        () => ZipCodec(passwordProvider: (name) => 'wrong').decode(encoded).entries.single.data,
        throwsA(isA<ZCodecException>()),
      );
      encoded[30 + 'secret.txt'.length + 11 + 18] ^= 1;
      expect(
        () => ZipCodec(passwordProvider: (name) => 'right').decode(encoded).entries.single.data,
        throwsA(isA<ZCodecException>()),
      );
    });

    test('writes and reads forced ZIP64 records and entry extra fields', () {
      final Uint8List encoded = const ZipCodec(forceZip64: true).encode(
        ZipArchive(
          entries: <ZipEntry>[
            ZipEntry(name: 'large-metadata.bin', data: <int>[1, 2, 3]),
          ],
        ),
      );

      expect(encoded, containsAllInOrder(<int>[0x50, 0x4b, 0x06, 0x06]));
      final ZipArchive archive = codec.decode(encoded);
      expect(archive.entries.single.data, orderedEquals(<int>[1, 2, 3]));
    });

    test('writes and reads encrypted entries spanning split ZIP volumes', () {
      final Uint8List large = Uint8List.fromList(<int>[for (int index = 0; index < 150000; index++) (index * 149 + index ~/ 251) & 0xff]);
      final ZipCodec encrypted = ZipCodec(passwordProvider: (name) => 'volume password', randomBytes: Uint8List.new);
      final List<Uint8List> volumes = encrypted.encodeVolumes(
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
      );

      expect(volumes.length, greaterThan(1));
      expect(volumes.every((volume) => volume.length <= 65536), isTrue);
      expect(volumes.first.take(4), orderedEquals(<int>[0x50, 0x4b, 0x07, 0x08]));
      final ZipArchive archive = encrypted.decodeVolumes(volumes);
      expect(archive.volumeCount, volumes.length);
      expect(archive.comment, 'split archive');
      expect(archive.find('large.bin')!.data, orderedEquals(large));
      expect(utf8.decode(archive.find('tail.txt')!.data), 'end');
    });

    test('combines forced ZIP64 records with split volumes', () {
      final Uint8List large = Uint8List.fromList(<int>[for (int index = 0; index < 70000; index++) index & 0xff]);
      final List<Uint8List> volumes = const ZipCodec(forceZip64: true).encodeVolumes(
        ZipArchive(
          entries: <ZipEntry>[ZipEntry(name: 'zip64.bin', data: large, compression: ZipCompression.store)],
        ),
        volumeSize: 65536,
      );

      expect(volumes.length, greaterThan(1));
      expect(codec.decodeVolumes(volumes).entries.single.data, orderedEquals(large));
    });

    test('reads a central directory distributed over several volumes', () {
      final List<Uint8List> volumes = codec.encodeVolumes(
        ZipArchive(
          entries: <ZipEntry>[
            for (int index = 0; index < 2000; index++) ZipEntry(name: 'entry-$index', data: const <int>[], compression: ZipCompression.store),
          ],
        ),
        volumeSize: 65536,
      );

      final ZipArchive archive = codec.decodeVolumes(volumes);
      expect(volumes.length, greaterThan(2));
      expect(archive.entries.length, 2000);
      expect(archive.find('entry-1999')!.data, isEmpty);
      expect(() => codec.decodeVolumes(volumes.sublist(1)), throwsA(isA<ZCodecException>()));
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

/// Builds a two-entry TAR archive whose first entry is a PAX metadata block.
///
/// Header checksums are left blank, so the archive must be decoded with
/// `verifyChecksum: false`.
Uint8List _paxTarArchive(String name, String record) {
  final Uint8List payload = Uint8List.fromList(utf8.encode('${record.length + 3} $record'));
  final BytesBuilder output = BytesBuilder();
  output
    ..add(_tarHeaderBlock('PaxHeaders/$name', payload.length, 0x78))
    ..add(payload)
    ..add(Uint8List(512 - payload.length % 512))
    ..add(_tarHeaderBlock(name, 0, 0x30))
    ..add(Uint8List(1024));
  return output.takeBytes();
}

/// Builds one 512-byte header block, in POSIX ustar or GNU format.
Uint8List _tarHeaderBlock(String name, int size, int typeFlag, {bool gnu = false}) {
  final Uint8List block = Uint8List(512)
    ..setRange(0, name.length, utf8.encode(name))
    ..setRange(124, 135, ascii.encode(size.toRadixString(8).padLeft(11, '0')))
    ..setRange(257, 265, gnu ? <int>[0x75, 0x73, 0x74, 0x61, 0x72, 0x20, 0x20, 0] : <int>[0x75, 0x73, 0x74, 0x61, 0x72, 0, 0x30, 0x30]);
  block[156] = typeFlag;
  return block;
}
