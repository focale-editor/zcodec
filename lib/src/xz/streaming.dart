part of 'package:zcodec/src/xz.dart';

/// Emits a single XZ stream incrementally, retaining only one block and index.
final class _XzEncodingSink extends BlockSink {
  /// Stream-wide integrity algorithm.
  final XzCheck check;

  /// Raw block target.
  final int blockSize;

  /// Maximum index records.
  final int maxBlocks;

  /// Observed unpadded and decoded block sizes for the index.
  final List<(int, int)> records = [];

  /// Whether the stream header was emitted.
  bool started = false;

  /// Creates bounded block storage.
  _XzEncodingSink(Sink<List<int>> output, this.check, this.blockSize, this.maxBlocks) : super(output, blockSize + 65536);

  /// Emits the signature and checked stream flags once.
  void header() {
    if (!started) {
      started = true;
      output.add([
        ..._xzMagic,
        ..._xzWithCrc(Uint8List.fromList([0, check.id])),
      ]);
    }
  }

  /// Encodes one block with independent 64-KiB LZMA2 chunks.
  void block(Uint8List bytes) {
    if (records.length >= maxBlocks) {
      throw const ZCodecException('XZ block limit exceeded');
    }
    // One LZMA2 filter with a 64-KiB dictionary, no optional size fields.
    final Uint8List header = _xzWithCrc(Uint8List.fromList([2, 0, 33, 1, 8, 0, 0, 0]));
    output.add(header);
    int packed = 0;
    for (int cursor = 0; cursor < bytes.length; cursor += 65536) {
      final int end = (cursor + 65536).clamp(0, bytes.length);
      final Uint8List raw = Uint8List.sublistView(bytes, cursor, end);
      final Uint8List compressed = _encodeLzma(raw);
      final int size = raw.length - 1;
      if (compressed.length < raw.length && compressed.length <= 65536) {
        final int encodedSize = compressed.length - 1;
        output.add([0xe0 | (size >>> 16), (size >>> 8) & 255, size & 255, encodedSize >>> 8, encodedSize & 255, 93]);
        output.add(compressed);
        packed += 6 + compressed.length;
      } else {
        output.add([1, size >>> 8, size & 255]);
        output.add(Uint8List.fromList(raw));
        packed += 3 + raw.length;
      }
    }
    output.add(const [0]);
    packed++;
    output.add(Uint8List((-packed) & 3));
    final _XzDigest digest = _XzDigest(check)..add(bytes);
    output.add(digest.finish());
    records.add((header.length + packed + check.size, bytes.length));
  }

  @override
  void process() {
    header();
    while (available >= blockSize) {
      block(Uint8List.sublistView(buffer, start, start + blockSize));
      start += blockSize;
    }
  }

  @override
  void finish() {
    process();
    if (available != 0) {
      block(Uint8List.sublistView(buffer, start, end));
      start = end;
    }
    final Uint8List index = _xzIndex(records);
    output.add(index);
    final ByteWriter footer = ByteWriter()
      ..writeUint32(index.length ~/ 4 - 1)
      ..writeByte(0)
      ..writeByte(check.id);
    final Uint8List fields = footer.takeBytes();
    final ByteWriter result = ByteWriter()
      ..writeUint32(crc32(fields))
      ..writeBytes(fields)
      ..writeBytes(const [89, 90]);
    output.add(result.takeBytes());
  }
}

/// Parsing stages, each requiring only a bounded unit of encoded input.
enum _XzStage { header, blockHeader, chunks, blockPadding, check, streamIndex, footer, padding }

/// Stateful Delta decoder; multiple Delta filters are applied in reverse order.
final class _DeltaDecoder implements _XzFilter {
  /// Back-reference distance from one through 256 bytes.
  final int distance;

  /// Circular filter history.
  final Uint8List history = Uint8List(256);

  /// Current circular position.
  int position = 0;

  /// Creates an empty Delta history.
  _DeltaDecoder(this.distance);

