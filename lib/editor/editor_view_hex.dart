part of 'editor_view.dart';

mixin _EditorViewHexMode {
  Document? get _doc;
  int get _anchorOffset;
  set _anchorOffset(int value);
  int get _caretOffset;
  set _caretOffset(int value);
  int? get _selAnchor;
  set _selAnchor(int? value);
  Uint8List get _hexBytes;
  set _hexBytes(Uint8List value);
  set _hexCells(List<String> value);
  int get _hexNibble;
  set _hexNibble(int value);
  bool get _hexInsertMode;
  HexArea get _hexArea;
  List<(int, int)> get _windowSplices;
  UndoStack get _undo;
  int get _visibleCount;
  int get _fullRowCount;
  double get editorCharWidth;
  AppLocalizations get _l10n;

  bool get mounted;
  void setState(VoidCallback fn);

  Future<void> _afterEdit();
  void _setModified(bool v);
  void _toast(String msg);
  void _restartBlink();
  bool _blockedReadOnly();

  // Read the hex view's visible bytes (simpler than text mode: a row is a
  // fixed 16 bytes, no line scanning). Also decodes the text column with the
  // document's codec; a few prefix bytes give context so a multi-byte
  // character straddling the window top still decodes (unit codecs are
  // already aligned — the base is a multiple of 16).
  Future<void> _reloadHex() async {
    final doc = _doc;
    if (doc == null) return;
    final rows = _visibleCount + 1;
    final pre = doc.codec.unitSize == 1
        ? (_anchorOffset < 4 ? _anchorOffset : 4)
        : 0;
    final buf = await doc.readRangeBytes(
      _anchorOffset - pre,
      rows * hexBytesPerRow + pre,
    );
    final skip = pre > buf.length ? buf.length : pre;
    final bytes = Uint8List.sublistView(buf, skip);
    final cells = hexTextCells(doc.codec, buf, skip, bytes.length);
    if (mounted) {
      setState(() {
        _hexBytes = bytes;
        _hexCells = cells;
        _windowSplices.clear(); // the hex window reflects every splice now
      });
    }
  }

  // Content width in hex mode (fixed row width, derived directly from the character count).
  double get _hexContentW {
    final doc = _doc;
    final digits = hexOffsetDigits(doc?.length ?? 0);
    return hexRowChars(digits) * editorCharWidth + 20;
  }

  // Hex-mode scrolling: the anchor moves in 16-byte steps (no line scanning needed).
  Future<void> _hexScrollRows(int rows) async {
    final doc = _doc;
    if (doc == null || rows == 0) return;
    final maxBase = _hexMaxBase(doc.length);
    var next = _anchorOffset + rows * hexBytesPerRow;
    if (next < 0) next = 0;
    if (next > maxBase) next = maxBase;
    if (next == _anchorOffset) return;
    _anchorOffset = next;
    await _reloadHex();
  }

  // Bottom scroll limit (wheel / scrollbar): the top row that puts the last
  // row on the LAST COMPLETE screen row — floor, not ceil, or the wheel
  // stopped with the last row half cut off at the viewport edge.
  int _hexMaxBase(int length) {
    if (length <= 0) return 0;
    final lastRow = (length - 1) ~/ hexBytesPerRow;
    final rowsOnScreen = _fullRowCount;
    final maxRow = lastRow - rowsOnScreen + 1;
    return maxRow <= 0 ? 0 : maxRow * hexBytesPerRow;
  }

  // Hex mode: scroll the caret's row into view.
  Future<void> _ensureCaretVisibleHex() async {
    final doc = _doc;
    if (doc == null) return;
    // COMPLETE rows only (floor), like the text view: _visibleCount rounds
    // the viewport height UP, so with a partial last row the caret parked
    // there counted as visible while its row was cut off at the viewport's
    // bottom edge — right above the status bar, which looked like the bar
    // covering the last line (ctrl+End on a large file).
    final rows = _fullRowCount;
    final caretRow = _caretOffset ~/ hexBytesPerRow;
    final topRow = _anchorOffset ~/ hexBytesPerRow;
    if (caretRow < topRow) {
      _anchorOffset = caretRow * hexBytesPerRow;
      await _reloadHex();
    } else if (caretRow >= topRow + rows) {
      final newTop = caretRow - rows + 1;
      _anchorOffset = newTop * hexBytesPerRow;
      await _reloadHex();
    }
  }

  // Hex-mode caret movement (in bytes; hex has no notion of "line", so it bypasses the
  // keybinding caret.* commands). [keepNibble]: up/down/page moves keep the current high/low
  // nibble (as HxD and other hex editors do); jumps like row start/end return to the high one.
  Future<void> _hexMoveCaret(
    int deltaBytes, {
    required bool select,
    bool keepNibble = false,
  }) async {
    final doc = _doc;
    if (doc == null) return;
    // The caret may sit AFTER the last byte in every mode, like a text
    // editor's: the selection is [anchor, caret), so pinning the caret to the
    // last byte in overwrite mode made that byte unselectable from either
    // side. Typing there appends (see _hexTypeDigit / _hexTypeAscii).
    final maxOff = doc.length;
    var next = _caretOffset + deltaBytes;
    if (next < 0) next = 0;
    if (next > maxOff) next = maxOff;
    setState(() {
      if (select) {
        _selAnchor ??= _caretOffset;
      } else {
        _selAnchor = null;
      }
      _caretOffset = next;
      if (!keepNibble) _hexNibble = 0;
    });
    _restartBlink();
    await _ensureCaretVisibleHex();
  }

  // Left/right in the hex column: the unit is a **nibble** (half a byte).
  // Right: high → low → next byte's high; left is the reverse. The ascii column has no
  // nibbles and goes through _hexMoveCaret.
  Future<void> _hexMoveNibble(int deltaNibbles, {required bool select}) async {
    final doc = _doc;
    if (doc == null || doc.length == 0) return;
    final pos = hexClampNibblePos(
      _caretOffset * 2 + _hexNibble + deltaNibbles,
      doc.length,
      allowEnd: true, // the caret may sit after the last byte (see _hexMoveCaret)
    );
    setState(() {
      if (select) {
        _selAnchor ??= _caretOffset;
      } else {
        _selAnchor = null;
      }
      _caretOffset = pos >> 1;
      _hexNibble = pos & 1;
    });
    _restartBlink();
    await _ensureCaretVisibleHex();
  }

  // ── Hex editing ────────────────────────────────────────────────
  // Overwrite mode: typing rewrites the byte at the caret (the file never grows). Only
  // delete/backspace actually remove bytes. Each overwrite = delete(1) + insertBytes(1), both
  // pushed to the UndoStack, so undo/redo is shared with text mode.

  // Unit codecs (UTF-16/32): insert and delete work in WHOLE code units, so
  // the bytes behind the edit never shift out of alignment. A byte codec
  // (unit == 1) keeps the byte-granular behavior.
  static int _hexAlignDown(int off, int unit) =>
      unit > 1 ? off - off % unit : off;
  static int _hexAlignUp(int off, int unit) =>
      unit > 1 ? ((off + unit - 1) ~/ unit) * unit : off;

  /// Overwrite the byte at [offset] with [value] (0–255).
  Future<void> _hexOverwrite(int offset, int value) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || offset < 0 || offset >= doc.length) return;
    final rev = await doc.overwriteBytes(offset, [value]);
    _undo.push(rev); // compound reverse edit → one undo step restores the original byte
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
  }

  /// Type one hex digit in the hex column.
  ///
  /// Overwrite mode: the high/low nibble each replace their half; after the low nibble the
  /// caret moves to the next byte.
  /// Insert mode: **typing the high nibble inserts a new byte** (low nibble 0 for now), the
  /// caret stays on that new byte's low nibble, and typing the low nibble completes it
  /// (same as HxD).
  Future<void> _hexTypeDigit(int digit) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final off = _caretOffset;
    // Insert mode, or the caret parked after the last byte (there is nothing
    // to overwrite there, so overwrite mode appends too).
    if ((_hexInsertMode || off >= doc.length) && _hexNibble == 0) {
      // A unit codec inserts a whole code unit: the typed byte plus zero
      // padding, snapped down to a unit boundary so everything behind the
      // caret keeps its alignment. The padding sits in the display order the
      // hex column shows, so typing continues nibble by nibble as usual.
      final u = doc.codec.unitSize;
      final at = _hexAlignDown(off, u);
      final bytes = u > 1
          ? <int>[digit << 4, ...List<int>.filled(u - 1, 0)]
          : <int>[digit << 4];
      await _hexInsertBytes(at, bytes);
      if (!mounted) return;
      setState(() {
        _caretOffset = at;
        _hexNibble = 1; // stay on the low nibble of the byte just inserted
      });
      return;
    }
    if (doc.length == 0) return;
    final cur = await _hexByteAt(off);
    if (cur == null) return;
    final value = _hexNibble == 0
        ? (digit << 4) | (cur & 0x0F)
        : (cur & 0xF0) | digit;
    await _hexOverwrite(off, value);
    if (!mounted) return;
    // Advance one nibble: after the high nibble stay on the same byte's low nibble; only
    // after the low nibble move to the next byte.
    await _hexMoveNibble(1, select: false);
  }

  /// Type a character in the text column: it is encoded with the document's
  /// codec (so a CJK character in a Big5 file writes its 2 Big5 bytes) and
  /// overwrites (or inserts) that many bytes; the caret moves past them.
  Future<void> _hexTypeAscii(String ch) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final enc = doc.codec.encode(ch);
    if (enc.bytes.isEmpty) return;
    if (enc.fallbackCount > 0) {
      _toast(_l10n.trf('toast_unencodable_one', [doc.codec.name]));
    }
    if (_hexInsertMode || _caretOffset >= doc.length) {
      // Insert mode, or after the last byte: append. The codec's bytes are
      // already a whole number of units; snap the insertion point down to a
      // unit boundary so a unit codec keeps everything aligned.
      final at = _hexAlignDown(_caretOffset, doc.codec.unitSize);
      await _hexInsertBytes(at, enc.bytes);
      if (mounted) {
        await _hexMoveCaret(
          at + enc.bytes.length - _caretOffset,
          select: false,
        );
      }
      return;
    }
    if (_caretOffset + enc.bytes.length > doc.length) {
      _toast(_l10n.tr('toast_hex_ovr_end'));
      return;
    }
    final rev = await doc.overwriteBytes(_caretOffset, enc.bytes);
    _undo.push(rev);
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
    await _hexMoveCaret(enc.bytes.length, select: false);
  }

  /// Insert bytes at [offset] (insert mode). Consecutive inserts coalesce into one undo step.
  Future<void> _hexInsertBytes(int offset, List<int> bytes) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final at = offset.clamp(0, doc.length);
    final rev = await doc.insertBytes(at, bytes);
    _undo.push(rev, coalesce: true);
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
  }

  /// Delete [length] bytes starting at [offset] (the document shrinks).
  Future<void> _hexDelete(int offset, int length) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || length <= 0 || offset < 0 || offset >= doc.length) {
      return;
    }
    var off = offset;
    var len = (offset + length > doc.length) ? doc.length - offset : length;
    // Unit codecs never remove half a code unit: the range expands outward
    // to whole units, so the rest of the file stays aligned. (A truncated
    // last unit at EOF is removed as-is.)
    final u = doc.codec.unitSize;
    if (u > 1) {
      off = _hexAlignDown(offset, u);
      final end = _hexAlignUp(offset + length, u);
      len = (end > doc.length ? doc.length : end) - off;
    }
    final rev = await doc.delete(off, len);
    _undo.push(rev, coalesce: true);
    _setModified(_undo.isDirty);
    setState(() {
      _caretOffset = off;
      _hexNibble = 0;
      _selAnchor = null;
    });
    await _afterEdit();
  }

  /// Byte value at an offset within the current window (read from the file when outside it).
  Future<int?> _hexByteAt(int offset) async {
    final i = offset - _anchorOffset;
    if (i >= 0 && i < _hexBytes.length) return _hexBytes[i];
    final doc = _doc;
    if (doc == null) return null;
    final b = await doc.readRangeBytes(offset, 1);
    return b.isEmpty ? null : b[0];
  }

  // Left segment of the status bar in hex mode: the current row's offset + the value of the
  // byte under the caret.
  String _hexStatusText(Document file) {
    final o = _caretOffset;
    final i = o - _anchorOffset;
    final b = (i >= 0 && i < _hexBytes.length) ? _hexBytes[i] : null;
    final hex = o.toRadixString(16).toUpperCase().padLeft(8, '0');
    final val = b == null
        ? ''
        : _l10n.trf('hex_value_fmt', [
            b.toRadixString(16).toUpperCase().padLeft(2, '0'),
            b.toString().padLeft(3),
          ]);
    final area = _hexArea == HexArea.hex
        ? _l10n.trf('hex_area_fmt', [
            _l10n.tr(_hexNibble == 0 ? 'hex_high' : 'hex_low'),
          ])
        : 'ASCII';
    final mode = _hexInsertMode ? 'INS' : 'OVR';
    return _l10n.trf('hex_status_fmt', [area, mode, hex, val]);
  }
}
