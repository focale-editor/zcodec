/// Shared codec abstractions layered on top of `dart:convert`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/exception.dart';

part 'codecs/binary_codec.dart';
part 'codecs/block_sink.dart';
part 'codecs/byte_codec.dart';
part 'codecs/chunked_sinks.dart';
part 'codecs/compression_level.dart';