  /// Reconstructs original bytes in place.
  @override
  Uint8List decode(Uint8List bytes, {bool last = false}) {
    for (int i = 0; i < bytes.length; i++) {
      final int value = (bytes[i] + history[(position - distance) & 255]) & 255;
      bytes[i] = value;
      history[position] = value;
      position = (position + 1) & 255;
    }
    return bytes;
  }
}

/// Incremental XZ parser whose dictionary and index allocations are bounded.
final class _XzDecodingSink extends BlockSink {
  /// Decoding limits captured from the immutable converter.
  final XzDecoder options;

  /// Current parser stage.
  _XzStage stage = _XzStage.header;

  /// Current stream check.
  XzCheck check = XzCheck.none;

  /// Accepted stream count.
  int streams = 0;

  /// Cumulative block count.
  int blocks = 0;

  /// Total output bytes across streams.
  int produced = 0;

  /// Padding count modulo four between streams.
  int streamPadding = 0;

  /// Observed current-stream block sizes.
  final List<(int, int)> records = [];

  /// Expected canonical index, compared incrementally with encoded bytes.
  Uint8List index = Uint8List(0);

  /// Number of checked index bytes.
  int indexOffset = 0;

  /// Current block header byte size.
  int headerSize = 0;

  /// Compressed bytes consumed in the current block, including LZMA2 terminator.
  int packed = 0;

  /// Decoded bytes in the current block.
  int unpacked = 0;

  /// Optional declared compressed size.
  int? expectedPacked;

  /// Optional declared uncompressed size.
  int? expectedUnpacked;

  /// Per-block bounded LZMA history.
  _LzmaDecoder? lzma;

  /// Delta filter histories, in encoded order.
  final List<_XzFilter> filters = [];

  /// Current payload integrity state.
  _XzDigest? digest;

  /// Whether LZMA2 still requires dictionary initialization.
  bool needsDictionary = true;

  /// Whether LZMA properties must be supplied before a compressed chunk.
  bool needsProperties = true;

  /// Whether LZMA probabilities must be reset before a compressed chunk.
  bool needsState = true;

  /// Creates parser state after validating caller limits.
  _XzDecodingSink(Sink<List<int>> output, this.options) : super(output, 196608, maxInputBytes: options.maxInputBytes) {
    if (options.maxOutputBytes != null && options.maxOutputBytes! < 0) {
      throw RangeError.value(options.maxOutputBytes!, 'maxOutputBytes');
    }
    if (options.maxDictionaryBytes < 0 || options.maxStreams < 1 || options.maxBlocks < 1) {
      throw ArgumentError('XZ dictionary limit must be nonnegative and stream/block limits positive');
    }
  }

