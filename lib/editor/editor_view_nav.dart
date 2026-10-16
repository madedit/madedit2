part of 'editor_view.dart';

mixin _EditorViewNavHistory {
  Document? get _doc;
  int get _caretOffset;
  set _colBlock(ColumnBlock? value);
  set _selAnchor(int? value);
  void _enqueueCaret(Future<void> Function() op);
  Future<void> _moveCaretTo(int offset, bool select);

  final NavHistory _nav = NavHistory();
  bool _navigating = false;
  int? _lastEditOffset;

  Future<void> _navTo(int? off) async {
    if (off == null || _doc == null) return;
    _navigating = true;
    try {
      _colBlock = null;
      _selAnchor = null;
      await _moveCaretTo(off, false);
    } finally {
      _navigating = false;
    }
  }

  void navBack() => _enqueueCaret(() => _navTo(_nav.back(_caretOffset)));

  void navForward() => _enqueueCaret(() => _navTo(_nav.forward()));

  void navLastEdit() => _enqueueCaret(() async {
    final off = _lastEditOffset;
    if (off == null || off == _caretOffset) return;
    _recordJumpFrom(_caretOffset);
    await _navTo(off);
  });

  void _recordJumpFrom(int from) {
    if (!_navigating) _nav.record(from);
  }

  void _spliceNav(int offset, int delta) {
    _nav.shift(offset, delta);
    int sh(int x) => x < offset ? x : (x + delta < offset ? offset : x + delta);
    final le = _lastEditOffset;
    if (le != null) _lastEditOffset = sh(le);
  }
}
