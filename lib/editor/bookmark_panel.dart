// Bookmark panel sidebar (Search → Bookmark Panel).
//
// Lists the bookmarks of the active pane — or of every open pane — grouped
// by file with line number and a preview of the line. Click = jump (the
// shell selects the pane and moves the caret), ✕ = remove, per-file clear.
// Refreshes when any pane's bookmark set changes (EditorController.
// bookmarksEpoch, funnelled by the shell into [tick]) — debounced, since
// typing shifts offsets on every keystroke.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'editor_theme.dart';
import 'editor_view.dart';

class BookmarkPanel extends StatefulWidget {
  const BookmarkPanel({
    super.key,
    required this.controllers,
    required this.activeId,
    required this.tick,
    required this.onJump,
    required this.onClose,
  });

  final Map<int, EditorController> controllers;
  final int? activeId;

  /// Changes whenever some pane's bookmarks changed.
  final Listenable tick;
  final void Function(int paneId, int offset) onJump;
  final VoidCallback onClose;

  @override
  State<BookmarkPanel> createState() => _BookmarkPanelState();
}

class _Group {
  _Group(this.id, this.path, this.items);
  final int id;
  final String? path;
  final List<BookmarkInfo> items;
}

class _BookmarkPanelState extends State<BookmarkPanel> {
  bool _allFiles = false;
  List<_Group> _groups = const [];
  Timer? _debounce;
  int _loadSerial = 0;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    widget.tick.addListener(_scheduleReload);
    _reload();
  }

  @override
  void didUpdateWidget(BookmarkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tick, widget.tick)) {
      oldWidget.tick.removeListener(_scheduleReload);
      widget.tick.addListener(_scheduleReload);
    }
    if (oldWidget.activeId != widget.activeId ||
        oldWidget.controllers.length != widget.controllers.length) {
      _scheduleReload();
    }
  }

  @override
  void dispose() {
    widget.tick.removeListener(_scheduleReload);
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _reload);
  }

  Future<void> _reload() async {
    final serial = ++_loadSerial;
    final ids = _allFiles
        ? widget.controllers.keys.toList()
        : [if (widget.activeId != null) widget.activeId!];
    final groups = <_Group>[];
    for (final id in ids) {
      final c = widget.controllers[id];
      if (c == null || !c.hasDoc) continue;
      final items = await c.bookmarkDetails();
      if (serial != _loadSerial) return; // superseded
      if (items.isEmpty && _allFiles) continue;
      groups.add(_Group(id, c.path, items));
    }
    if (!mounted || serial != _loadSerial) return;
    setState(() => _groups = groups);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final fg = editorFg;
    final dim = editorGutterFg;
    final total = _groups.fold<int>(0, (a, g) => a + g.items.length);
    return Material(
      color: editorChromeBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 2, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${l10n.tr('bm_panel_title')}  ($total)',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Tooltip(
                  message: l10n.tr('bm_all_files'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _allFiles,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) {
                          setState(() => _allFiles = v ?? false);
                          _reload();
                        },
                      ),
                      Text(
                        l10n.tr('bm_all_files'),
                        style: TextStyle(color: fg, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close, size: 17),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: total == 0
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        l10n.tr('bm_none'),
                        style: TextStyle(color: dim, fontSize: 12),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final g in _groups) ...[
                        _groupHeader(g, fg, dim),
                        for (final b in g.items) _row(g, b, fg, dim),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(_Group g, Color fg, Color dim) {
    final l10n = _l10n;
    final name = g.path == null
        ? l10n.tr('common_untitled')
        : g.path!.split(Platform.pathSeparator).last;
    return Container(
      color: editorBg.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 14),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: g.path ?? name,
              child: Text(
                '$name  (${g.items.length})',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.tr('bm_clear_file'),
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: g.items.isEmpty
                ? null
                : () => widget.controllers[g.id]?.clearBookmarks(),
          ),
        ],
      ),
    );
  }

  Widget _row(_Group g, BookmarkInfo b, Color fg, Color dim) {
    final l10n = _l10n;
    final lineText = b.exact
        ? l10n.trf('bm_line', [b.line + 1])
        : l10n.trf('bm_line_approx', [b.line + 1]);
    return InkWell(
      onTap: () => widget.onJump(g.id, b.offset),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
        child: Row(
          children: [
            Icon(
              Icons.bookmark,
              size: 14,
              color: editorSelColor.withValues(alpha: 1),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 72,
              child: Text(
                lineText,
                style: TextStyle(color: dim, fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: Text(
                b.preview.isEmpty ? ' ' : b.preview,
                style: TextStyle(
                  color: fg,
                  fontSize: 12.5,
                  fontFamily: editorMonoFont,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: l10n.tr('common_delete'),
              icon: const Icon(Icons.close, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              onPressed: () =>
                  widget.controllers[g.id]?.removeBookmark(b.offset),
            ),
          ],
        ),
      ),
    );
  }
}