  /// Returns a view of a complete pending unit.
  Uint8List view(int count) => Uint8List.sublistView(buffer, start, start + count);
  @override
  void process() {
    while (true) {
      switch (stage) {
        case _XzStage.header:
          if (available < 12) {
            return;
          }
          if (!_xzEqual(view(6), _xzMagic)) {
            throw const ZCodecException('Invalid XZ signature');
          }
          final Uint8List flags = _xzVerifyCrc(Uint8List.sublistView(buffer, start + 6, start + 12));
          if (flags[0] != 0 || flags[1] & 240 != 0) {
            throw const ZCodecException('Unsupported XZ stream flags');
          }
          check = switch (flags[1]) {
            0 => XzCheck.none,
            1 => XzCheck.crc32,
            4 => XzCheck.crc64,
            10 => XzCheck.sha256,
            _ => throw const ZCodecException('Unsupported XZ integrity check'),
          };
          if (++streams > options.maxStreams) {
            throw const ZCodecException('XZ stream limit exceeded');
          }
          start += 12;
          records.clear();
          stage = _XzStage.blockHeader;
        case _XzStage.blockHeader:
          if (available == 0) {
            return;
          }
          if (buffer[start] == 0) {
            index = _xzIndex(records);
            indexOffset = 0;
            stage = _XzStage.streamIndex;
            continue;
          }
          final int length = (buffer[start] + 1) * 4;
          if (available < length) {
            return;
          }
          _blockHeader(view(length));
          start += length;
          stage = _XzStage.chunks;
        case _XzStage.chunks:
          if (!_chunk()) {
            return;
          }
        case _XzStage.blockPadding:
          final int length = (-packed) & 3;
          if (available < length) {
            return;
          }
          if (view(length).any((byte) => byte != 0)) {
            throw const ZCodecException('Nonzero XZ block padding');
          }
          start += length;
          stage = _XzStage.check;
        case _XzStage.check:
          if (available < check.size) {
            return;
          }
          if (!_xzEqual(view(check.size), digest!.finish())) {
            throw const ZCodecException('XZ block integrity check mismatch');
          }
          start += check.size;
          records.add((headerSize + packed + check.size, unpacked));
          lzma = null;
          digest = null;
          stage = _XzStage.blockHeader;
        case _XzStage.streamIndex:
          final int count = available.clamp(0, index.length - indexOffset);
          for (int i = 0; i < count; i++) {
            if (buffer[start + i] != index[indexOffset + i]) {
              throw const ZCodecException('XZ index does not match decoded blocks');
            }
          }
          start += count;
          indexOffset += count;
          if (indexOffset != index.length) {
            return;
          }
          stage = _XzStage.footer;
        case _XzStage.footer:
          if (available < 12) {
            return;
          }
          final ByteData footer = ByteData.sublistView(view(12));
          if (footer.getUint32(0, Endian.little) != crc32(Uint8List.sublistView(buffer, start + 4, start + 10)) ||
              footer.getUint32(4, Endian.little) != index.length ~/ 4 - 1 ||
              buffer[start + 8] != 0 ||
              buffer[start + 9] != check.id ||
              buffer[start + 10] != 89 ||
              buffer[start + 11] != 90) {
            throw const ZCodecException('Invalid XZ footer');
          }
          start += 12;
          index = Uint8List(0);
          records.clear();
          streamPadding = 0;
          stage = _XzStage.padding;
        case _XzStage.padding:
          while (available > 0 && buffer[start] == 0) {
            start++;
            streamPadding = (streamPadding + 1) & 3;
          }
          if (available == 0) {
            return;
          }
          if (streamPadding != 0) {
            throw const ZCodecException('XZ stream padding is not a multiple of four');
          }
          stage = _XzStage.header;
      }
    }
  }

  /// Validates a complete block header before allocating its dictionary.
  void _blockHeader(Uint8List bytes) {
    final ByteReader reader = ByteReader(_xzVerifyCrc(bytes))..skip(1);
    final int flags = reader.readByte();
    if (flags & 0x3c != 0) {
      throw const ZCodecException('Reserved XZ block flags');
    }
    if (++blocks > options.maxBlocks) {
      throw const ZCodecException('XZ block limit exceeded');
    }
    expectedPacked = flags & 64 == 0 ? null : _readXzNumber(reader);
    expectedUnpacked = flags & 128 == 0 ? null : _readXzNumber(reader);
    if (expectedPacked == 0) {
      throw const ZCodecException('XZ block has zero compressed size');
    }
    if (options.maxOutputBytes != null && expectedUnpacked != null && expectedUnpacked! > options.maxOutputBytes! - produced) {
      throw const ZCodecException('XZ declared output exceeds the configured limit');
    }
    final int filterCount = (flags & 3) + 1;
    int dictionarySize = 0;
    filters.clear();
    for (int i = 0; i < filterCount; i++) {
      final int id = _readXzNumber(reader);
      final int size = _readXzNumber(reader);
      final Uint8List properties = reader.readBytes(size);
      if (i == filterCount - 1) {
        if (id != 33 || size != 1 || properties[0] > 40) {
          throw ZCodecException('Unsupported or invalid XZ terminal filter $id');
        }
        final int property = properties[0];
        dictionarySize = property == 40 ? 0xffffffff : (2 | (property & 1)) * (1 << ((property >> 1) + 11));
      } else if (id == 3 && size == 1) {
        filters.add(_DeltaDecoder(properties[0] + 1));
      } else if ((id == 4 || id == 5 || id == 10) && (size == 0 || size == 4)) {
        final int offset = size == 0 ? 0 : ByteData.sublistView(properties).getUint32(0, Endian.little);
        if (id != 4 && offset % 4 != 0) {
          throw const ZCodecException('Unaligned XZ BCJ start offset');
        }
        filters.add(_BcjDecoder(id, offset));
      } else {
        throw ZCodecException('Unsupported XZ prefilter $id');
      }
    }
    while (reader.remaining > 0) {
      if (reader.readByte() != 0) {
        throw const ZCodecException('Nonzero XZ header padding');
      }
    }
    if (dictionarySize > options.maxDictionaryBytes) {
      throw const ZCodecException('XZ dictionary exceeds the configured limit');
    }
    lzma = _LzmaDecoder(dictionarySize);
    digest = _XzDigest(check);
    headerSize = bytes.length;
    packed = unpacked = 0;
    needsDictionary = needsProperties = needsState = true;
  }

