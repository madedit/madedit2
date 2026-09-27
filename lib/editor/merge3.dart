// Three-way merge core (View → Three-Way Merge…): base + left + right → chunks.
//
// Pure Dart, no flutter imports (headless-testable: tool/merge3_test.dart).
// diff3 style: the two line diffs base→left and base→right are computed with
// diff.dart's Myers, their hunks are laid over the base and coalesced into
// regions wherever they overlap or touch (touching counts, as in git's
// xdiff merge: an insert right where the other side edited is a conflict).
// A region changed on one side only is taken from that side; changed
// identically on both is taken once; changed differently is a conflict the
// user resolves with a [MergeChoice].

import 'dart:math' as math;

import 'diff.dart';

enum MergeKind { same, leftOnly, rightOnly, bothSame, conflict }

/// How a conflict chunk is resolved in the output.
enum MergeChoice { unresolved, left, right, base, leftRight, rightLeft }

/// One aligned region: `[b0, b1)` of base corresponds to `[l0, l1)` of left
/// and `[r0, r1)` of right.
class MergeChunk {
  const MergeChunk(
    this.kind,
    this.b0,
    this.b1,
    this.l0,
    this.l1,
    this.r0,
    this.r1,
  );
  final MergeKind kind;
  final int b0, b1, l0, l1, r0, r1;

  int get baseLen => b1 - b0;
  int get leftLen => l1 - l0;
  int get rightLen => r1 - r0;

  /// Display rows the chunk occupies side by side (a change that deletes on
  /// every side still gets one row so it stays visible).
  int get rows {
    final n = math.max(baseLen, math.max(leftLen, rightLen));
    return kind == MergeKind.same ? n : math.max(1, n);
  }

  @override
  String toString() => '$kind b[$b0,$b1) l[$l0,$l1) r[$r0,$r1)';
}

class MergeResult {
  const MergeResult({
    required this.chunks,
    required this.conflicts,
    required this.coarse,
  });
  final List<MergeChunk> chunks;

  /// Indices into [chunks] of the conflict chunks, in order.
  final List<int> conflicts;

  /// Either diff ran out of budget (see diff.dart) — regions may be coarse.
  final bool coarse;
}

/// Merge three line lists. Lines compare by exact string equality.
MergeResult mergeThreeWay(
  List<String> base,
  List<String> left,
  List<String> right, {
  int? budget,
}) {
  final ids = <String, int>{};
  List<int> intern(List<String> lines) => [
    for (final l in lines) ids.putIfAbsent(l, () => ids.length),
  ];
  final b = intern(base), l = intern(left), r = intern(right);
  final bl = diffSequences(b, l, budget: budget ?? defaultDiffBudget);
  final br = diffSequences(b, r, budget: budget ?? defaultDiffBudget);
  return mergeHunks(
    base.length,
    left.length,
    right.length,
    bl.hunks,
    br.hunks,
    sameText: (l0, l1, r0, r1) {
      if (l1 - l0 != r1 - r0) return false;
      for (var i = 0; i < l1 - l0; i++) {
        if (l[l0 + i] != r[r0 + i]) return false;
      }
      return true;
    },
    coarse: bl.coarse || br.coarse,
  );
}

/// Build the chunk list from the two hunk lists (base→left, base→right).
/// [sameText] tells whether the left slice and the right slice are equal.
MergeResult mergeHunks(
  int baseLen,
  int leftLen,
  int rightLen,
  List<DiffHunk> leftHunks,
  List<DiffHunk> rightHunks, {
  required bool Function(int l0, int l1, int r0, int r1) sameText,
  bool coarse = false,
}) {
  // (side, hunk) sorted by base start; a stable merge of the two lists.
  final all = <(bool, DiffHunk)>[];
  var i = 0, j = 0;
  while (i < leftHunks.length || j < rightHunks.length) {
    if (j >= rightHunks.length ||
        (i < leftHunks.length && leftHunks[i].aStart <= rightHunks[j].aStart)) {
      all.add((true, leftHunks[i++]));
    } else {
      all.add((false, rightHunks[j++]));
    }
  }

  final chunks = <MergeChunk>[];
  final conflicts = <int>[];
  var dl = 0, dr = 0; // left/right offset relative to base so far
  var pos = 0; // base position already emitted
  void emitSame(int upTo) {
    if (upTo > pos) {
      chunks.add(
        MergeChunk(
          MergeKind.same,
          pos,
          upTo,
          pos + dl,
          upTo + dl,
          pos + dr,
          upTo + dr,
        ),
      );
      pos = upTo;
    }
  }

  var k = 0;
  while (k < all.length) {
    // One region: hunks that overlap or touch in base coordinates.
    final start = all[k].$2.aStart;
    var end = all[k].$2.aEnd;
    var hasL = false, hasR = false;
    var regionDl = 0, regionDr = 0;
    while (k < all.length && all[k].$2.aStart <= end) {
      final (isLeft, h) = all[k];
      if (h.aEnd > end) end = h.aEnd;
      final delta = (h.bEnd - h.bStart) - (h.aEnd - h.aStart);
      if (isLeft) {
        hasL = true;
        regionDl += delta;
      } else {
        hasR = true;
        regionDr += delta;
      }
      k++;
    }
    emitSame(start);
    final l0 = start + dl, l1 = end + dl + regionDl;
    final r0 = start + dr, r1 = end + dr + regionDr;
    MergeKind kind;
    if (hasL && hasR) {
      kind = sameText(l0, l1, r0, r1) ? MergeKind.bothSame : MergeKind.conflict;
    } else {
      kind = hasL ? MergeKind.leftOnly : MergeKind.rightOnly;
    }
    if (kind == MergeKind.conflict) conflicts.add(chunks.length);
    chunks.add(MergeChunk(kind, start, end, l0, l1, r0, r1));
    pos = end;
    dl += regionDl;
    dr += regionDr;
  }
  emitSame(baseLen);
  assert(pos + dl == leftLen && pos + dr == rightLen);
  return MergeResult(chunks: chunks, conflicts: conflicts, coarse: coarse);
}

