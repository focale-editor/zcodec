/// POSIX ustar, GNU, and PAX TAR archives.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcodec/src/codecs.dart';
import 'package:zcodec/src/exception.dart';
import 'package:zcodec/src/io.dart';

part 'tar/codec.dart';
part 'tar/decoder.dart';
part 'tar/encoder.dart';
part 'tar/header.dart';
part 'tar/model.dart';
part 'tar/paths.dart';
part 'tar/pax.dart';
