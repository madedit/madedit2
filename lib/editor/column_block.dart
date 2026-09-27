// Column (block / rectangular) selection: the math behind the `column` view mode.
//
// A block is two corners, each of which is a **document line** (identified by the byte offset of
// its start — offsets are comparable, so no line index or file-wide index is needed) plus a
// **column** within that line. Every line the block covers contributes the same column range,
// clamped to its own length; that per-line slice is what painting, copy and block editing all use.
//
// The column unit is the character's **display width**: 1 for normal characters, 2 for East-Asian
// wide/fullwidth ones (and emoji) — the same convention terminals and MadEdit use. In a monospace
// font that makes the block's edges line up vertically even over mixed Chinese/Japanese and ASCII
// text, which counting runes would not.
//
// A column can therefore land *inside* a wide character. Selection edges then grow outwards so a
// wide character is always either fully in or fully out (see [charIndexForColumn]'s `roundUp`).
//
// One known simplification: a line shorter than the block's left edge contributes nothing — the
// block never pads a short line with spaces (MadEdit does; here inserting clamps to the line end).
//
// Pure Dart (no Flutter, no IO), so it is headless-testable — see tool/column_block_test.dart.

import 'dart:convert';
import 'dart:typed_data';

/// A rectangular selection: the anchor corner (where the block started) and the caret corner
/// (where it currently ends). Either corner may be the top/left one.
class ColumnBlock {
  const ColumnBlock({
    required this.anchorLine,
    required this.anchorCol,
    required this.caretLine,
    required this.caretCol,
  });

  /// A zero-size block at one corner — the starting point before the caret moves.
  const ColumnBlock.at(int line, int col)
    : anchorLine = line,
      anchorCol = col,
      caretLine = line,
      caretCol = col;

  /// Document byte offset of the anchor line's start.
  final int anchorLine;

  /// Column (rune index) of the anchor corner within its line.
  final int anchorCol;

  /// Document byte offset of the caret line's start.
  final int caretLine;

  /// Column (rune index) of the caret corner within its line.
  final int caretCol;

  int get topLine => anchorLine < caretLine ? anchorLine : caretLine;
  int get bottomLine => anchorLine > caretLine ? anchorLine : caretLine;
  int get leftCol => anchorCol < caretCol ? anchorCol : caretCol;
  int get rightCol => anchorCol > caretCol ? anchorCol : caretCol;

  /// Whether the block covers more than one line.
  bool get multiLine => topLine != bottomLine;

  /// Whether the block has horizontal extent (a zero-width block is still useful: typing inserts
  /// the same text into every line it spans).
  bool get hasWidth => leftCol != rightCol;

  /// Nothing selected at all (one point).
  bool get isEmpty => !multiLine && !hasWidth;

  /// The same block with the caret corner moved.
  ColumnBlock withCaret(int line, int col) => ColumnBlock(
    anchorLine: anchorLine,
    anchorCol: anchorCol,
    caretLine: line,
    caretCol: col,
  );

  /// Whether the line starting at [lineStart] is one of the block's rows.
  bool coversLine(int lineStart) =>
      lineStart >= topLine && lineStart <= bottomLine;

  @override
  bool operator ==(Object other) =>
      other is ColumnBlock &&
      other.anchorLine == anchorLine &&
      other.anchorCol == anchorCol &&
      other.caretLine == caretLine &&
      other.caretCol == caretCol;

  @override
  int get hashCode => Object.hash(anchorLine, anchorCol, caretLine, caretCol);

  @override
  String toString() =>
      'ColumnBlock($anchorLine:$anchorCol → $caretLine:$caretCol)';
}

/// The part of one line that a block covers, in both UTF-16 (painting) and byte (editing)
/// coordinates, all relative to the line's start.
class ColumnSlice {
  const ColumnSlice(this.startChar, this.endChar, this.startByte, this.endByte);

  /// UTF-16 indices into the line's text — what `Paragraph.getBoxesForRange` wants.
  final int startChar, endChar;

  /// Byte offsets within the line — what `Document.insert`/`delete` want.
  final int startByte, endByte;

  bool get isEmpty => endByte <= startByte;

  @override
  String toString() => '$startChar-$endChar/$startByte-$endByte';
}

