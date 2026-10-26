part of 'package:zcodec/src/bzip2.dart';

/// Incremental encoder retaining at most one raw block and its sort workspace.
final class _BzipEncodingSink extends BlockSink {
  /// Configured block-size digit.
  final int blockSize;

  /// Conservative raw size so initial RLE never exceeds the declared block.
  final int rawSize;

  /// Shared bit alignment across blocks.
  late final _BzipWriter writer = _BzipWriter(output);

  /// Folded checksum of all emitted blocks.
  int combined = 0;

  /// Whether the member header has been written.
  bool started = false;

  /// Creates a bounded encoder.
  _BzipEncodingSink(Sink<List<int>> output, this.blockSize) : rawSize = blockSize * 80000, super(output, blockSize * 80000 + 65536);

  /// Writes the header once, including for an empty member.
  void header() {
    if (!started) {
      started = true;
      writer
        ..write(24, 0x425a68)
        ..write(8, 48 + blockSize);
    }
  }

  @override
  void process() {
    header();
    while (available >= rawSize) {
      _encodeBzipBlock(Uint8List.sublistView(buffer, start, start + rawSize), writer, (crc) => combined = _bzipCombine(combined, crc));
      start += rawSize;
      writer.flush();
    }
  }

  @override
  void finish() {
    process();
    if (available > 0) {
      _encodeBzipBlock(Uint8List.sublistView(buffer, start, end), writer, (crc) => combined = _bzipCombine(combined, crc));
      start = end;
    }
    writer
      ..write(24, 0x177245)
      ..write(24, 0x385090)
      ..write(32, combined)
      ..finish();
  }
}

/// Incrementally reads concatenated members with transactional block parsing.
final class _BzipDecodingSink extends BlockSink {
  /// Cumulative decoded byte ceiling.
  final int? maxOutputBytes;

  /// Whether non-member trailing bytes may be ignored.
  final bool allowTrailingBytes;

  /// Whether trailing data is now being discarded.
  bool trailing = false;

  /// Maximum member count.
  final int maxMembers;

  /// Decoded bytes emitted so far.
  int produced = 0;

  /// Number of headers accepted.
  int members = 0;

  /// Whether the next unit is a member header.
  bool needsHeader = true;

  /// Block capacity declared by the current member.
  int blockLimit = 0;

  /// Bit offset within the first pending byte.
  int bitOffset = 0;

  /// Expected rolling member checksum.
  int combined = 0;

  /// Retry at geometrically increasing sizes to avoid quadratic fragmented work.
  int nextAttempt = 0;

  /// Creates a bounded decoder; even maximal 20-bit symbols fit this buffer.
  _BzipDecodingSink(Sink<List<int>> output, this.maxOutputBytes, int? maxInputBytes, this.maxMembers, this.allowTrailingBytes) : super(output, 4 * 1024 * 1024, maxInputBytes: maxInputBytes) {
    if (maxOutputBytes != null && maxOutputBytes! < 0) {
      throw RangeError.value(maxOutputBytes!, 'maxOutputBytes');
    }
    if (maxMembers < 1) {
      throw RangeError.value(maxMembers, 'maxMembers');
    }
  }
  @override
  void process() {
    while (available > 0) {
      if (trailing) {
        start = end;
        return;
      }
      if (needsHeader) {
        if (available < 4) {
          return;
        }
        if (buffer[start] != 66 || buffer[start + 1] != 90 || buffer[start + 2] != 104 || buffer[start + 3] < 49 || buffer[start + 3] > 57) {
          if (allowTrailingBytes && members > 0) {
            trailing = true;
            start = end;
            return;
          }
          throw const ZCodecException('Invalid BZIP2 member header');
        }
        if (++members > maxMembers) {
          throw const ZCodecException('BZIP2 member limit exceeded');
        }
        blockLimit = (buffer[start + 3] - 48) * 100000;
        start += 4;
        combined = 0;
        bitOffset = 0;
        needsHeader = false;
      }
      if (available < nextAttempt) {
        return;
      }
      final _BzipReader reader = _BzipReader(buffer, end, start * 8 + bitOffset);
      try {
        final int first = reader.read(24);
        final int second = reader.read(24);
        if (first == 0x177245 && second == 0x385090) {
          if (reader.read(32) != combined) {
            throw const ZCodecException('BZIP2 member checksum mismatch');
          }
          start = (reader.position + 7) ~/ 8;
          bitOffset = 0;
          needsHeader = true;
        } else if (first == 0x314159 && second == 0x265359) {
          final int crc = reader.read(32);
          final (Uint8List last, int origin, bool randomized) = _readBzipBlock(reader, blockLimit);
          start = reader.position ~/ 8;
          bitOffset = reader.position & 7;
          _emitBlock(last, origin, randomized, crc);
          combined = _bzipCombine(combined, crc);
        } else {
          throw const ZCodecException('Invalid BZIP2 block marker');
        }
        nextAttempt = 0;
      } on _NeedBzipInput {
        nextAttempt = (available * 2).clamp(64, 3 * 1024 * 1024);
        return;
      }
    }
  }

  /// Reverses BWT/randomization/RLE while emitting bounded output chunks.
  void _emitBlock(Uint8List last, int origin, bool randomized, int expectedCrc) {
    final Uint32List counts = Uint32List(257);
    for (final int byte in last) {
      counts[byte + 1]++;
    }
    for (int i = 1; i < counts.length; i++) {
      counts[i] += counts[i - 1];
    }
    final Uint32List links = Uint32List(last.length);
    for (int i = 0; i < last.length; i++) {
      links[counts[last[i]]++] = i;
    }
    int row = links[origin];
    int randomPosition = 0;
    int randomCount = 0;
    int previous = -1;
    int repeats = 0;
    int crc = 0xffffffff;
    Uint8List chunk = Uint8List(8192);
    int used = 0;
    for (int i = 0; i < last.length; i++) {
      int byte = last[row];
      row = links[row];
      if (randomized) {
        if (randomCount == 0) {
          randomCount = _randomNumbers[randomPosition];
          randomPosition = (randomPosition + 1) & 511;
        }
        randomCount--;
        if (randomCount == 1) {
          byte ^= 1;
        }
      }
      final bool countByte = repeats == 4;
      final int count = countByte ? byte : 1;
      final int value = countByte ? previous : byte;
      if (maxOutputBytes != null && count > maxOutputBytes! - produced) {
        throw const ZCodecException('BZIP2 decoded output exceeds the configured limit');
      }
      produced += count;
      for (int n = 0; n < count; n++) {
        chunk[used++] = value;
        crc = _bzipUpdate(crc, value);
        if (used == chunk.length) {
          output.add(chunk);
          chunk = Uint8List(8192);
          used = 0;
        }
      }
      if (countByte) {
        repeats = 0;
        previous = -1;
      } else {
        repeats = byte == previous ? repeats + 1 : 1;
        previous = byte;
      }
    }
    if (repeats == 4 || (crc ^ 0xffffffff) != expectedCrc) {
      throw const ZCodecException('Invalid BZIP2 run or block checksum');
    }
    if (used > 0) {
      output.add(Uint8List.sublistView(chunk, 0, used));
    }
  }

  @override
  void finish() {
    nextAttempt = 0;
    process();
    if (allowTrailingBytes && members > 0 && needsHeader && available > 0 && (available > 3 || !List.generate(available, (i) => buffer[start + i] == const [66, 90, 104][i]).every((value) => value))) {
      start = end;
    }
    if (members == 0 || !needsHeader || available != 0) {
      throw const ZCodecException('Truncated BZIP2 stream');
    }
  }
}
