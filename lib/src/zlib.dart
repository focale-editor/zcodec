/// RFC 1950 zlib streams: a DEFLATE payload framed by a header and an
/// Adler-32 trailer.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/deflate.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'zlib/codec.dart';
part 'zlib/streaming.dart';