/// Display width of [rune] in columns: 2 for East-Asian wide/fullwidth characters and emoji,
/// 1 for everything else.
///
/// This is the usual `wcwidth` table (Unicode East Asian Width = W or F) trimmed to the ranges that
/// matter here; anything not listed is narrow. Combining marks are **not** treated as zero-width —
/// the editor counts them as their own column everywhere else too.
int runeWidth(int rune) {
  if (rune < 0x1100) return 1;
  if (rune <= 0x115F) return 2; // Hangul Jamo (initial consonants)
  if (rune >= 0x2E80 && rune <= 0x303E) return 2; // CJK radicals … symbols
  if (rune >= 0x3041 && rune <= 0x33FF) return 2; // kana, Bopomofo, enclosed CJK
  if (rune >= 0x3400 && rune <= 0x4DBF) return 2; // CJK ext A
  if (rune >= 0x4E00 && rune <= 0x9FFF) return 2; // CJK unified ideographs
  if (rune >= 0xA000 && rune <= 0xA4CF) return 2; // Yi
  if (rune >= 0xA960 && rune <= 0xA97F) return 2; // Hangul Jamo ext A
  if (rune >= 0xAC00 && rune <= 0xD7A3) return 2; // Hangul syllables
  if (rune >= 0xF900 && rune <= 0xFAFF) return 2; // CJK compatibility ideographs
  if (rune >= 0xFE10 && rune <= 0xFE19) return 2; // vertical forms
  if (rune >= 0xFE30 && rune <= 0xFE6F) return 2; // CJK compatibility forms
  if (rune >= 0xFF00 && rune <= 0xFF60) return 2; // fullwidth forms
  if (rune >= 0xFFE0 && rune <= 0xFFE6) return 2; // fullwidth signs
  if (rune >= 0x1F300 && rune <= 0x1FAFF) return 2; // emoji
  if (rune >= 0x20000 && rune <= 0x3FFFD) return 2; // CJK ext B and beyond
  return 1;
}

// The character starting at UTF-16 index [i]: its code point and how many code units it takes
// (2 for a surrogate pair).
(int, int) _charAt(String line, int i) {
  final u = line.codeUnitAt(i);
  if (u >= 0xD800 && u < 0xDC00 && i + 1 < line.length) {
    final lo = line.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo < 0xE000) {
      return (0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00), 2);
    }
  }
  return (u, 1);
}

/// UTF-16 index at display column [col] in [line]; clamped to the line's end.
///
/// When [col] lands **inside** a wide character, [roundUp] decides which way to snap: false gives
/// the index before it (the character starts after the edge), true the index after it. Selections
/// use false on the left edge and true on the right, so a wide character is never cut in half.
///
/// A tab advances to the next multiple of [tabSize] (1 = a tab is one
/// column) and counts as a wide character for the snapping rule, so a
/// boundary inside a tab's span takes or leaves the whole tab.
int charIndexForColumn(
  String line,
  int col, {
  bool roundUp = false,
  int tabSize = 1,
}) {
  if (col <= 0) return 0;
  var w = 0, i = 0;
  while (i < line.length) {
    if (w >= col) return i;
    final (rune, n) = _charAt(line, i);
    final cw = _cellWidth(rune, w, tabSize);
    if (w + cw > col) return roundUp ? i + n : i; // falls inside a wide character
    w += cw;
    i += n;
  }
  return line.length;
}

/// Display column of the UTF-16 index [charIndex] in [line].
int columnForCharIndex(String line, int charIndex, {int tabSize = 1}) {
  var w = 0, i = 0;
  while (i < line.length && i < charIndex) {
    final (rune, n) = _charAt(line, i);
    w += _cellWidth(rune, w, tabSize);
    i += n;
  }
  return w;
}

/// How many columns [line] takes up.
int columnCount(String line, {int tabSize = 1}) =>
    columnForCharIndex(line, line.length, tabSize: tabSize);

// Columns [rune] occupies when it starts at column [at]: a tab runs to the
// next tab stop, everything else is its wcwidth.
int _cellWidth(int rune, int at, int tabSize) {
  if (rune != 0x09) return runeWidth(rune);
  final ts = tabSize < 1 ? 1 : tabSize;
  return ts - at % ts;
}

/// Byte offset of column [col] within [line] (clamped to the line's end).
/// [byteLen] measures a string's encoded byte length (defaults to UTF-8);
/// pass the document codec's measure for other encodings.
int byteOffsetOfColumn(
  String line,
  int col, {
  bool roundUp = false,
  int Function(String)? byteLen,
  int tabSize = 1,
}) {
  final ci = charIndexForColumn(line, col, roundUp: roundUp, tabSize: tabSize);
  final f = byteLen ?? _utf8Len;
  return ci <= 0 ? 0 : f(line.substring(0, ci));
}

int _utf8Len(String s) => utf8.encode(s).length;