/// Default conflict markers (git style; the labels are file names).
const String mergeMarkerLeft = '<<<<<<< ';
const String mergeMarkerBase = '||||||| ';
const String mergeMarkerSplit = '=======';
const String mergeMarkerRight = '>>>>>>> ';

/// One output line and the chunk it came from (for colouring the result).
class MergeOutLine {
  const MergeOutLine(this.text, this.chunk, {this.marker = false});
  final String text;
  final int chunk;
  final bool marker; // a conflict marker line, not content
}

/// The merged text: every chunk contributes according to its kind, conflicts
/// according to [choices] (indexed like [MergeResult.conflicts]); unresolved
/// ones are written out with markers so nothing is silently lost.
List<MergeOutLine> mergeOutput(
  MergeResult res,
  List<String> base,
  List<String> left,
  List<String> right,
  List<MergeChoice> choices, {
  String leftLabel = 'LEFT',
  String baseLabel = 'BASE',
  String rightLabel = 'RIGHT',
}) {
  final out = <MergeOutLine>[];
  var ci = 0;
  for (var i = 0; i < res.chunks.length; i++) {
    final c = res.chunks[i];
    void add(List<String> src, int s, int e) {
      for (var k = s; k < e; k++) {
        out.add(MergeOutLine(src[k], i));
      }
    }

    switch (c.kind) {
      case MergeKind.same:
        add(base, c.b0, c.b1);
      case MergeKind.leftOnly:
      case MergeKind.bothSame:
        add(left, c.l0, c.l1);
      case MergeKind.rightOnly:
        add(right, c.r0, c.r1);
      case MergeKind.conflict:
        final choice = ci < choices.length
            ? choices[ci]
            : MergeChoice.unresolved;
        ci++;
        switch (choice) {
          case MergeChoice.left:
            add(left, c.l0, c.l1);
          case MergeChoice.right:
            add(right, c.r0, c.r1);
          case MergeChoice.base:
            add(base, c.b0, c.b1);
          case MergeChoice.leftRight:
            add(left, c.l0, c.l1);
            add(right, c.r0, c.r1);
          case MergeChoice.rightLeft:
            add(right, c.r0, c.r1);
            add(left, c.l0, c.l1);
          case MergeChoice.unresolved:
            out.add(
              MergeOutLine('$mergeMarkerLeft$leftLabel', i, marker: true),
            );
            add(left, c.l0, c.l1);
            out.add(
              MergeOutLine('$mergeMarkerBase$baseLabel', i, marker: true),
            );
            add(base, c.b0, c.b1);
            out.add(const MergeOutLine(mergeMarkerSplit, -1, marker: true));
            add(right, c.r0, c.r1);
            out.add(
              MergeOutLine('$mergeMarkerRight$rightLabel', i, marker: true),
            );
        }
    }
  }
  return out;
}

/// One aligned display row of the three-column view: line index on each
/// side (-1 = no line on this row) and the chunk it belongs to.
class MergeRow {
  const MergeRow(this.chunk, this.il, this.ib, this.ir);
  final int chunk;
  final int il, ib, ir;
}

/// Lay the chunks out side by side; returns the rows and the first row of
/// each chunk.
(List<MergeRow>, List<int>) alignMerge(List<MergeChunk> chunks) {
  final rows = <MergeRow>[];
  final starts = <int>[];
  for (var i = 0; i < chunks.length; i++) {
    final c = chunks[i];
    starts.add(rows.length);
    final n = c.rows;
    for (var k = 0; k < n; k++) {
      rows.add(
        MergeRow(
          i,
          k < c.leftLen ? c.l0 + k : -1,
          k < c.baseLen ? c.b0 + k : -1,
          k < c.rightLen ? c.r0 + k : -1,
        ),
      );
    }
  }
  return (rows, starts);
}

/// Everything the merge view needs; plain data (isolate-safe).
class MergeData {
  const MergeData({
    required this.base,
    required this.left,
    required this.right,
    required this.result,
    required this.rows,
    required this.chunkRows,
  });
  final DiffSide base, left, right;
  final MergeResult result;
  final List<MergeRow> rows;
  final List<int> chunkRows;
}

/// Load the three files and merge them (run this in an isolate from the UI).
MergeData computeFileMerge(
  String basePath,
  String leftPath,
  String rightPath, {
  int maxBytes = diffMaxBytes,
}) {
  final base = loadDiffSide(basePath, maxBytes: maxBytes);
  final left = loadDiffSide(leftPath, maxBytes: maxBytes);
  final right = loadDiffSide(rightPath, maxBytes: maxBytes);
  final res = mergeThreeWay(base.lines, left.lines, right.lines);
  final (rows, starts) = alignMerge(res.chunks);
  return MergeData(
    base: base,
    left: left,
    right: right,
    result: res,
    rows: rows,
    chunkRows: starts,
  );
}
