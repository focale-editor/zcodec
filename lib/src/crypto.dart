/// Cryptographic primitives required by encrypted ZIP entries.
///
/// These are self-contained Dart implementations: the package deliberately
/// avoids `package:crypto` and platform APIs so that it stays dependency-free
/// on every Dart platform.
library;

import 'dart:typed_data';

part 'crypto/aes.dart';
part 'crypto/sha1.dart';