/// What [block] covers of the line that starts at [lineStart] and holds [lineText] (without its
/// newline), or null when that line is outside the block.
///
/// A line shorter than the block's left edge yields an **empty** slice sitting at the line's end,
/// so callers can tell "outside the block" (null) from "inside but nothing to take" (empty).
/// [map] is the line's byte<->code-unit map from the document's codec
/// (`DocWindow.maps` style: one entry per code unit + trailing byte length);
/// when given, the slice's byte offsets are exact for any encoding —
/// otherwise UTF-8 re-encoding is assumed.
ColumnSlice? sliceLine(
  ColumnBlock block,
  int lineStart,
  String lineText, {
  Uint32List? map,
  int tabSize = 1,
}) {
  if (!block.coversLine(lineStart)) return null;
  // Left edge snaps left, right edge snaps right → a wide character cut by
  // the boundary is taken whole (never half a glyph). Exception: a zero-width
  // block is just a per-line insertion point — it must not swallow the wide
  // character it happens to land inside.
  final sc = charIndexForColumn(lineText, block.leftCol, tabSize: tabSize);
  final ec = block.hasWidth
      ? charIndexForColumn(
          lineText,
          block.rightCol,
          roundUp: true,
          tabSize: tabSize,
        )
      : sc;
  final int sb, eb;
  if (map != null) {
    sb = map[sc];
    eb = ec <= sc ? sb : map[ec];
  } else {
    sb = sc <= 0 ? 0 : utf8.encode(lineText.substring(0, sc)).length;
    eb = ec <= sc ? sb : sb + utf8.encode(lineText.substring(sc, ec)).length;
  }
  return ColumnSlice(sc, ec, sb, eb);
}

/// The text a block copies out of [lines]: one entry per covered line, each the line's slice.
///
/// [lineStarts] are the lines' document byte offsets, parallel to [lines].
List<String> blockSliceTexts(
  ColumnBlock block,
  List<String> lines,
  List<int> lineStarts, {
  int tabSize = 1,
}) {
  final out = <String>[];
  for (var i = 0; i < lines.length && i < lineStarts.length; i++) {
    final s = sliceLine(block, lineStarts[i], lines[i], tabSize: tabSize);
    if (s == null) continue;
    out.add(s.isEmpty ? '' : lines[i].substring(s.startChar, s.endChar));
  }
  return out;
}

/// One line's edit when a block operation is applied: replace `[start, end)` (document byte
/// offsets) with [text].
class BlockEdit {
  const BlockEdit(this.lineStart, this.start, this.end, this.text,
      {this.textBytes});

  /// Document byte offset of the line this edit belongs to (before the edit).
  final int lineStart;

  final int start, end;
  final String text;

  /// Encoded byte length of [text] under the document's codec (null = UTF-8).
  final int? textBytes;

  bool get isNoop => end <= start && text.isEmpty;

  /// How many bytes the document grows (or shrinks) by.
  int get delta => (textBytes ?? utf8.encode(text).length) - (end - start);

  @override
  String toString() => 'BlockEdit($start-$end,"$text")';
}

/// Where the line that used to start at [lineStart] starts **after** [edits] were applied.
///
/// Only the lines above it move it: each edit changes the document length from its own position
/// onwards, so the shift is the sum of the deltas of the edits above.
int shiftedLineStart(List<BlockEdit> edits, int lineStart) {
  var shift = 0;
  for (final e in edits) {
    if (e.lineStart < lineStart) shift += e.delta;
  }
  return lineStart + shift;
}

/// Turn a block operation into per-line edits, **ordered bottom-up** (descending offset).
///
/// Bottom-up matters: each edit's offsets are computed against the unmodified document, so the
/// later (lower-offset) edits must not have been shifted by the earlier ones. The caller applies
/// them in this order and groups the reverse commands into a single undo step.
///
/// [insert] is the text to put at the block's left edge on every covered line ('' = pure delete).
/// When the block has no width and [insert] is empty the result is empty (nothing to do).
///
/// [maps] (parallel to [lines]) are the lines' byte<->code-unit maps and
/// [insertBytes] the encoded byte length of [insert] under the document's
/// codec; both default to UTF-8 assumptions when omitted.
List<BlockEdit> blockEdits(
  ColumnBlock block,
  List<String> lines,
  List<int> lineStarts, {
  String insert = '',
  List<Uint32List>? maps,
  int? insertBytes,
  List<String>? insertPerLine, // column editor: a different text per line
  List<int>? insertBytesPerLine,
  int tabSize = 1,
}) {
  final out = <BlockEdit>[];
  for (var i = 0; i < lines.length && i < lineStarts.length; i++) {
    final map = maps != null && i < maps.length ? maps[i] : null;
    final s = sliceLine(
      block,
      lineStarts[i],
      lines[i],
      map: map,
      tabSize: tabSize,
    );
    if (s == null) continue;
    final base = lineStarts[i];
    final text = insertPerLine != null && i < insertPerLine.length
        ? insertPerLine[i]
        : insert;
    final bytes = insertBytesPerLine != null && i < insertBytesPerLine.length
        ? insertBytesPerLine[i]
        : insertBytes;
    final e = BlockEdit(base, base + s.startByte, base + s.endByte, text,
        textBytes: bytes);
    if (!e.isNoop) out.add(e);
  }
  return out.reversed.toList();
}
