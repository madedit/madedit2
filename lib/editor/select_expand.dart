// Expand / shrink selection (shift+alt+→ / ←) — pure Dart,
// tool/select_expand_test.dart. VS Code grows the selection along the
// syntax tree; without one, the levels here are: word → contents of the
// innermost enclosing bracket pair → the pair including its brackets → the
// next pair out … → the logical line → (the caller adds) the document.
// Bracket matching is character-level per kind, like bracket_match.dart:
// strings and comments are not understood.

import 'word_index.dart' show isWordCodeUnit;

/// The next range strictly containing [s, e) (UTF-16 indices into [text]),
/// or null when nothing inside [text] is larger (the caller may then select
/// the whole document).
(int, int)? expandedRange(String text, int s, int e) {
  bool grows((int, int) r) =>
      r.$1 <= s && r.$2 >= e && r.$2 - r.$1 > e - s;

  final w = wordRangeAt(text, s, e);
  if (w != null && grows(w)) return w;

  var cur = (s, e);
  for (var i = 0; i < 64; i++) {
    final p = enclosingPair(text, cur.$1, cur.$2);
    if (p == null) break;
    final inner = (p.$1 + 1, p.$2);
    if (grows(inner)) return inner;
    final outer = (p.$1, p.$2 + 1);
    if (grows(outer)) return outer;
    cur = outer;
  }

  final ls = s == 0 ? 0 : text.lastIndexOf('\n', s - 1) + 1;
  var le = text.indexOf('\n', e);
  if (le < 0) le = text.length;
  if (le > ls && text.codeUnitAt(le - 1) == 0x0D) le--;
  final line = (ls, le);
  if (grows(line)) return line;
  return null;
}

bool _wordish(int u) =>
    isWordCodeUnit(u) ||
    (u >= 0x3040 && u <= 0x30FF) || // kana
    (u >= 0x3400 && u <= 0x9FFF) || // CJK ideographs
    (u >= 0xAC00 && u <= 0xD7AF); // Hangul

/// The word run around [s, e): both ends must sit on/next to word
/// characters of one run. Null when the range touches no word.
(int, int)? wordRangeAt(String text, int s, int e) {
  if (text.isEmpty) return null;
  var a = s, b = e;
  // Anchor on the character at s (or just before it for a caret at a word's
  // end).
  if (a >= text.length || !_wordish(text.codeUnitAt(a))) {
    if (a > 0 && _wordish(text.codeUnitAt(a - 1))) {
      a--;
    } else {
      return null;
    }
  }
  while (a > 0 && _wordish(text.codeUnitAt(a - 1))) {
    a--;
  }
  if (b < a) b = a;
  while (b < text.length && _wordish(text.codeUnitAt(b))) {
    b++;
  }
  // The original range must lie inside the run (a selection spanning a
  // space is not "a word").
  for (var i = s; i < e; i++) {
    if (!_wordish(text.codeUnitAt(i))) return null;
  }
  return (a, b);
}

const _pairs = {0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D}; // ( [ {

/// Innermost bracket pair enclosing [s, e): (open index, close index), the
/// closer at or after e. Each kind nests independently.
(int, int)? enclosingPair(String text, int s, int e) {
  (int, int)? best;
  for (final entry in _pairs.entries) {
    final open = entry.key, close = entry.value;
    var depth = 0;
    int? p;
    for (var i = s - 1; i >= 0; i--) {
      final c = text.codeUnitAt(i);
      if (c == close) {
        depth++;
      } else if (c == open) {
        if (depth == 0) {
          p = i;
          break;
        }
        depth--;
      }
    }
    if (p == null) continue;
    depth = 0;
    int? q;
    for (var j = e; j < text.length; j++) {
      final c = text.codeUnitAt(j);
      if (c == open) {
        depth++;
      } else if (c == close) {
        if (depth == 0) {
          q = j;
          break;
        }
        depth--;
      }
    }
    if (q == null) continue;
    if (best == null || p > best.$1) best = (p, q);
  }
  return best;
}
