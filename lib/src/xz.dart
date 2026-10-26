/// XZ/LZMA2 codecs, with bounded dictionaries and portable integrity checks.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/crypto.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'xz/bcj.dart';
part 'xz/checks.dart';
part 'xz/codec.dart';
part 'xz/decoder.dart';
part 'xz/encoder.dart';
part 'xz/lzma_models.dart';
part 'xz/model.dart';
part 'xz/range_coder.dart';
part 'xz/streaming.dart';
part 'xz/support.dart';
