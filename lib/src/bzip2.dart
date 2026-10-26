/// BZIP2 byte codecs with bounded block storage and mandatory integrity checks.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'bzip2/bits.dart';
part 'bzip2/codec.dart';
part 'bzip2/decoder.dart';
part 'bzip2/encoder.dart';
part 'bzip2/streaming.dart';
part 'bzip2/tables.dart';
