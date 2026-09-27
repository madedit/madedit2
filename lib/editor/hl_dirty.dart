// Dirty-range bookkeeping for incremental whole-file highlighting (pure Dart, headless-tested in
// tool/hl_dirty_test.dart).
//
// Edits reach the highlighter as line replacements. Between two syncs the view accumulates the
// edited region as one byte range in the document's *current* coordinates ([DirtyBytes]); at
// sync time that range becomes a line range, and the line count delta tells which *old* lines it
// replaced ([DirtyLines]). One merged range (not a list) is enough: re-highlighting the untouched
// lines in between is cheap, and rapid edits are almost always adjacent anyway.

/// The byte range touched by the splices since the last drain, in current coordinates.
class DirtyBytes {
  int start = -1; // -1 = nothing pending
  int end = -1;

  bool get isEmpty => start < 0;

  /// Note a splice at [offset]: [delta] > 0 bytes inserted there, < 0 bytes deleted from there.
  /// The pending range is shifted like any other offset-anchored state, then unioned with the
  /// splice's new-coordinate footprint (a point for a deletion).
  void add(int offset, int delta) {
    final ins = delta > 0 ? delta : 0;
    final del = delta < 0 ? -delta : 0;
    if (start < 0) {
      start = offset;
      end = offset + ins;
      return;
    }
    int map(int p) {
      if (p < offset) return p;
      if (p >= offset + del) return p + delta;
      return offset; // inside the deleted range → collapses onto it
    }

    final s = map(start), e = map(end);
    start = s < offset ? s : offset;
    end = e > offset + ins ? e : offset + ins;
  }

  void clear() {
    start = -1;
    end = -1;
  }
}

/// The line range whose highlighting is stale, in current line numbering, together with the
/// line count the highlighter last saw so the old range it must replace can be derived.
class DirtyLines {
  int start = -1; // -1 = clean
  int end = -1; // exclusive
  int localLines = 0; // line count as of the last [add] (current numbering)

  bool get isEmpty => start < 0;

  /// Merge an edit that turned lines `[a, b)` (numbering before it) into `[a, y)`; [lines] is
  /// the document's line count after the edit.
  void add(int a, int y, int lines) {
    final delta = lines - localLines;
    final b = y - delta;
    if (start < 0) {
      start = a;
      end = y;
    } else {
      // Everything at/after max(end, b) shifts by delta; the union covers both ranges.
      start = start < a ? start : a;
      end = (end > b ? end : b) + delta;
    }
    localLines = lines;
  }

  /// The end of the pending range in the numbering the highlighter still has ([syncedLines]
  /// lines): the same range with the accumulated line delta undone.
  int oldEnd(int syncedLines) => end - (localLines - syncedLines);

  void clear() {
    start = -1;
    end = -1;
  }
}

/// Where a line numbered [line] as of a sync (the highlighter's numbering, [syncedLines] lines)
/// lives now, given the pending dirty range [dirty] in current numbering — or -1 when it falls
/// inside the dirty range (it will be re-highlighted anyway).
int mapSyncedLine(int line, DirtyLines dirty, int syncedLines) {
  if (dirty.isEmpty) return line;
  if (line < dirty.start) return line;
  final delta = dirty.localLines - syncedLines;
  final oldEnd = dirty.end - delta;
  if (line >= oldEnd) return line + delta;
  return -1;
}
