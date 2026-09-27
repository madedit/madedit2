// File comparison core (View → Compare Files…): line diff of two files.
//
// Pure Dart, no flutter imports (headless-testable: tool/diff_test.dart).
// The widget runs [computeFileDiff] in an isolate; everything it returns is
// plain lists so it crosses the isolate boundary.
//
// Algorithm: Myers' O(ND) difference with the linear-space (middle snake)
// refinement, on interned line ids. A work budget bounds the worst case
// (two large, unrelated files): once it is spent, the remaining regions are
// reported as one coarse "replace" block instead of a fine-grained diff.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'encoding/codecs.dart';
import 'encoding/detector.dart';

/// `[aStart, aEnd)` of the left sequence is replaced by `[bStart, bEnd)` of
/// the right one (either side may be empty: pure delete / insert).
class DiffHunk {
  const DiffHunk(this.aStart, this.aEnd, this.bStart, this.bEnd);
  final int aStart, aEnd, bStart, bEnd;

  bool get isDelete => bStart == bEnd;
  bool get isInsert => aStart == aEnd;

  @override
  String toString() => 'a[$aStart,$aEnd) → b[$bStart,$bEnd)';
}

/// Default work budget for [diffSequences] (inner-loop steps).
const int defaultDiffBudget = 200000000;

/// Diff two sequences of ids; hunks come back in order. When the budget
/// runs out mid-way the unresolved region becomes one replace hunk and
/// [DiffOutcome.coarse] is set.
DiffOutcome diffSequences(
  List<int> a,
  List<int> b, {
  int budget = defaultDiffBudget,
}) {
  final m = _Myers(a, b, budget);
  m.run(0, a.length, 0, b.length);
  return DiffOutcome(m.hunks, coarse: m.exhausted);
}

class DiffOutcome {
  const DiffOutcome(this.hunks, {this.coarse = false});
  final List<DiffHunk> hunks;
  final bool coarse;
}

class _Myers {
  _Myers(this.a, this.b, this.budget);
  final List<int> a, b;
  int budget;
  bool exhausted = false;
  final hunks = <DiffHunk>[];
  late Int32List _vf, _vb;

  void run(int a0, int a1, int b0, int b1) {
    // Reverse diagonals sit around delta = n - m, so the index range is
    // wider than the forward [-d, d]; 2(n+m) each side covers both.
    final span = (a1 - a0) + (b1 - b0);
    _vf = Int32List(4 * span + 8);
    _vb = Int32List(4 * span + 8);
    _rec(a0, a1, b0, b1);
  }

  // Adjacent hunks (a zero-length middle snake splits a region into a pure
  // insert next to a pure delete) merge into one replace block.
  void _emit(int a0, int a1, int b0, int b1) {
    if (a0 == a1 && b0 == b1) return;
    if (hunks.isNotEmpty) {
      final last = hunks.last;
      if (last.aEnd == a0 && last.bEnd == b0) {
        hunks[hunks.length - 1] = DiffHunk(last.aStart, a1, last.bStart, b1);
        return;
      }
    }
    hunks.add(DiffHunk(a0, a1, b0, b1));
  }

  void _rec(int a0, int a1, int b0, int b1) {
    // Shared prefix / suffix first: cheap, and keeps the snake search small.
    while (a0 < a1 && b0 < b1 && a[a0] == b[b0]) {
      a0++;
      b0++;
    }
    while (a0 < a1 && b0 < b1 && a[a1 - 1] == b[b1 - 1]) {
      a1--;
      b1--;
    }
    if (a0 == a1 || b0 == b1) {
      _emit(a0, a1, b0, b1);
      return;
    }
    if (exhausted) {
      _emit(a0, a1, b0, b1);
      return;
    }
    final s = _middleSnake(a0, a1, b0, b1);
    if (s == null) {
      exhausted = true;
      _emit(a0, a1, b0, b1);
      return;
    }
    final (x, y, u, v) = s;
    _rec(a0, a0 + x, b0, b0 + y);
    _rec(a0 + u, a1, b0 + v, b1);
  }

