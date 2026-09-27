// Tab stops for display (pure Dart, headless-tested in tool/tab_expand_test.dart).
//
// The text engine has no notion of tab stops (a `\t` lays out as one space),
// so a row is shown with each tab replaced by the spaces that reach the next
// stop, and the painter converts between the row's own UTF-16 indices and
// the expanded ("display") indices with the map produced here. Columns are
// terminal cells: wide (CJK) characters count 2, so stops line up in a
// monospace face the way they do in a terminal.

import 'dart:typed_data';

import 'column_block.dart' show runeWidth;

class TabExpansion {
  const TabExpansion(this.display, this.map, this.endColumn);

  /// [text] with every tab replaced by 1..tabSize spaces.
  final String display;

  /// Row char index → display index; `map[text.length]` = display length.
  final Int32List map;

  /// Display column after the last character (the next row's start column
  /// when the row is a soft-wrap slice).
  final int endColumn;
}

/// Expand tabs in [text] whose first character sits at display column
/// [startColumn] (0 for a line start; a soft-wrap slice passes the column
/// its prefix ends at).
TabExpansion expandTabs(String text, int tabSize, {int startColumn = 0}) {
  final size = tabSize < 1 ? 1 : tabSize;
  final map = Int32List(text.length + 1);
  if (!text.contains('\t')) {
    // Identity, except a trailing surrogate maps to its lead's spot (same
    // convention as the tab path, so charForDisplay never lands mid-pair).
    for (var i = 0; i <= text.length; i++) {
      final u = i < text.length ? text.codeUnitAt(i) : 0;
      map[i] = u >= 0xDC00 && u < 0xE000 && i > 0 ? map[i - 1] : i;
    }
    return TabExpansion(
      text,
      map,
      startColumn + _columns(text, 0, text.length),
    );
  }
  final sb = StringBuffer();
  var col = startColumn;
  var i = 0;
  while (i < text.length) {
    final u = text.codeUnitAt(i);
    map[i] = sb.length;
    if (u == 0x09) {
      final n = size - col % size;
      sb.write(' ' * n);
      col += n;
      i++;
      continue;
    }
    if (u >= 0xD800 && u < 0xDC00 && i + 1 < text.length) {
      map[i + 1] = sb.length; // inside a surrogate pair: same spot
      sb.write(text.substring(i, i + 2));
      col += runeWidth(_pairRune(text.codeUnitAt(i), text.codeUnitAt(i + 1)));
      i += 2;
      continue;
    }
    sb.writeCharCode(u);
    col += runeWidth(u);
    i++;
  }
  map[text.length] = sb.length;
  return TabExpansion(sb.toString(), map, col);
}

int _pairRune(int hi, int lo) =>
    0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);

// Cells occupied by text[from, to) (no tabs inside).
int _columns(String text, int from, int to) {
  var col = 0;
  var i = from;
  while (i < to) {
    final u = text.codeUnitAt(i);
    if (u >= 0xD800 && u < 0xDC00 && i + 1 < to) {
      col += runeWidth(_pairRune(text.codeUnitAt(i), text.codeUnitAt(i + 1)));
      i += 2;
    } else {
      col += runeWidth(u);
      i++;
    }
  }
  return col;
}

/// Display column reached after [text] (tabs advance to the next stop),
/// starting from [startColumn].
int displayColumn(String text, int tabSize, {int startColumn = 0}) =>
    expandTabs(text, tabSize, startColumn: startColumn).endColumn;

/// Row char index for display index [disp] (from a hit test on the expanded
/// paragraph): the character whose expansion covers it, rounding to the
/// nearer edge inside a tab's spaces so a click on the right half of a tab
/// lands after it.
int charForDisplay(Int32List map, int disp) {
  final n = map.length - 1; // text length
  if (disp <= 0) return 0;
  if (disp >= map[n]) return n;
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (map[mid] <= disp) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  // lo = last char whose display start <= disp. Both halves of a surrogate
  // pair map to the same spot: step back to the lead, then treat the pair
  // as one character.
  while (lo > 0 && map[lo - 1] == map[lo]) {
    lo--;
  }
  final a = map[lo];
  var next = lo + 1;
  while (next < n && map[next] == a) {
    next++;
  }
  final b = map[next];
  return (disp - a) * 2 >= (b - a) && b > a ? next : lo;
}
