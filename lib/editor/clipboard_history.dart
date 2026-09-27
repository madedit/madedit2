// Clipboard history (Edit → Clipboard History…, ctrl+shift+v): what the editor
// copied/cut this session, plus whatever the system clipboard held when
// the window regained focus. In memory only; newest first, deduplicated.
// Pure Dart.

class ClipboardHistory {
  static final ClipboardHistory instance = ClipboardHistory();

  static const int maxItems = 30;
  static const int maxItemChars = 1 << 20;

  final List<String> _items = [];
  List<String> get items => List.unmodifiable(_items);

  /// Record [text] as the most recent entry (moved to the front if already
  /// present; empty / oversized text ignored).
  void add(String text) {
    if (text.isEmpty || text.length > maxItemChars) return;
    _items.remove(text);
    _items.insert(0, text);
    if (_items.length > maxItems) _items.removeRange(maxItems, _items.length);
  }

  void clear() => _items.clear();
}
