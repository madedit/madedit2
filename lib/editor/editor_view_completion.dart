part of 'editor_view.dart';

mixin _EditorViewCompletion on State<EditorView> {
  Document? get _doc;
  String? get _path;
  int get _caretOffset;
  bool get _hexMode;
  bool get _readOnly;
  String get _composing;
  bool get _multi;
  double get _viewportW;
  double get _viewportH;
  double get _lineHeight;
  AppLocalizations get _l10n;

  void _toast(String msg);
  void _enqueueCaret(Future<void> Function() op);
  Future<void> _offQueue(String what, Future<void> Function() body);
  Future<void> _forEachCursor(Future<void> Function(int docOrderIndex) op);
  Future<void> _doInsert(String rawText);
  set _selAnchor(int? value);
  Offset? _caretScreenPos();

  Set<String> _words = const {};
  Timer? _wordScanTimer;
  int _wordScanSerial = 0;
  _CompletionState? _completion;

  void _scheduleWordScan() {
    if (!AppSettings.instance.autoComplete && _completion == null) return;
    _wordScanTimer?.cancel();
    _wordScanTimer = Timer(const Duration(milliseconds: 1200), _scanWords);
  }

  Future<void> _scanWords() => _offQueue('word scan', _scanWordsNow);

  Future<void> _scanWordsNow() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final serial = ++_wordScanSerial;
    final words = await scanDocumentWords(
      doc,
      cancelled: () => serial != _wordScanSerial,
    );
    if (!mounted || serial != _wordScanSerial) return;
    _words = words;
  }

  Set<String> get _languageKeywords {
    final p = _path;
    if (p == null) return const {};
    final dot = p.lastIndexOf('.');
    final ext = dot >= 0 ? p.substring(dot + 1).toLowerCase() : '';
    return HighlightConfig.instance.forExt(ext).keywords;
  }

  // The identifier prefix before the caret (null when the line is too long
  // to read cheaply or the caret is not right after a word).
  Future<String?> _wordPrefixAtCaret() async {
    final doc = _doc;
    if (doc == null) return null;
    final ls = await doc.lineStartOf(_caretOffset);
    final len = _caretOffset - ls;
    if (len <= 0 || len > 4096) return len <= 0 ? '' : null;
    final d = await doc.readRangeDecoded(ls, len);
    return wordPrefixBefore(d.text, d.text.length);
  }

  // After a keystroke landed: open / refresh / close the popup.
  Future<void> _completionAfterTyping(String typed) async {
    final s = AppSettings.instance;
    if (_hexMode || _readOnly || _composing.isNotEmpty || _multi) {
      _closeCompletion();
      return;
    }
    final open = _completion != null;
    if (!open) {
      if (!s.autoComplete) return;
      // Only a typed word character opens it (not paste, Enter, space...).
      if (typed.length != 1 || !isWordCodeUnit(typed.codeUnitAt(0))) return;
    }
    final prefix = await _wordPrefixAtCaret();
    if (prefix == null || prefix.isEmpty) {
      _closeCompletion();
      return;
    }
    if (!open && prefix.length < s.autoCompleteMinChars) return;
    if (_words.isEmpty && _wordScanTimer == null) {
      await _scanWords(); // first use on this document
    }
    _showCompletion(prefix, manual: false);
  }

  void _showCompletion(String prefix, {required bool manual}) {
    final items = completionsFor(
      _words,
      prefix,
      keywords: _languageKeywords,
      max: 12,
    );
    if (items.isEmpty) {
      _closeCompletion();
      if (manual) _toast(_l10n.tr('toast_no_completion'));
      return;
    }
    final pos = _caretScreenPos();
    if (pos == null) {
      _closeCompletion();
      return;
    }
    final prev = _completion;
    setState(() {
      _completion = _CompletionState(
        prefix: prefix,
        items: items,
        selected: prev != null && prev.selected < items.length
            ? prev.selected
            : 0,
        anchor: pos,
      );
    });
  }

  void _closeCompletion() {
    if (_completion == null) return;
    if (mounted) setState(() => _completion = null);
  }

  void _acceptCompletion([int? index]) {
    final c = _completion;
    if (c == null) return;
    final i = index ?? c.selected;
    if (i < 0 || i >= c.items.length) return;
    final word = c.items[i].word;
    final prefix = c.prefix;
    _closeCompletion();
    // Replace the typed prefix (case may differ) with the whole word.
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null) return;
      final tail = word.startsWith(prefix)
          ? word.substring(prefix.length)
          : null;
      if (tail != null) {
        await _forEachCursor((_) => _doInsert(tail));
      } else {
        await _forEachCursor((_) async {
          final ls = await doc.lineStartOf(_caretOffset);
          final len = _caretOffset - ls;
          final d = await doc.readRangeDecoded(ls, len);
          final p = wordPrefixBefore(d.text, d.text.length);
          final pStart = ls + d.byteForCodeUnit(d.text.length - p.length);
          _selAnchor = pStart;
          await _doInsert(word); // replaces the selection
        });
      }
    });
  }

  // Keys the popup owns while open. True = consumed.
  bool _completionKey(KeyEvent e) {
    final c = _completion;
    if (c == null) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      _closeCompletion();
      return true;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.tab) {
      _acceptCompletion();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final n = c.items.length;
      final d = k == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => c.selected = (c.selected + d + n) % n);
      return true;
    }
    if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.pageUp) {
      final n = c.items.length;
      final d = k == LogicalKeyboardKey.pageDown ? 6 : -6;
      setState(() => c.selected = (c.selected + d).clamp(0, n - 1));
      return true;
    }
    // Anything else that moves the caret (Home/End/left/right) closes it;
    // typing keeps it open and re-filters through _completionAfterTyping.
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.home ||
        k == LogicalKeyboardKey.end) {
      _closeCompletion();
    }
    return false;
  }

  void triggerCompletion() => _enqueueCaret(() async {
    if (_doc == null || _hexMode || _readOnly) return;
    final prefix = await _wordPrefixAtCaret();
    if (prefix == null || prefix.isEmpty) return;
    if (_words.isEmpty) await _scanWords();
    _showCompletion(prefix, manual: true);
  });

  Widget _completionPopup() {
    final c = _completion!;
    const w = 260.0;
    const rowH = 24.0;
    final h = c.items.length * rowH + 4;
    var left = c.anchor.dx;
    if (left + w > _viewportW) left = (_viewportW - w).clamp(0.0, left);
    var top = c.anchor.dy;
    if (top + h > _viewportH && c.anchor.dy - _lineHeight - h >= 0) {
      top = c.anchor.dy - _lineHeight - h; // not enough room below: above
    }
    final theme = Theme.of(context);
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Material(
        key: const ValueKey('completion-popup'),
        elevation: 6,
        borderRadius: BorderRadius.circular(4),
        color: theme.colorScheme.surfaceContainerHigh,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemExtent: rowH,
          itemCount: c.items.length,
          itemBuilder: (_, i) {
            final it = c.items[i];
            final sel = i == c.selected;
            return InkWell(
              onTap: () => _acceptCompletion(i),
              child: Container(
                color: sel
                    ? theme.colorScheme.primary.withValues(alpha: 0.25)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      it.keyword ? Icons.key : Icons.text_fields,
                      size: 14,
                      color: theme.disabledColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: TextStyle(
                            fontFamily: editorMonoFont,
                            fontSize: 13,
                            color: theme.colorScheme.onSurface,
                          ),
                          children: [
                            TextSpan(
                              text: it.word.substring(0, c.prefix.length),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(text: it.word.substring(c.prefix.length)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompletionState {
  _CompletionState({
    required this.prefix,
    required this.items,
    required this.selected,
    required this.anchor,
  });
  final String prefix;
  final List<Completion> items;
  int selected;
  final Offset anchor; // just below the caret, viewport coordinates
}
