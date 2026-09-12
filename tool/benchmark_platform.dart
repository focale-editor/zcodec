import 'dart:typed_data';

/// Runtime label for benchmarks compiled without dart:io.
String get runtime => 'Dart compiled for the Web';

/// Whether a native reference compressor is available.
bool get hasNativeEncoder => false;

/// Native reference compression is unavailable on this platform.
Uint8List nativeEncode(Uint8List data, {bool fixed = false}) => throw UnsupportedError('No native zlib');

/// Resident memory is unavailable through the portable Dart API.
int? get currentRss => null;

/// Maximum resident memory is unavailable through the portable Dart API.
int? get maxRss => null;
