// Caret navigation history (pure Dart, tool/nav_history_test.dart): the
// VS Code "Go Back / Go Forward" ring for one pane. Positions are byte
// offsets; the pane records the position it *left* on a jump (goto line,
// search hit, bookmark, bracket, click far away) and `back` walks toward
// older entries, `forward` toward newer. Going back from the newest entry
// first stashes the current position so `forward` can return to it.

class NavHistory {
  NavHistory({this.capacity = 100});

  final int capacity;
  final List<int> _items = [];
  // Index into _items of the entry the caret is "at" while walking back;
  // -1 = at the live end (not walking).
  int _cursor = -1;

  List<int> get items => List.unmodifiable(_items);
  int get length => _items.length;
  bool get canBack => _items.isNotEmpty && (_cursor == -1 || _cursor > 0);
  bool get canForward => _cursor != -1 && _cursor < _items.length - 1;

  /// Record the position being left. Walking state is dropped (a fresh
  /// jump starts a new "future"); consecutive duplicates collapse.
  void record(int offset) {
    if (_cursor != -1) {
      // Branching off while walked back: newer entries are discarded, like
      // a browser history.
      _items.removeRange(_cursor + 1, _items.length);
      _cursor = -1;
    }
    if (_items.isNotEmpty && _items.last == offset) return;
    _items.add(offset);
    if (_items.length > capacity) _items.removeAt(0);
  }

  /// Older position to move to from [current], or null. [current] is stored
  /// as the newest entry the first time so [forward] can come back to it.
  int? back(int current) {
    if (_items.isEmpty) return null;
    if (_cursor == -1) {
      if (_items.last != current) {
        _items.add(current);
        if (_items.length > capacity) _items.removeAt(0);
      }
      _cursor = _items.length - 1;
    }
    if (_cursor <= 0) return null;
    _cursor--;
    return _items[_cursor];
  }

  /// Newer position, or null when already at the live end.
  int? forward() {
    if (_cursor == -1 || _cursor >= _items.length - 1) return null;
    _cursor++;
    final off = _items[_cursor];
    if (_cursor == _items.length - 1) _cursor = -1; // back at the live end
    return off;
  }

  /// Edits shift offsets: apply the same delta the document did.
  void shift(int from, int delta) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i] >= from) {
        final v = _items[i] + delta;
        _items[i] = v < from ? from : v;
      }
    }
  }

  void clear() {
    _items.clear();
    _cursor = -1;
  }
}
