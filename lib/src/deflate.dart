/// Raw RFC 1951 DEFLATE compression.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'deflate/codec.dart';
part 'deflate/decoder.dart';
part 'deflate/dynamic_encoder.dart';
part 'deflate/encoder.dart';
part 'deflate/huffman.dart';
part 'deflate/output_buffer.dart';
part 'deflate/streaming.dart';
part 'deflate/tables.dart';
