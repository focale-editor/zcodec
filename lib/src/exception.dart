/// Describes invalid or unsupported compressed data.
final class ZCodecException extends FormatException {
  /// Creates an exception with a human-readable [message].
  const ZCodecException(super.message);

  @override
  String toString() => 'ZCodecException: $message';
}