  // Middle snake of the region (Myers §4b). Coordinates are relative to
  // (a0, b0). Returns (x, y, u, v): the snake runs from (x,y) to (u,v).
  (int, int, int, int)? _middleSnake(int a0, int a1, int b0, int b1) {
    final n = a1 - a0, m = b1 - b0;
    final delta = n - m;
    final odd = delta.isOdd;
    final off = 2 * (n + m) + 3; // index offset so negative diagonals fit
    final vf = _vf, vb = _vb;
    vf[off + 1] = 0;
    // Reverse diagonals are indexed by the absolute k = x - y too, so the
    // reverse start (n, m) sits on diagonal delta; its d=0 step reads k-1.
    vb[off + delta - 1] = n;
    final dmax = (n + m + 1) ~/ 2 + 1;
    for (var d = 0; d <= dmax; d++) {
      // ── forward ──
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && vf[off + k - 1] < vf[off + k + 1])) {
          x = vf[off + k + 1];
        } else {
          x = vf[off + k - 1] + 1;
        }
        var y = x - k;
        final sx = x, sy = y;
        while (x < n && y < m && a[a0 + x] == b[b0 + y]) {
          x++;
          y++;
        }
        if (budget-- <= 0) return null;
        vf[off + k] = x;
        if (odd && k - delta >= -(d - 1) && k - delta <= d - 1) {
          if (vb[off + k] <= x) return (sx, sy, x, y);
        }
      }
      // ── reverse ──
      for (var k = -d; k <= d; k += 2) {
        final kk = k + delta; // absolute diagonal
        int x;
        if (k == d || (k != -d && vb[off + kk - 1] < vb[off + kk + 1])) {
          x = vb[off + kk - 1];
        } else {
          x = vb[off + kk + 1] - 1;
        }
        var y = x - kk;
        final sx = x, sy = y;
        while (x > 0 && y > 0 && a[a0 + x - 1] == b[b0 + y - 1]) {
          x--;
          y--;
        }
        if (budget-- <= 0) return null;
        vb[off + kk] = x;
        if (!odd && kk >= -d && kk <= d) {
          if (x <= vf[off + kk]) return (x, y, sx, sy);
        }
      }
    }
    return null; // unreachable in theory; treat as budget exhaustion
  }
}

/// One aligned display row of a side-by-side view.
class DiffRow {
  const DiffRow(this.kind, this.ia, this.ib);

  /// 0 equal, 1 deleted (left only), 2 added (right only), 3 changed pair.
  final int kind;

  /// Line index on each side, -1 when that side has no line on this row.
  final int ia, ib;

  static const equal = 0, del = 1, add = 2, change = 3;
}

/// Turn hunks into aligned rows: equal stretches pair up, a replace hunk
/// pairs its first min(n, m) lines as "changed" and lists the rest as pure
/// deletions / additions. Returns the rows and the row index where each
/// hunk starts (for next/previous navigation).
(List<DiffRow>, List<int>) alignRows(int aLen, int bLen, List<DiffHunk> hunks) {
  final rows = <DiffRow>[];
  final starts = <int>[];
  var ia = 0, ib = 0;
  for (final h in hunks) {
    while (ia < h.aStart) {
      rows.add(DiffRow(DiffRow.equal, ia++, ib++));
    }
    starts.add(rows.length);
    final n = h.aEnd - h.aStart, m = h.bEnd - h.bStart;
    final paired = n < m ? n : m;
    for (var i = 0; i < paired; i++) {
      rows.add(DiffRow(DiffRow.change, ia++, ib++));
    }
    while (ia < h.aEnd) {
      rows.add(DiffRow(DiffRow.del, ia++, -1));
    }
    while (ib < h.bEnd) {
      rows.add(DiffRow(DiffRow.add, -1, ib++));
    }
  }
  while (ia < aLen && ib < bLen) {
    rows.add(DiffRow(DiffRow.equal, ia++, ib++));
  }
  return (rows, starts);
}

/// The changed span of each string in a "changed" pair: everything past the
/// common prefix and before the common suffix. `(aStart, aEnd, bStart, bEnd)`.
(int, int, int, int) changedSpan(String a, String b) {
  var p = 0;
  final pmax = a.length < b.length ? a.length : b.length;
  while (p < pmax && a.codeUnitAt(p) == b.codeUnitAt(p)) {
    p++;
  }
  var sa = a.length, sb = b.length;
  while (sa > p && sb > p && a.codeUnitAt(sa - 1) == b.codeUnitAt(sb - 1)) {
    sa--;
    sb--;
  }
  // Do not split a surrogate pair.
  if (p > 0 && p < a.length && (a.codeUnitAt(p) & 0xFC00) == 0xDC00) p--;
  return (p, sa, p, sb);
}

