// Text-column cells for the hex view, decoded with the document's codec.
//
// Each visible byte gets one cell. A character is drawn at the cell of its
// FIRST byte (wide CJK glyphs simply spill into the following cell, which is
// left empty); the character's remaining bytes get empty cells; control
// bytes / undecodable bytes get '.' (the classic xxd convention).
//
// Pure Dart (no flutter) — tested from tool/encoding_test.dart.

import 'dart:typed_data';

import 'encoding/codecs.dart';

/// Cell content for bytes [pre, pre+count) of [buf] decoded with [codec]:
/// `cells[i]` is what to draw at the cell of byte `pre + i` — a character,
/// '.' for control/undecodable bytes, or '' for a continuation byte.
///
/// [pre] is prefix context (bytes read before the visible base) so that a
/// character straddling the window top is decoded correctly; its in-window
/// continuation bytes come out as ''.
List<String> hexTextCells(TextCodec codec, Uint8List buf, int pre, int count) {
  final cells = List<String>.filled(count, '');
  final d = codec.decode(buf);
  var cu = 0;
  while (cu < d.text.length) {
    final start = d.byteOffsets[cu];
    // The character's code units all share the same start byte offset.
    var end = cu + 1;
    while (end < d.text.length && d.byteOffsets[end] == start) {
      end++;
    }
    final cell = start - pre;
    if (cell >= 0 && cell < count) {
      final cp = d.text.codeUnitAt(cu);
      final printable = cp >= 0x20 &&
          cp != 0x7F &&
          cp != 0xFFFD &&
          cp != 0xFEFF && // BOM: invisible, show as '.'
          !(cp >= 0x80 && cp <= 0xA0);
      cells[cell] = printable ? d.text.substring(cu, end) : '.';
    }
    cu = end;
  }
  return cells;
}
