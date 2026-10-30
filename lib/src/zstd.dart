/// RFC 8878 Zstandard compression and bounded decompression in pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'zstd/bits.dart';
part 'zstd/checksum.dart';
part 'zstd/codec.dart';
part 'zstd/decoder.dart';
part 'zstd/encoder.dart';
part 'zstd/entropy.dart';
part 'zstd/streaming.dart';
part 'zstd/tables.dart';
