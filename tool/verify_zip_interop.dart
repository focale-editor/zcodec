import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcodec/zcodec.dart';

/// Verifies ZIP encryption, ZIP64, and split-volume interoperability with 7-Zip.
Future<void> main() async {
  final Directory temporary = await Directory.systemTemp.createTemp('zcodec-interop-');
  try {
    final Uint8List payload = Uint8List.fromList(<int>[for (int index = 0; index < 150000; index++) (index * 149 + index ~/ 251) & 0xff]);
    final ZipArchive source = ZipArchive(
      entries: <ZipEntry>[
        ZipEntry(name: 'payload.bin', data: payload, compression: ZipCompression.store, encryption: ZipEncryption.aes256),
      ],
    );
    final ZipCodec encrypted = ZipCodec(passwordProvider: (name) => 'secret', randomBytes: Uint8List.new);
    final File aes = File('${temporary.path}/aes.zip');
    await aes.writeAsBytes(encrypted.encode(source));
    await _run7Zip(<String>['t', '-psecret', aes.path]);

    final File zipCrypto = File('${temporary.path}/zipcrypto.zip');
    await zipCrypto.writeAsBytes(
      encrypted.encode(
        ZipArchive(
          entries: <ZipEntry>[
            ZipEntry(name: 'payload.bin', data: payload, compression: ZipCompression.store, encryption: ZipEncryption.zipCrypto),
          ],
        ),
      ),
    );
    await _run7Zip(<String>['t', '-psecret', zipCrypto.path]);

    final File zip64 = File('${temporary.path}/zip64.zip');
    await zip64.writeAsBytes(ZipCodec(passwordProvider: (name) => 'secret', forceZip64: true).encode(source));
    await _run7Zip(<String>['t', '-psecret', zip64.path]);

    final List<Uint8List> volumes = encrypted.encodeVolumes(source, volumeSize: 65536);
    await _writeSplitVolumes(temporary, 'split', volumes);
    await _run7Zip(<String>['t', '-psecret', '${temporary.path}/split.zip']);

    final File streamed = File('${temporary.path}/streamed-zip64.zip');
    final IOSink streamedSink = streamed.openWrite();
    final ZipStreamWriter streamWriter = ZipStreamWriter(streamedSink, forceZip64: true);
    await streamWriter.addStoredStream(
      name: 'payload.bin',
      data: Stream<List<int>>.fromIterable(<List<int>>[
        payload.sublist(0, 75000),
        payload.sublist(75000),
      ]),
      size: payload.length,
    );
    streamWriter.close();
    await streamedSink.close();
    await _run7Zip(<String>['t', streamed.path]);

    final File input = File('${temporary.path}/external.txt');
    await input.writeAsString('7-Zip interoperability');
    final File externalAes = File('${temporary.path}/external-aes.zip');
    await _run7Zip(<String>['a', '-tzip', '-psecret', '-mem=AES256', externalAes.path, input.path]);
    final ZipArchive decodedAes = encrypted.decode(await externalAes.readAsBytes());
    if (utf8.decode(decodedAes.entries.single.data) != '7-Zip interoperability') {
      throw StateError('ZCodec did not decode the 7-Zip AES archive correctly');
    }

    final File externalZipCrypto = File('${temporary.path}/external-zipcrypto.zip');
    await _run7Zip(<String>['a', '-tzip', '-psecret', '-mem=ZipCrypto', externalZipCrypto.path, input.path]);
    final ZipArchive decodedZipCrypto = encrypted.decode(await externalZipCrypto.readAsBytes());
    if (utf8.decode(decodedZipCrypto.entries.single.data) != '7-Zip interoperability') {
      throw StateError('ZCodec did not decode the 7-Zip ZipCrypto archive correctly');
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Writes [volumes] using conventional `.z01` through `.zip` names.
Future<void> _writeSplitVolumes(Directory directory, String baseName, List<Uint8List> volumes) async {
  for (int index = 0; index < volumes.length; index++) {
    final bool finalVolume = index == volumes.length - 1;
    final String suffix = finalVolume ? 'zip' : 'z${(index + 1).toString().padLeft(2, '0')}';
    await File('${directory.path}/$baseName.$suffix').writeAsBytes(volumes[index]);
  }
}

/// Runs 7-Zip with [arguments] and rejects a nonzero exit code.
Future<void> _run7Zip(List<String> arguments) async {
  final ProcessResult result = await Process.run('7z', arguments);
  if (result.exitCode != 0) {
    throw ProcessException('7z', arguments, '${result.stdout}\n${result.stderr}', result.exitCode);
  }
}
