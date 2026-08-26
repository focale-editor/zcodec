part of 'package:zcodec/src/tar.dart';

/// Holds name and prefix bytes selected for a ustar header.
final class _TarPathFields {
  /// Name-field bytes, limited to 100 bytes.
  final Uint8List name;

  /// Prefix-field bytes, limited to 155 bytes.
  final Uint8List prefix;

  /// Whether a PAX path override is required.
  final bool requiresPax;

  /// Creates a split ustar path representation.
  const _TarPathFields({required this.name, required this.prefix, required this.requiresPax});
}

/// Splits [path] into the ustar name and prefix fields when possible.
_TarPathFields _splitTarPath(String path) {
  final Uint8List whole = Uint8List.fromList(utf8.encode(path));
  if (whole.length <= 100) {
    return _TarPathFields(name: whole, prefix: Uint8List(0), requiresPax: false);
  }
  for (int index = path.length - 1; index > 0; index--) {
    if (path.codeUnitAt(index) != 0x2f) {
      continue;
    }
    final Uint8List prefix = Uint8List.fromList(utf8.encode(path.substring(0, index)));
    final Uint8List name = Uint8List.fromList(utf8.encode(path.substring(index + 1)));
    if (prefix.length <= 155 && name.isNotEmpty && name.length <= 100) {
      return _TarPathFields(name: name, prefix: prefix, requiresPax: false);
    }
  }
  final Uint8List fallback = whole.length <= 100 ? whole : Uint8List.fromList(utf8.encode(_tarBaseName(path)));
  return _TarPathFields(
    name: fallback.length <= 100 ? fallback : Uint8List.fromList(ascii.encode('PaxPath')),
    prefix: Uint8List(0),
    requiresPax: true,
  );
}

/// Returns the final path component of [path].
String _tarBaseName(String path) {
  final List<String> components = path.split('/');
  for (int index = components.length - 1; index >= 0; index--) {
    if (components[index].isNotEmpty) {
      return components[index];
    }
  }
  return 'entry';
}

/// Validates a nonempty TAR path without imposing extraction policy.
void _validateTarPath(String path, {required String label}) {
  if (path.isEmpty || path.contains('\u0000')) {
    throw ArgumentError.value(path, label, 'TAR paths must be nonempty and must not contain NUL');
  }
}

/// Whether [path] is relative and contains no parent traversal component.
bool _hasSafeTarPath(String path) {
  if (path.startsWith('/') || path.startsWith(r'\')) {
    return false;
  }
  final List<String> components = path.replaceAll(r'\', '/').split('/');
  return !components.contains('..') && (components.isEmpty || !components.first.contains(':'));
}

/// Returns [length] rounded up to the next TAR block boundary.
int _tarPaddedLength(int length) => ((length + _tarBlockSize - 1) ~/ _tarBlockSize) * _tarBlockSize;
