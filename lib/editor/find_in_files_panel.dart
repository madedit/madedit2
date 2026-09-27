// Find/Replace-in-Files bottom panel (Search → Find in Files…, ctrl+shift+f).
//
// Hosts the query/replacement/folder/pattern inputs and the streaming result
// list; the actual work is the pure-Dart core in find_in_files.dart, run
// right here on the UI isolate (it is chunked awaits, same as the in-editor
// search). Result updates are throttled to one setState per 100ms —
// thousands of per-match setStates would freeze the list. Clicking a result
// hands (path, byteStart, byteEnd) to the shell, which opens/jumps and
// selects.
//
// Replace-all asks for confirmation first: files open in a pane are edited
// in their buffer (undoable, left modified), every other file is rewritten
// on disk — which is not undoable.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../l10n/app_localizations.dart';
import '../settings/app_settings.dart';
import '../util/atomic_file.dart';
import 'find_in_files.dart';
import 'search.dart' show compileQuery;

class FindInFilesPanel extends StatefulWidget {
  const FindInFilesPanel({
    super.key,
    required this.initialFolder,
    required this.onOpenMatch,
    required this.onClose,
    this.replaceInOpen,
    this.replaceFile,
  });

  /// Prefill for the folder field (the active file's directory).
  final String initialFolder;

  final void Function(String path, int byteStart, int byteEnd) onOpenMatch;
  final VoidCallback onClose;

  /// Replace-all hook for files the shell has open: return the count once
  /// the open buffer is edited, or null to have the disk file rewritten.
  final Future<int?> Function(
    String path,
    RegExp re,
    String replacement,
    bool regex,
  )?
  replaceInOpen;

  /// Atomic temp→dest swap override (macOS sandbox); null = plain dart:io.
  final ReplaceFileFn? replaceFile;

  @override
  State<FindInFilesPanel> createState() => FindInFilesPanelState();
}

class FindInFilesPanelState extends State<FindInFilesPanel> {
  final TextEditingController _queryCtl = TextEditingController();
  final TextEditingController _replaceCtl = TextEditingController();
  late final TextEditingController _folderCtl = TextEditingController(
    text: widget.initialFolder,
  );
  final TextEditingController _patternsCtl = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  bool _regex = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _recursive = true;
  bool _showReplace = false; // replace row is collapsed by default
  bool _searching = false; // a search OR a replace run is in flight
  FifCancel? _cancel;

  final List<FifMatch> _results = [];
  // Per-file outcome rows of the last replace run (shown instead of matches).
  final List<(String, FifReplaceOutcome)> _replaced = [];
  String _status = '';
  Timer? _flushTimer; // batches match/progress updates into one repaint

  AppLocalizations get _l10n => AppLocalizations.of(context);

  /// Shell calls this when the panel is (re)opened via menu/shortcut.
  void focusQuery() => _queryFocus.requestFocus();

  /// ctrl+shift+h: make sure the replace row is visible.
  void showReplace() {
    if (!_showReplace) setState(() => _showReplace = true);
  }

