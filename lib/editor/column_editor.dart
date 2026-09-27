// Column editor (Edit → Column Editor…, alt+c): insert the same text, or a
// sequence of numbers, into every line of a rectangular block at its left
// column — the Notepad++ "Column Editor". Pure Dart (headless-testable:
// tool/column_editor_test.dart); the editor applies the texts through the
// column-block machinery (blockEdits with insertPerLine).

import 'column_block.dart' show columnCount;

class ColumnEditorSpec {
  const ColumnEditorSpec.text(this.text)
    : isNumber = false,
      initial = 0,
      step = 1,
      repeat = 1,
      leadingZeros = false,
      radix = 10;

  const ColumnEditorSpec.number({
    this.initial = 1,
    this.step = 1,
    this.repeat = 1,
    this.leadingZeros = false,
    this.radix = 10,
  }) : isNumber = true,
       text = '';

  final bool isNumber;
  final String text;
  final int initial;
  final int step;

  /// How many consecutive lines share one number (1 = every line differs).
  final int repeat;
  final bool leadingZeros;
  final int radix; // 10 / 16 / 8 / 2
}

/// The text for each of [count] lines. Numbers are right-aligned by
/// padding with zeros (leadingZeros) or spaces to the widest one.
List<String> columnTexts(ColumnEditorSpec spec, int count) {
  if (count <= 0) return const [];
  if (!spec.isNumber) return List.filled(count, spec.text);
  final rep = spec.repeat < 1 ? 1 : spec.repeat;
  final values = <int>[
    for (var i = 0; i < count; i++) spec.initial + (i ~/ rep) * spec.step,
  ];
  String raw(int v) {
    final s = v.abs().toRadixString(spec.radix);
    return v < 0 ? '-$s' : (spec.radix == 16 ? s.toUpperCase() : s);
  }

  final strs = [for (final v in values) raw(v)];
  var width = 0;
  for (final s in strs) {
    if (s.length > width) width = s.length;
  }
  return [
    for (final s in strs)
      spec.leadingZeros
          ? (s.startsWith('-')
                ? '-${s.substring(1).padLeft(width - 1, '0')}'
                : s.padLeft(width, '0'))
          : s.padLeft(width),
  ];
}

/// Spaces needed so an insertion at display column [col] lands there even
/// on a line that is shorter (the block's left edge past the line end).
String padForColumn(String lineText, int col, {int tabSize = 1}) {
  final have = columnCount(lineText, tabSize: tabSize);
  return have >= col ? '' : ' ' * (col - have);
}
