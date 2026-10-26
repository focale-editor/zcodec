part of 'package:zcodec/src/xz.dart';

/// Probability tables and finite state shared by LZMA packet readers/writers.
final class _LzmaModels {
  /// Position context bits.
  int pb = 2;

  /// Literal position bits.
  int lp = 0;

  /// Literal previous-byte context bits.
  int lc = 3;

  /// Packet history state.
  int state = 0;

  /// Most recent match distances, stored minus one.
  final List<int> reps = List.filled(4, 0);

  /// Literal/match decisions by state and position.
  final Uint16List match = Uint16List(12 * 16);

  /// Repeated-distance packet decisions.
  final Uint16List rep = Uint16List(12);

  /// Repeated-distance index decisions.
  final Uint16List rep0 = Uint16List(12);

  /// Second repeated-distance decisions.
  final Uint16List rep1 = Uint16List(12);

  /// Third repeated-distance decisions.
  final Uint16List rep2 = Uint16List(12);

  /// Single-byte repeat decisions by state and position.
  final Uint16List shortRep = Uint16List(12 * 16);

  /// Literal trees, including matched-literal contexts.
  Uint16List literals = Uint16List(768 * 8);

  /// Match length trees.
  final Uint16List length = Uint16List(514);

  /// Repeated-match length trees.
  final Uint16List repLength = Uint16List(514);

  /// Distance slot trees by length state.
  final Uint16List slots = Uint16List(4 * 64);

  /// Reverse trees for short distances.
  final Uint16List distances = Uint16List(114);

  /// Four aligned low distance bits.
  final Uint16List align = Uint16List(16);

  /// Creates the standard lc=3, lp=0, pb=2 model.
  _LzmaModels() {
    reset(93);
  }

  /// Resets probabilities and optionally changes the encoded properties.
  void reset([int? property]) {
    if (property != null) {
      if (property >= 225) {
        throw const ZCodecException('Invalid LZMA properties');
      }
      lc = property % 9;
      lp = (property ~/ 9) % 5;
      pb = property ~/ 45;
      if (lc + lp > 4) {
        throw const ZCodecException('LZMA2 literal context exceeds four bits');
      }
      literals = Uint16List(768 * (1 << (lc + lp)));
    }
    state = 0;
    reps.fillRange(0, 4, 0);
    for (final Uint16List table in [match, rep, rep0, rep1, rep2, shortRep, literals, length, repLength, slots, distances, align]) {
      table.fillRange(0, table.length, 1024);
    }
  }

  /// Position-dependent state index.
  int positionState(int position) => position & ((1 << pb) - 1);

  /// Literal tree base offset.
  int literalBase(int position, int previous) => (((position & ((1 << lp) - 1)) << lc) + (previous >> (8 - lc))) * 768;

  /// Advances packet history after a literal.
  void literalState() => state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6);
}