  @override
  void dispose() {
    _cancel?.cancelled = true;
    _flushTimer?.cancel();
    _queryCtl.dispose();
    _replaceCtl.dispose();
    _folderCtl.dispose();
    _patternsCtl.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _flushTimer = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      initialDirectory: Directory(_folderCtl.text).existsSync()
          ? _folderCtl.text
          : null,
    );
    if (dir != null) _folderCtl.text = dir;
  }

  /// Validate folder + query and compile the search; null (with the status
  /// line set) when the inputs are unusable.
  (String, RegExp)? _prepare() {
    final folder = _folderCtl.text.trim();
    if (folder.isEmpty || !Directory(folder).existsSync()) {
      setState(() => _status = _l10n.tr('fif_bad_folder'));
      return null;
    }
    if (_queryCtl.text.isEmpty) return null;
    try {
      final re = compileQuery(
        _queryCtl.text,
        regex: _regex,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
      );
      return (folder, re);
    } on FormatException {
      setState(() => _status = _l10n.tr('toast_bad_regex'));
      return null;
    }
  }

  Future<void> _run() async {
    if (_searching) return;
    final prep = _prepare();
    if (prep == null) return;
    final (folder, re) = prep;
    final cancel = FifCancel();
    setState(() {
      _searching = true;
      _cancel = cancel;
      _results.clear();
      _replaced.clear();
      _status = '';
    });
    final summary = await findInFiles(
      root: folder,
      re: re,
      patterns: _patternsCtl.text,
      recursive: _recursive,
      cancel: cancel,
      onMatch: (m) {
        _results.add(m);
        _scheduleFlush();
      },
      onFile: (path, n) {
        _status = _l10n.trf('fif_status_running', [path]);
        _scheduleFlush();
      },
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _cancel = null;
      _status = summary.truncated
          ? _l10n.trf('fif_status_truncated', [summary.matches])
          : _l10n.trf('fif_status_done', [
              summary.matches,
              summary.filesMatched,
              summary.filesScanned,
            ]);
    });
  }

  Future<void> _replaceAll() async {
    if (_searching) return;
    final prep = _prepare();
    if (prep == null) return;
    final (folder, re) = prep;
    final l10n = _l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('fif_replace_confirm_title')),
        content: Text(
          l10n.trf('fif_replace_confirm_body', [
            _queryCtl.text,
            _replaceCtl.text,
            folder,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('fif_replace_all')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final cancel = FifCancel();
    setState(() {
      _searching = true;
      _cancel = cancel;
      _results.clear();
      _replaced.clear();
      _status = '';
    });
    final replacement = _replaceCtl.text;
    final inOpen = widget.replaceInOpen;
    final summary = await replaceInFiles(
      root: folder,
      re: re,
      replacement: replacement,
      regex: _regex,
      patterns: _patternsCtl.text,
      recursive: _recursive,
      cancel: cancel,
      replaceFile: widget.replaceFile ?? atomicReplaceFile,
      inOpenFile: inOpen == null
          ? null
          : (path) => inOpen(path, re, replacement, _regex),
      onFile: (path, n) {
        _status = _l10n.trf('fif_status_running', [path]);
        _scheduleFlush();
      },
      onFileDone: (path, out) {
        _replaced.add((path, out));
        _scheduleFlush();
      },
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _cancel = null;
      _status = _l10n.trf('fif_replace_done', [
        summary.replacements,
        summary.filesChanged,
        summary.filesScanned,
      ]);
      if (summary.failed > 0) {
        _status += '  ${_l10n.trf('fif_replace_failed', [summary.failed])}';
      }
    });
  }

  void _stop() => _cancel?.cancelled = true;

  Widget _resultRow(FifMatch m) {
    final name = m.path.split(Platform.pathSeparator).last;
    final fg = Color(AppSettings.instance.fgArgb);
    final dim = Color(AppSettings.instance.gutterFgArgb);
    final hlBg = Color(AppSettings.instance.selectionArgb);
    return InkWell(
      onTap: () => widget.onOpenMatch(m.path, m.byteStart, m.byteEnd),
      child: Tooltip(
        message: m.path,
        waitDuration: const Duration(milliseconds: 700),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(fontSize: 12.5, color: fg),
              children: [
                TextSpan(
                  text: '$name:${m.line}:  ',
                  style: TextStyle(color: dim),
                ),
                TextSpan(text: m.preview.substring(0, m.hlStart)),
                TextSpan(
                  text: m.preview.substring(m.hlStart, m.hlEnd),
                  style: TextStyle(backgroundColor: hlBg),
                ),
                TextSpan(text: m.preview.substring(m.hlEnd)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _replacedRow((String, FifReplaceOutcome) r) {
    final (path, out) = r;
    final fg = Color(AppSettings.instance.fgArgb);
    final dim = Color(AppSettings.instance.gutterFgArgb);
    final detail = out.error != null
        ? _l10n.trf('fif_replace_row_error', [out.error!])
        : _l10n.trf('fif_replace_row', [out.count]);
    return InkWell(
      onTap: () => widget.onOpenMatch(path, 0, 0),
      child: Tooltip(
        message: path,
        waitDuration: const Duration(milliseconds: 700),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(fontSize: 12.5, color: fg),
              children: [
                TextSpan(text: path),
                TextSpan(
                  text: '   $detail',
                  style: TextStyle(
                    color: out.error != null
                        ? Theme.of(context).colorScheme.error
                        : dim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final bg = Color(AppSettings.instance.chromeBgArgb);
    final fg = Color(AppSettings.instance.fgArgb);
    InputDecoration deco(String hint) => InputDecoration(
      isDense: true,
      hintText: hint,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );
    final showReplaced = _replaced.isNotEmpty && _results.isEmpty;
    // Escape anywhere in the panel closes it (like the in-pane search bar);
    // a running search is cancelled by dispose.
    return Focus(
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: bg,
        child: Column(
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _queryCtl,
                      focusNode: _queryFocus,
                      decoration: deco(l10n.tr('fif_query_hint')),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: l10n.tr('tip_search_regex'),
                    isSelected: _regex,
                    onPressed: _searching
                        ? null
                        : () => setState(() => _regex = !_regex),
                    icon: const Text('.*'),
                  ),
                  IconButton(
                    tooltip: l10n.tr('tip_search_case'),
                    isSelected: _caseSensitive,
                    onPressed: _searching
                        ? null
                        : () =>
                              setState(() => _caseSensitive = !_caseSensitive),
                    icon: const Text('Aa'),
                  ),
                  IconButton(
                    tooltip: l10n.tr('tip_search_word'),
                    isSelected: _wholeWord,
                    onPressed: _searching
                        ? null
                        : () => setState(() => _wholeWord = !_wholeWord),
                    icon: const Text('ab'),
                  ),
                  IconButton(
                    tooltip: l10n.tr('fif_replace_hint'),
                    isSelected: _showReplace,
                    onPressed: _searching
                        ? null
                        : () => setState(() => _showReplace = !_showReplace),
                    icon: const Icon(Icons.find_replace, size: 18),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _searching ? _stop : _run,
                    child: Text(
                      _searching ? l10n.tr('fif_stop') : l10n.tr('fif_search'),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            if (_showReplace)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _replaceCtl,
                        enabled: !_searching,
                        decoration: deco(l10n.tr('fif_replace_hint')),
                      ),
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed: _searching ? null : _replaceAll,
                      child: Text(l10n.tr('fif_replace_all')),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _folderCtl,
                      enabled: !_searching,
                      decoration: deco(l10n.tr('fif_folder_hint')),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.tr('fif_folder_hint'),
                    onPressed: _searching ? null : _pickFolder,
                    icon: const Icon(Icons.folder_open, size: 18),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _patternsCtl,
                      enabled: !_searching,
                      decoration: deco(l10n.tr('fif_patterns_hint')),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Checkbox(
                    value: _recursive,
                    onChanged: _searching
                        ? null
                        : (v) => setState(() => _recursive = v ?? true),
                  ),
                  Text(
                    l10n.tr('fif_recursive'),
                    style: TextStyle(color: fg, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(AppSettings.instance.gutterFgArgb),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Container(
                color: Color(AppSettings.instance.bgArgb),
                child: showReplaced
                    ? ListView.builder(
                        controller: _scroll,
                        itemExtent: 22,
                        itemCount: _replaced.length,
                        itemBuilder: (_, i) => _replacedRow(_replaced[i]),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: 22,
                        itemCount: _results.length,
                        itemBuilder: (_, i) => _resultRow(_results[i]),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
