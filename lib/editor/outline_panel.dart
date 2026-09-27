// Document outline sidebar (View → Document Outline).
//
// Shows the symbols outline.dart finds in the active pane with the
// language's rules (settings/outline.json): indented by depth, with a kind
// icon; click = jump. Rescans when the document changes
// (EditorController.docEpoch, debounced — typing bumps it per keystroke)
// or when the pane / language changes. The caret's enclosing symbol is
// highlighted from the caret offset the shell passes in.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'editor_theme.dart';
import 'editor_view.dart';
import 'outline.dart';

class OutlinePanel extends StatefulWidget {
  const OutlinePanel({
    super.key,
    required this.controller,
    required this.language,
    required this.caretOffset,
    required this.onJump,
    required this.onClose,
  });

  /// The active pane (null = none).
  final EditorController? controller;

  /// Rules for the active file (null = no rules for this file type).
  final OutlineLanguage? language;
  final int caretOffset;
  final void Function(int offset) onJump;
  final VoidCallback onClose;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  OutlineResult? _result;
  bool _scanning = false;
  int _serial = 0;
  Timer? _debounce;
  final TextEditingController _filter = TextEditingController();
  final ScrollController _scroll = ScrollController();

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    widget.controller?.docEpoch.addListener(_scheduleScan);
    _scan();
  }

  @override
  void didUpdateWidget(OutlinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.docEpoch.removeListener(_scheduleScan);
      widget.controller?.docEpoch.addListener(_scheduleScan);
      _result = null;
      _scan();
    } else if (oldWidget.language?.name != widget.language?.name) {
      _scan();
    }
  }

  @override
  void dispose() {
    widget.controller?.docEpoch.removeListener(_scheduleScan);
    _debounce?.cancel();
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleScan() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _scan);
  }

  Future<void> _scan() async {
    final serial = ++_serial;
    final c = widget.controller;
    final lang = widget.language;
    if (c == null || lang == null) {
      if (mounted) setState(() => _result = null);
      return;
    }
    setState(() => _scanning = true);
    final r = await c.scanOutlineWith(lang, cancelled: () => serial != _serial);
    if (!mounted || serial != _serial) return;
    setState(() {
      _scanning = false;
      if (r != null) _result = r;
    });
  }

  static IconData _icon(String kind) => switch (kind) {
    'function' => Icons.functions,
    'method' => Icons.functions,
    'class' => Icons.class_outlined,
    'heading' => Icons.title,
    'variable' => Icons.label_outline,
    'section' => Icons.segment,
    _ => Icons.circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final fg = editorFg;
    final dim = editorGutterFg;
    final r = _result;
    final q = _filter.text.trim().toLowerCase();
    final items = r == null
        ? const <OutlineItem>[]
        : q.isEmpty
        ? r.items
        : [
            for (final i in r.items)
              if (i.name.toLowerCase().contains(q)) i,
          ];
    // The symbol the caret is in: the last item at or before the caret.
    int current = -1;
    if (r != null && q.isEmpty) {
      for (var i = 0; i < r.items.length; i++) {
        if (r.items[i].offset <= widget.caretOffset) current = i;
      }
    }
    return Material(
      color: editorGutterBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 2, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${l10n.tr('ol_title')}  (${r?.items.length ?? 0})',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_scanning)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                IconButton(
                  tooltip: l10n.tr('explorer_refresh'),
                  icon: const Icon(Icons.refresh, size: 17),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  onPressed: _scan,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: SizedBox(
              height: 28,
              child: TextField(
                controller: _filter,
                style: TextStyle(fontSize: 12.5, color: fg),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.tr('ol_filter_hint'),
                  prefixIcon: const Icon(Icons.filter_alt_outlined, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.controller == null || widget.language == null
                ? _hint(l10n.tr('ol_no_rules'), dim)
                : items.isEmpty
                ? _hint(l10n.tr('ol_none'), dim)
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: 22,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final it = items[i];
                      final isCur =
                          q.isEmpty &&
                          current >= 0 &&
                          identical(r!.items[current], it);
                      return InkWell(
                        onTap: () => widget.onJump(it.offset),
                        child: Container(
                          color: isCur
                              ? editorSelColor.withValues(alpha: 0.35)
                              : null,
                          padding: EdgeInsets.only(
                            left: 8 + it.depth * 12.0,
                            right: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(_icon(it.kind), size: 14, color: dim),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  it.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: fg,
                                    fontFamily: editorMonoFont,
                                  ),
                                ),
                              ),
                              Text(
                                '${it.line + 1}',
                                style: TextStyle(fontSize: 11, color: dim),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (r != null && r.truncated)
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                l10n.trf('ol_truncated', [outlineMaxBytes >> 20]),
                style: TextStyle(fontSize: 11, color: dim),
              ),
            ),
        ],
      ),
    );
  }

  Widget _hint(String text, Color dim) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(text, style: TextStyle(color: dim, fontSize: 12)),
    ),
  );
}
