/// RFC 1952 GZIP files: one or more DEFLATE members with optional metadata.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/checksums.dart';
import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/deflate.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'gzip/codec.dart';
part 'gzip/member.dart';
part 'gzip/member_codec.dart';
part 'gzip/streaming.dart';
part 'gzip/support.dart';
