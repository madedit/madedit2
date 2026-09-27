// Status-bar caret column (pure Dart, no flutter import).
//
// "Character column" in the VS Code / Notepad++ sense: every code point
// counts one (a surrogate pair is one, CJK is one — not its display width),
// a tab advances to the next multiple of tabSize. This is deliberately not
// the wcwidth column used by column mode / tab expansion for drawing.

/// 1-based column of UTF-16 index [charIndex] within [line].
int charColumn(String line, int charIndex, int tabSize) {
  final end = charIndex < 0
      ? 0
      : (charIndex > line.length ? line.length : charIndex);
  final ts = tabSize < 1 ? 1 : tabSize;
  var col = 0;
  var i = 0;
  while (i < end) {
    final u = line.codeUnitAt(i);
    // A high surrogate followed by a low one is a single code point; an
    // index that splits the pair counts as before it.
    final pair = u >= 0xD800 && u < 0xDC00 && i + 1 < line.length;
    if (pair && i + 2 > end) break;
    if (u == 0x09) {
      col += ts - col % ts;
    } else {
      col++;
    }
    i += pair ? 2 : 1;
  }
  return col + 1;
}