/// One side of a comparison, decoded and split into lines.
class DiffSide {
  const DiffSide({
    required this.path,
    required this.lines,
    required this.codecName,
    required this.bytes,
    this.crlf = false,
  });
  final String path;
  final List<String> lines;
  final String codecName;
  final int bytes;

  /// The file uses CRLF line endings (first newline decides).
  final bool crlf;
}

/// Files bigger than this are refused (whole content lives in memory).
const int diffMaxBytes = 64 << 20;

/// Read a file, guess its encoding from the head sample, decode and split
/// into lines (CRLF / LF; a trailing newline does not add an empty line).
DiffSide loadDiffSide(String path, {int maxBytes = diffMaxBytes}) {
  final f = File(path);
  final len = f.lengthSync();
  if (len > maxBytes) throw DiffTooLarge(path, len);
  final bytes = f.readAsBytesSync();
  final sample = Uint8List.sublistView(
    bytes,
    0,
    bytes.length < 65536 ? bytes.length : 65536,
  );
  final guess = detectEncoding(sample);
  final codec = textCodecByName(guess.codecName);
  String text;
  if (codec == null || codec.name.toLowerCase() == 'utf-8') {
    // The common case decodes without the byte map (half the memory).
    final body = guess.bomLength > 0
        ? Uint8List.sublistView(bytes, guess.bomLength)
        : bytes;
    text = utf8.decode(body, allowMalformed: true);
  } else {
    text = codec.decode(bytes).text;
    if (guess.bomLength > 0 &&
        text.isNotEmpty &&
        text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
  }
  return DiffSide(
    path: path,
    lines: splitLines(text),
    codecName: codec?.name ?? guess.codecName,
    crlf: _firstNewlineIsCrlf(text),
    bytes: len,
  );
}

bool _firstNewlineIsCrlf(String text) {
  final i = text.indexOf('\n');
  return i > 0 && text.codeUnitAt(i - 1) == 0x0D;
}

/// Split on `\n`, dropping a `\r` before it; a final newline ends the last
/// line rather than starting an empty one.
List<String> splitLines(String text) {
  if (text.isEmpty) return const [];
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      var end = i;
      if (end > start && text.codeUnitAt(end - 1) == 0x0D) end--;
      out.add(text.substring(start, end));
      start = i + 1;
    }
  }
  if (start < text.length) out.add(text.substring(start));
  return out;
}

class DiffTooLarge implements Exception {
  const DiffTooLarge(this.path, this.bytes);
  final String path;
  final int bytes;
  @override
  String toString() => 'file too large to compare: $path ($bytes bytes)';
}

/// Everything the side-by-side view needs; plain data (isolate-safe).
class DiffResult {
  const DiffResult({
    required this.left,
    required this.right,
    required this.rows,
    required this.hunkRows,
    required this.deleted,
    required this.added,
    required this.changed,
    required this.coarse,
  });
  final DiffSide left, right;
  final List<DiffRow> rows;
  final List<int> hunkRows; // first row of each difference block
  final int deleted, added, changed; // line counts by row kind
  final bool coarse;

  bool get identical => hunkRows.isEmpty;
}

/// Compare two sequences of lines (already loaded).
DiffResult diffSides(DiffSide left, DiffSide right, {int? budget}) {
  // Intern lines so the diff compares ints.
  final ids = <String, int>{};
  List<int> intern(List<String> lines) => [
    for (final l in lines) ids.putIfAbsent(l, () => ids.length),
  ];
  final a = intern(left.lines), b = intern(right.lines);
  final out = diffSequences(a, b, budget: budget ?? defaultDiffBudget);
  final (rows, starts) = alignRows(a.length, b.length, out.hunks);
  var del = 0, add = 0, chg = 0;
  for (final r in rows) {
    switch (r.kind) {
      case DiffRow.del:
        del++;
      case DiffRow.add:
        add++;
      case DiffRow.change:
        chg++;
    }
  }
  return DiffResult(
    left: left,
    right: right,
    rows: rows,
    hunkRows: starts,
    deleted: del,
    added: add,
    changed: chg,
    coarse: out.coarse,
  );
}

/// Load both files and diff them (run this in an isolate from the UI).
DiffResult computeFileDiff(
  String leftPath,
  String rightPath, {
  int maxBytes = diffMaxBytes,
}) => diffSides(
  loadDiffSide(leftPath, maxBytes: maxBytes),
  loadDiffSide(rightPath, maxBytes: maxBytes),
);
