import 'dart:io' as io;
import 'dart:typed_data';

/// Runtime and architecture reported by the SDK.
String get runtime => io.Platform.version;

/// Whether a native reference compressor is available.
bool get hasNativeEncoder => true;

/// Compresses using the native SDK implementation for comparison only.
Uint8List nativeEncode(Uint8List data, {bool fixed = false}) => Uint8List.fromList(io.ZLibCodec(raw: true, strategy: fixed ? io.ZLibOption.strategyFixed : io.ZLibOption.strategyDefault).encode(data));

/// Current resident memory of this benchmark process.
int get currentRss => io.ProcessInfo.currentRss;

/// Largest resident memory observed during this process.
int get maxRss => io.ProcessInfo.maxRss;
