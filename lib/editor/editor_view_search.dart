part of 'editor_view.dart';

mixin _EditorViewSearch on State<EditorView> {
  Document? get _doc;
  bool get _hexMode;
  bool get _opening;
  bool get _readOnly;
  set _gotoOpen(bool value);
  int get _selStart;
  int get _selEnd;
  int get _caretOffset;
  set _caretOffset(int value);
  set _selAnchor(int? value);
  ColumnBlock? get _colBlock;
  set _colBlock(ColumnBlock? value);
  UndoStack get _undo;
  FocusNode get _focus;
  AppLocalizations get _l10n;

  void _toast(String msg);
  void _enqueueCaret(Future<void> Function() op);
  Future<void> _offQueue(String what, Future<void> Function() body);
  Future<void> _moveCaretTo(int offset, bool select);
  Future<void> _afterEdit();
  void _setModified(bool v);
  bool _blockedReadOnly();

  bool _searchOpen = false;
  bool _replaceOpen = false; // the second (replace) row of the bar
  bool _searchRegex = false;
  bool _searchCase = false;
  bool _searchWord = false; // whole word (alt+w)
  // Find in selection (alt+l): the selection at the moment the toggle went
  // on becomes the scope; matches outside it are ignored, wrap-around and
  // replace-all stay inside it. Edits shift it along (see _onDocSplice).
  bool _searchInSel = false;
  (int, int)? _searchScope;
  // Hex mode: query is a byte sequence (`FF 00 A1`, `??` = any byte) rather
  // than decoded text. Only consulted while in hex mode; defaults on when
  // entering it.
  bool _searchHex = false;
  bool get _byteSearch => _hexMode && _searchHex;
  bool _searching = false; // one chunked scan at a time
  final TextEditingController _searchCtl = TextEditingController();
  final TextEditingController _replaceCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _replaceFocus = FocusNode();

  // Scrollbar ticks for current find matches. Fresh list on every update so
  // the painter's identical-check sees changes; capped/partial by design.
  List<int> _searchMarksView = const [];
  Timer? _searchMarksTimer;
  int _searchMarksEpoch = 0;

  static const int _searchSeedMax = searchOverlap;
  int? _lastMatchStart, _lastMatchEnd;

  void openSearch() {
    if (_doc == null) return;
    setState(() {
      _searchOpen = true;
      _gotoOpen = false;
    });
    _searchFocus.requestFocus();
    _prefillSearchFromSelection();
    _scheduleSearchMarks();
  }

  void openReplace() {
    if (_doc == null) return;
    if (_hexMode) {
      openSearch(); // byte view edits bytes, not decoded text: search only
      return;
    }
    setState(() {
      _searchOpen = true;
      _replaceOpen = true;
      _gotoOpen = false;
    });
    _searchFocus.requestFocus();
    _prefillSearchFromSelection();
    _scheduleSearchMarks();
  }

  void _prefillSearchFromSelection() {
    _enqueueCaret(() async {
      // Prefill from the selection; regex queries are never overwritten
      // (the selection is literal text, not a pattern).
      final doc = _doc;
      final s = _selStart, e = _selEnd;
      if (doc != null && e > s && e - s <= _searchSeedMax) {
        if (_byteSearch) {
          _searchCtl.text = formatHexBytes(await doc.readRangeBytes(s, e - s));
        } else if (!_searchRegex) {
          _searchCtl.text = await doc.readRangeString(s, e - s);
        }
      }
      // Select the query so typing replaces it.
      _searchCtl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchCtl.text.length,
      );
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _replaceOpen = false;
    });
    _scheduleSearchMarks();
    _focus.requestFocus();
  }

  // Find in selection on: the current (non-empty) selection becomes the
  // scope — with nothing selected the existing scope is kept, else nothing
  // to scope to and the toggle stays off. Off: scope forgotten.
  void _toggleSearchInSel() {
    if (_searchInSel) {
      setState(() {
        _searchInSel = false;
        _searchScope = null;
      });
      _scheduleSearchMarks();
      return;
    }
    final s = _selStart, e = _selEnd;
    if (e > s && _colBlock == null) {
      setState(() {
        _searchInSel = true;
        _searchScope = (s, e);
      });
    } else if (_searchScope != null) {
      setState(() => _searchInSel = true);
    }
    _scheduleSearchMarks();
  }

  RegExp? _compileSearch() {
    final p = _searchCtl.text;
    if (p.isEmpty) return null;
    try {
      return compileQuery(
        p,
        regex: _searchRegex,
        caseSensitive: _searchCase,
        wholeWord: _searchWord,
      );
    } on FormatException {
      _toast(_l10n.tr('toast_bad_regex'));
      return null;
    }
  }

  // Debounced scrollbar find marks. Rapid typing / option toggles must not
  // stack up whole-file scans; the epoch drops results from an older query.
  void _scheduleSearchMarks() {
    _searchMarksTimer?.cancel();
    _searchMarksEpoch++;
    if (!_searchOpen || _byteSearch || _doc == null) {
      if (_searchMarksView.isEmpty) return;
      if (mounted) setState(() => _searchMarksView = const []);
      return;
    }
    _searchMarksTimer = Timer(
      const Duration(milliseconds: 300),
      _computeSearchMarks,
    );
  }

  Future<void> _computeSearchMarks() =>
      _offQueue('search marks', _computeSearchMarksNow);

  Future<void> _computeSearchMarksNow() async {
    final doc = _doc;
    if (doc == null || !mounted) return;
    if (!_searchOpen || _byteSearch) return;
    final re = _compileSearchSilent();
    if (re == null) {
      if (_searchMarksView.isNotEmpty) {
        setState(() => _searchMarksView = const []);
      }
      return;
    }
    final epoch = _searchMarksEpoch;
    final scope = _searchInSel ? _searchScope : null;
    final hits = await collectMatches(
      doc,
      re,
      from: scope?.$1 ?? 0,
      to: scope?.$2,
    );
    if (!mounted || epoch != _searchMarksEpoch || !identical(_doc, doc)) return;
    setState(
      () => _searchMarksView = List<int>.unmodifiable(hits.map((m) => m.start)),
    );
  }

  RegExp? _compileSearchSilent() {
    final p = _searchCtl.text;
    if (p.isEmpty) return null;
    try {
      return compileQuery(
        p,
        regex: _searchRegex,
        caseSensitive: _searchCase,
        wholeWord: _searchWord,
      );
    } on FormatException {
      return null;
    }
  }

  // Hex-mode byte query → pattern (null + toast when malformed or empty).
  List<int?>? _compileBytePattern() {
    try {
      final pat = parseHexPattern(_searchCtl.text);
      return pat.isEmpty ? null : pat;
    } on FormatException {
      _toast(_l10n.tr('toast_bad_hex'));
      return null;
    }
  }

  void findNext() => _find(forward: true);

  void findPrev() => _find(forward: false);

  // Replace the current hit (selection re-verified against the pattern —
  // the buffer may have changed since it was found), then jump to the next.
  // A selection that is not a match just jumps, like F3.
  void _replaceCurrent() {
    if (_blockedReadOnly()) return;
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final re = _compileSearch();
      if (re == null) return;
      final s = _selStart, e = _selEnd;
      if (e <= s) return;
      final m = await searchForward(doc, re, s);
      if (m == null || m.start != s || m.end != e) return;
      final text = expandReplacement(
        _replaceCtl.text,
        m.groups,
        regex: _searchRegex,
      );
      final enc = doc.codec.encode(text);
      final reverses = <ReverseEdit>[
        await doc.delete(m.start, m.end - m.start),
        if (enc.bytes.isNotEmpty) await doc.insertBytes(m.start, enc.bytes),
      ];
      _undo.push(ReverseEdit.group(reverses.reversed.toList()));
      _undo.breakCoalescing();
      if (enc.fallbackCount > 0) {
        _toast(
          _l10n.trf('toast_unencodable_many', [
            enc.fallbackCount,
            doc.codec.name,
          ]),
        );
      }
      _caretOffset = m.start + enc.bytes.length;
      _selAnchor = null;
      _lastMatchStart = _lastMatchEnd = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
    });
    _find(forward: true); // queued after the replace above
  }

  // Replace every match in the document, all of it one undo step. Walks
  // forward re-searching after each splice, so offsets never go stale.
  void _replaceAll() {
    if (_blockedReadOnly()) return;
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final re = _compileSearch();
      if (re == null) return;
      _searching = true;
      if (mounted) setState(() {});
      try {
        final scope = _searchInSel ? _searchScope : null;
        final (count, fallbacks) = await _replaceAllWith(
          doc,
          re,
          _replaceCtl.text,
          regex: _searchRegex,
          from: scope?.$1 ?? 0,
          to: scope?.$2,
        );
        if (count == 0) {
          _toast(_l10n.tr('toast_not_found'));
          return;
        }
        if (fallbacks > 0) {
          _toast(
            _l10n.trf('toast_unencodable_many', [fallbacks, doc.codec.name]),
          );
        }
        _toast(_l10n.trf('toast_replaced', [count]));
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
  }

  // Core of replace-all, shared with replace-in-files for panes that are
  // open: returns (replacements, unencodable chars); when anything was
  // replaced it is pushed as ONE undo step and the view is refreshed. Must
  // run inside the caret queue.
  Future<(int, int)> _replaceAllWith(
    Document doc,
    RegExp re,
    String template, {
    required bool regex,
    int from = 0,
    int? to, // find-in-selection: only matches ending here or before
  }) async {
    final reverses = <ReverseEdit>[];
    var pos = from, count = 0, fallbacks = 0;
    var limit = to;
    while (true) {
      final m = await searchForward(doc, re, pos);
      if (m == null || (limit != null && m.end > limit)) break;
      final text = expandReplacement(template, m.groups, regex: regex);
      final enc = doc.codec.encode(text);
      fallbacks += enc.fallbackCount;
      reverses.add(await doc.delete(m.start, m.end - m.start));
      if (enc.bytes.isNotEmpty) {
        reverses.add(await doc.insertBytes(m.start, enc.bytes));
      }
      pos = m.start + enc.bytes.length;
      if (limit != null) limit += enc.bytes.length - (m.end - m.start);
      count++;
    }
    if (count == 0) return (0, 0);
    // Reverses run newest-first on undo, so offsets stay valid.
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _lastMatchStart = _lastMatchEnd = null;
    if (_caretOffset > doc.length) _caretOffset = doc.length;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return (count, fallbacks);
  }

  // Replace-in-files entry for an open pane: edits the buffer (one undo
  // step, left modified — the user saves). null = this pane can't take it
  // (hex mode, still loading, busy), so the caller rewrites the disk file.
  Future<int?> _replaceAllMatches(
    RegExp re,
    String template, {
    required bool regex,
  }) {
    if (_readOnly) return Future.value(0); // read-only pane: nothing replaced
    final c = Completer<int?>();
    if (_searching || _hexMode || _doc == null || _opening) {
      c.complete(null);
      return c.future;
    }
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) {
        c.complete(null);
        return;
      }
      _searching = true;
      if (mounted) setState(() {});
      try {
        final (count, _) = await _replaceAllWith(
          doc,
          re,
          template,
          regex: regex,
        );
        c.complete(count);
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
    return c.future;
  }

  // F3/shift+F3 work from a closed bar too, and a selection the USER made
  // (≠ the previous hit — hits become selections, so "selection always
  // wins" would break query cycling) replaces the query. Regex queries are
  // never overwritten by seeding. The bar is shown for feedback without
  // stealing focus, so F3 keeps cycling from the editor.
  void _find({required bool forward}) {
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null) return;
      final s = _selStart, e = _selEnd;
      final isOwnHit = s == _lastMatchStart && e == _lastMatchEnd;
      final bytes = _byteSearch;
      if (e > s && !isOwnHit && e - s <= _searchSeedMax) {
        if (bytes) {
          _searchCtl.text = formatHexBytes(await doc.readRangeBytes(s, e - s));
        } else if (!_searchRegex) {
          _searchCtl.text = await doc.readRangeString(s, e - s);
        }
      }
      // Byte pattern (hex mode) or text regex — one of the two is compiled.
      List<int?>? pat;
      RegExp? re;
      if (bytes) {
        pat = _compileBytePattern();
        if (pat == null) return;
      } else {
        re = _compileSearch();
        if (re == null) return;
      }
      if (!_searchOpen && mounted) setState(() => _searchOpen = true);
      _searching = true;
      if (mounted) setState(() {});
      try {
        // Find-in-selection clamps the start point and rejects hits that
        // leave the scope; wrap-around restarts at the scope's edges.
        final scope = _searchInSel ? _searchScope : null;
        Future<SearchMatch?> fwd(int from) async {
          if (scope != null && from < scope.$1) from = scope.$1;
          final m = pat != null
              ? await searchBytesForward(doc, pat, from)
              : await searchForward(doc, re!, from);
          return m != null && scope != null && m.end > scope.$2 ? null : m;
        }

        Future<SearchMatch?> bwd(int before) async {
          if (scope != null && before > scope.$2) before = scope.$2;
          final m = pat != null
              ? await searchBytesBackward(doc, pat, before)
              : await searchBackward(doc, re!, before);
          return m != null && scope != null && m.start < scope.$1 ? null : m;
        }

        SearchMatch? m;
        var wrapped = false; // the hit came from restarting at the far edge
        if (forward) {
          // Continue after the current hit (= the selection), wrap once.
          final from = _selEnd > _selStart ? _selEnd : _caretOffset;
          final lo = scope?.$1 ?? 0;
          m = await fwd(from);
          if (m == null && from > lo) {
            m = await fwd(lo);
            wrapped = m != null;
          }
        } else {
          final before = _selEnd > _selStart ? _selStart : _caretOffset;
          final hi = scope?.$2 ?? doc.length;
          m = await bwd(before);
          if (m == null && before < hi) {
            m = await bwd(hi);
            wrapped = m != null;
          }
        }
        if (m == null) {
          _toast(_l10n.tr('toast_not_found'));
          return;
        }
        // Tell the user the search passed the end (or start) and continued
        // from the other edge — otherwise cycling silently jumps back to
        // the first hit and looks like a new one.
        if (wrapped) {
          _toast(
            _l10n.tr(
              forward
                  ? 'toast_search_wrapped_end'
                  : 'toast_search_wrapped_start',
            ),
          );
        }
        _colBlock = null;
        _selAnchor = m.start;
        _lastMatchStart = m.start;
        _lastMatchEnd = m.end;
        await _moveCaretTo(m.end, true);
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
  }

  Widget _buildSearchBar() {
    Widget toggle(String label, String tooltip, bool on, VoidCallback flip) =>
        Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: () {
              flip();
              _searchFocus.requestFocus();
            },
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: on ? _selColor : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: on ? _fg : _gutterFg,
                  fontSize: 12,
                  fontFamily: editorMonoFont,
                ),
              ),
            ),
          ),
        );

    Widget btn(IconData icon, String tooltip, VoidCallback? onTap) =>
        IconButton(
          icon: Icon(icon, size: 16),
          tooltip: tooltip,
          color: _gutterFg,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: onTap,
        );

    return Focus(
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          _closeSearch();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.f3) {
          _find(forward: !Mods.shift);
          return KeyEventResult.handled;
        }
        // VS Code's find-widget toggles: alt+c case, alt+r regex,
        // alt+w whole word, alt+l in selection.
        if (HardwareKeyboard.instance.isAltPressed && !_byteSearch) {
          final k = e.logicalKey;
          if (k == LogicalKeyboardKey.keyC) {
            setState(() => _searchCase = !_searchCase);
            _scheduleSearchMarks();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyR) {
            setState(() => _searchRegex = !_searchRegex);
            _scheduleSearchMarks();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyW) {
            setState(() => _searchWord = !_searchWord);
            _scheduleSearchMarks();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyL) {
            _toggleSearchInSel();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: _chromeBg,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.search, size: 16, color: _gutterFg),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _searchCtl,
                    focusNode: _searchFocus,
                    style: TextStyle(color: _fg, fontSize: 13),
                    cursorColor: _caretColor,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: _l10n.tr(
                        _byteSearch ? 'search_hint_hex' : 'search_hint',
                      ),
                      hintStyle: TextStyle(color: _gutterFg, fontSize: 13),
                    ),
                    onSubmitted: (_) {
                      _find(forward: true);
                      _searchFocus.requestFocus(); // keep typing/enter cycling
                    },
                  ),
                ),
                const SizedBox(width: 4),
                // Hex mode: bytes toggle; regex/case only apply to text.
                if (_hexMode) ...[
                  toggle('0x', _l10n.tr('tip_search_hex'), _searchHex, () {
                    setState(() => _searchHex = !_searchHex);
                    _scheduleSearchMarks();
                  }),
                  const SizedBox(width: 4),
                ],
                if (!_byteSearch) ...[
                  toggle('.*', _l10n.tr('tip_search_regex'), _searchRegex, () {
                    setState(() => _searchRegex = !_searchRegex);
                    _scheduleSearchMarks();
                  }),
                  const SizedBox(width: 4),
                  toggle('Aa', _l10n.tr('tip_search_case'), _searchCase, () {
                    setState(() => _searchCase = !_searchCase);
                    _scheduleSearchMarks();
                  }),
                  const SizedBox(width: 4),
                  toggle('ab', _l10n.tr('tip_search_word'), _searchWord, () {
                    setState(() => _searchWord = !_searchWord);
                    _scheduleSearchMarks();
                  }),
                  const SizedBox(width: 4),
                  toggle(
                    '≡',
                    _l10n.tr('tip_search_in_sel'),
                    _searchInSel,
                    _toggleSearchInSel,
                  ),
                  const SizedBox(width: 4),
                ],
                if (_searching)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  btn(
                    Icons.keyboard_arrow_up,
                    _l10n.tr('tip_search_prev'),
                    () => _find(forward: false),
                  ),
                  btn(
                    Icons.keyboard_arrow_down,
                    _l10n.tr('tip_search_next'),
                    () => _find(forward: true),
                  ),
                ],
                btn(Icons.close, _l10n.tr('tip_search_close'), _closeSearch),
              ],
            ),
            if (_replaceOpen)
              Row(
                children: [
                  Icon(Icons.find_replace, size: 16, color: _gutterFg),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _replaceCtl,
                      focusNode: _replaceFocus,
                      style: TextStyle(color: _fg, fontSize: 13),
                      cursorColor: _caretColor,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: _l10n.tr('replace_hint'),
                        hintStyle: TextStyle(color: _gutterFg, fontSize: 13),
                      ),
                      onSubmitted: (_) {
                        _replaceCurrent();
                        _replaceFocus.requestFocus();
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _searching ? null : _replaceCurrent,
                    child: Text(
                      _l10n.tr('btn_replace'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _searching ? null : _replaceAll,
                    child: Text(
                      _l10n.tr('btn_replace_all'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
