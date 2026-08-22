/// ZIP archive encoding and decoding APIs.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:zcodec/src/byte_io.dart';
import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/deflate_codec.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/zip/crypto.dart';

part 'package:zcodec/src/zip/decoder.dart';
part 'package:zcodec/src/zip/encoder.dart';
part 'package:zcodec/src/zip/model.dart';
part 'package:zcodec/src/zip/support.dart';
