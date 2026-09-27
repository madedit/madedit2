// Multi-cursor bookkeeping (pure Dart, headless-testable:
// tool/multi_cursor_test.dart).
//
// The editor keeps ONE primary caret/anchor and a list of extra cursors.
// A per-cursor command replays the ordinary single-cursor code path once per
// cursor; this file holds the offset arithmetic that makes that safe:
//   * process highest offset first, so a cursor's splices never move a
//     cursor that has not run yet;
//   * cursors already processed (all at higher offsets) shift by every later
//     net byte delta;
//   * afterwards cursors that landed on the same spot merge.

/// One cursor: caret byte offset, optional selection anchor, the goal
/// column kept across vertical moves, and the wrap-row-end affinity.
class Cursor {
  Cursor(this.caret, {this.anchor, this.goal, this.rowEnd = false});

  int caret;
  int? anchor;
  int? goal;
  bool rowEnd;

  int get selStart => anchor == null || anchor! > caret ? caret : anchor!;
  int get selEnd => anchor == null || anchor! < caret ? caret : anchor!;
  bool get hasSelection => anchor != null && anchor != caret;

  void shift(int delta) {
    caret += delta;
    if (anchor != null) anchor = anchor! + delta;
  }

  Cursor copy() => Cursor(caret, anchor: anchor, goal: goal, rowEnd: rowEnd);
}

/// Upper bound on cursors (select-all-occurrences on a common word).
const int maxCursors = 10000;

/// Order for an edit pass: highest caret first (see file comment).
List<Cursor> editOrder(Iterable<Cursor> cursors) =>
    cursors.toList()..sort((a, b) => b.caret.compareTo(a.caret));

/// After processing one cursor whose op changed the document length by
/// [delta], move every cursor processed before it (all higher).
void shiftProcessed(List<Cursor> processed, int delta) {
  if (delta == 0) return;
  for (final c in processed) {
    c.shift(delta);
  }
}

/// Split [all] back into the primary and the sorted extras, dropping extras
/// that collapsed onto another cursor's caret. [primary] must be in [all].
List<Cursor> mergeExtras(Iterable<Cursor> all, Cursor primary) {
  final seen = <int>{primary.caret};
  final rest = <Cursor>[];
  for (final c in all) {
    if (identical(c, primary) || !seen.add(c.caret)) continue;
    rest.add(c);
  }
  rest.sort((a, b) => a.caret.compareTo(b.caret));
  return rest;
}

/// Insert [caret] as a new extra cursor unless it is the primary or already
/// present — in which case the existing one is REMOVED (alt+click toggles).
/// Returns the new sorted extras.
List<Cursor> toggleCursor(List<Cursor> extras, int primaryCaret, int caret) {
  if (caret == primaryCaret) return extras;
  final out = [
    for (final c in extras)
      if (c.caret != caret) c,
  ];
  if (out.length == extras.length) out.add(Cursor(caret));
  out.sort((a, b) => a.caret.compareTo(b.caret));
  return out;
}

/// Paste distribution: when the clipboard has exactly one line per cursor
/// (a trailing newline ignored) each cursor gets its own line, in document
/// order; otherwise null — every cursor pastes the whole text.
List<String>? splitForCursors(String text, int cursorCount) {
  if (cursorCount < 2) return null;
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines.length == cursorCount ? lines : null;
}

/// Flat [start, end, start, end, …] pairs of the extras' selections (only
/// those with a non-empty selection), for the painter.
List<int> selectionPairs(List<Cursor> extras) => [
  for (final c in extras)
    if (c.hasSelection) ...[c.selStart, c.selEnd],
];
