part of 'editor_view.dart';

mixin _EditorViewBookmarks on State<EditorView> {
  Document? get _doc;
  int get _caretOffset;
  bool get _hexMode;
  set _colBlock(ColumnBlock? value);
  set _selAnchor(int? value);
  UndoStack get _undo;
  void _enqueueCaret(Future<void> Function() op);
  Future<void> _moveCaretTo(int offset, bool select);

  final Set<int> _bookmarks = {};
  Set<int> _bookmarksView = const {}; // immutable snapshot for the painter
  String? _bookmarksPath; // which file the set belongs to
  bool _initialBookmarksUsed = false; // widget.initialBookmarks consumed once

  void _bookmarksChanged() {
    _bookmarksView = Set.unmodifiable(_bookmarks);
    if (mounted) setState(() {});
    widget.controller.bookmarksEpoch.value++; // bookmark panel refresh
  }

  void _removeBookmark(int offset) {
    if (_bookmarks.remove(offset)) _bookmarksChanged();
  }

  // Line number + preview for every bookmark (bookmark panel). Line
  // numbers are exact within the indexed prefix, estimated beyond it.
  Future<List<BookmarkInfo>> _bookmarkDetails() async {
    final doc = _doc;
    if (doc == null) return const [];
    final sorted = _bookmarks.where((b) => b <= doc.length).toList()..sort();
    final out = <BookmarkInfo>[];
    for (final off in sorted) {
      final la = await doc.absoluteLineAt(off);
      var len = doc.length - off;
      if (len > 512) len = 512;
      var text = len > 0 ? (await doc.readRangeDecoded(off, len)).text : '';
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(0, nl);
      if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
      text = text.trim();
      if (text.length > 160) text = text.substring(0, 160);
      out.add(BookmarkInfo(off, la.line, la.exact, text));
    }
    return out;
  }

  // Document.onSplice: shift bookmark offsets with every edit (undo/redo
  // included -- apply() funnels through the same document paths). Bookmarks
  // inside a deleted range collapse onto its start.
  void _spliceBookmarks(int offset, int delta) {
    if (_bookmarks.isEmpty || delta == 0) return;
    var changed = false;
    final moved = <int>{};
    for (final b in _bookmarks) {
      var nb = b;
      if (b >= offset) {
        if (delta > 0) {
          nb = b + delta;
        } else {
          final end = offset - delta; // deleted range = [offset, end)
          nb = b >= end ? b + delta : offset;
        }
      }
      changed = changed || nb != b;
      moved.add(nb);
    }
    if (!changed && moved.length == _bookmarks.length) return;
    _bookmarks
      ..clear()
      ..addAll(moved);
    _bookmarksChanged();
  }

  void toggleBookmark() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final ls = await doc.lineStartOf(_caretOffset);
    if (!_bookmarks.remove(ls)) _bookmarks.add(ls);
    _bookmarksChanged();
  });

  void nextBookmark() => _jumpBookmark(1);

  void prevBookmark() => _jumpBookmark(-1);

  void clearBookmarks() {
    if (_bookmarks.isEmpty) return;
    _bookmarks.clear();
    _bookmarksChanged();
  }

  // Jump to the nearest bookmark after/before the caret's line, wrapping
  // around at either end.
  void _jumpBookmark(int dir) => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _bookmarks.isEmpty) return;
    final sorted = _bookmarks.where((b) => b <= doc.length).toList()..sort();
    if (sorted.isEmpty) return;
    final cur = await doc.lineStartOf(_caretOffset);
    final target = dir > 0
        ? sorted.firstWhere((b) => b > cur, orElse: () => sorted.first)
        : sorted.lastWhere((b) => b < cur, orElse: () => sorted.last);
    _colBlock = null;
    _selAnchor = null;
    _undo.breakCoalescing();
    await _moveCaretTo(target, false);
  });
}