  /// Consumes one fully buffered LZMA2 chunk without speculative state changes.
  bool _chunk() {
    if (available == 0) {
      return false;
    }
    final int control = buffer[start];
    if (control == 0) {
      start++;
      packed++;
      if ((expectedPacked != null && packed != expectedPacked) || (expectedUnpacked != null && unpacked != expectedUnpacked)) {
        throw const ZCodecException('XZ block sizes disagree with the header');
      }
      Uint8List tail = Uint8List(0);
      for (final _XzFilter filter in filters.reversed) {
        tail = filter.decode(tail, last: true);
      }
      digest!.add(tail);
      if (tail.isNotEmpty) {
        output.add(tail);
      }
      stage = _XzStage.blockPadding;
      return true;
    }
    if (control > 2 && control < 128) {
      throw const ZCodecException('Invalid LZMA2 control byte');
    }
    final bool compressed = control >= 128;
    final int header = compressed ? (control >= 192 ? 6 : 5) : 3;
    if (available < header) {
      return false;
    }
    final int size = ((compressed ? control & 31 : 0) * 65536 + buffer[start + 1] * 256 + buffer[start + 2]) + 1;
    final int encoded = compressed ? buffer[start + 3] * 256 + buffer[start + 4] + 1 : size;
    if (options.maxOutputBytes != null && size > options.maxOutputBytes! - produced) {
      throw const ZCodecException('XZ decoded output exceeds the configured limit');
    }
    if (expectedUnpacked != null && size > expectedUnpacked! - unpacked) {
      throw const ZCodecException('LZMA2 chunk exceeds the declared block output');
    }
    if (expectedPacked != null && header + encoded > expectedPacked! - packed) {
      throw const ZCodecException('LZMA2 chunk exceeds the declared compressed block');
    }
    if (available < header + encoded) {
      return false;
    }
    final _LzmaDecoder decoder = lzma!;
    if (control == 1 || control >= 224) {
      decoder.resetDictionary();
      needsDictionary = false;
      needsProperties = true;
    }
    if (needsDictionary) {
      throw const ZCodecException('LZMA2 dictionary reset is missing');
    }
    final Uint8List encodedBytes = Uint8List.sublistView(buffer, start + header, start + header + encoded);
    Uint8List bytes;
    if (compressed) {
      if (control >= 192) {
        decoder.models.reset(buffer[start + 5]);
        needsProperties = needsState = false;
      } else if (control >= 160) {
        decoder.models.reset();
        needsState = false;
      }
      if (needsState || needsProperties) {
        throw const ZCodecException('LZMA2 probability or property reset is missing');
      }
      bytes = decoder.decode(encodedBytes, size);
    } else {
      decoder.stored(encodedBytes);
      bytes = Uint8List.fromList(encodedBytes);
      needsState = true;
    }
    for (final _XzFilter filter in filters.reversed) {
      bytes = filter.decode(bytes);
    }
    digest!.add(bytes);
    output.add(bytes);
    produced += size;
    unpacked += size;
    packed += header + encoded;
    start += header + encoded;
    return true;
  }

  @override
  void finish() {
    process();
    if (streams == 0 || stage != _XzStage.padding || streamPadding != 0 || available != 0) {
      throw const ZCodecException('Truncated XZ stream');
    }
  }
}
