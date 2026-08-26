/// Byte- and bit-level buffer primitives shared by every ZCodec format.
library;

import 'dart:typed_data';

import 'package:zcodec/src/exception.dart';

part 'io/bit_reader.dart';
part 'io/bit_writer.dart';
part 'io/byte_reader.dart';
part 'io/byte_writer.dart';

/// Returns [input] as an unsigned byte buffer, copying only when required.
Uint8List asBytes(List<int> input) => input is Uint8List ? input : Uint8List.fromList(input);

/// Concatenates two byte sequences into one buffer.
Uint8List joinBytes(List<int> first, List<int> second) => Uint8List(first.length + second.length)
  ..setRange(0, first.length, first)
  ..setRange(first.length, first.length + second.length, second);
