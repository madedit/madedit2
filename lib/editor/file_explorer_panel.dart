// File explorer sidebar (View → File Explorer, ctrl+b).
//
// A lazily loaded directory tree (file_explorer.dart) painted as a flat
// list of rows: header (root name, choose / up / refresh / collapse /
// locate / close), a filter box, then the rows. Single click opens a file
// or toggles a folder; ctrl+click toggles a row in the selection and
// shift+click selects a range; right-click gives new file / folder,
// rename, delete, copy path, reveal in the OS file manager, set as root
// (delete / copy path / open act on the whole selection). Rows can be
// dragged onto a folder (or a file: its folder, or the empty area: the
// root) to move them there. Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste
// the selection through a panel-local clipboard (paste target: the
// selected folder, a selected file's folder, or the root); Delete, F2
// (rename) and Ctrl+A (select all visible) work on the focused panel. The shell owns the root path (persisted in
// settings) and tells the panel which file is active so it can be
// highlighted and located.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../settings/app_settings.dart';
import '../util/dispose_later.dart';
import 'editor_theme.dart';
import 'file_explorer.dart';

class FileExplorerPanel extends StatefulWidget {
  const FileExplorerPanel({
    super.key,
    required this.root,
    required this.activePath,
    required this.onOpen,
    required this.onRootChanged,
    required this.onClose,
    required this.onRevealInOs,
    this.onBeforeMutate,
    this.onAfterRename,
  });

  /// Called before renaming/deleting [path] (a file, or a folder and all
  /// beneath it): the shell closes the panes that hold those files open —
  /// Windows refuses to rename/delete a file with an open handle. Returns
  /// false to abort (the user kept a modified pane).
  final Future<bool> Function(String path)? onBeforeMutate;

  /// After a successful rename: the shell reopens what it closed, at the
  /// new location.
  final void Function(String oldPath, String newPath)? onAfterRename;

  final String root;
  final String? activePath;
  final void Function(String path) onOpen;
  final void Function(String root) onRootChanged;
  final VoidCallback onClose;
  final void Function(String path) onRevealInOs;

  @override
  State<FileExplorerPanel> createState() => FileExplorerPanelState();
}

class FileExplorerPanelState extends State<FileExplorerPanel> {
  late ExplorerTree _tree = ExplorerTree(widget.root);
  final TextEditingController _filter = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Set<String> _selected = {};
  String? _anchor; // shift+click range start
  String? _dropTarget; // folder highlighted while a drag hovers it
  final FocusNode _focus = FocusNode(debugLabel: 'explorer');
  // Panel-local clipboard: paths copied / cut here (the OS clipboard only
  // gets the paths as text — Flutter cannot put files on it).
  List<String> _clip = const [];
  bool _clipCut = false;
  int _epoch = 0; // bumps when the tree mutates (rows recomputed in build)

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _tree.load(_tree.root).then((_) => _bump());
  }

  @override
  void didUpdateWidget(FileExplorerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) {
      _tree = ExplorerTree(widget.root);
      _tree.load(_tree.root).then((_) => _bump());
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _bump() {
    if (mounted) setState(() => _epoch++);
  }

  /// Reload every expanded directory (window focus, after our own edits).
  Future<void> refresh() async {
    await _tree.refresh();
    _bump();
  }

  /// Expand to and highlight the active file.
  Future<void> locateActive() async {
    final p = widget.activePath;
    if (p == null) return;
    if (!_tree.contains(p)) {
      // Outside the root: re-root at the file's folder.
      widget.onRootChanged(File(p).parent.path);
      return;
    }
    final node = await _tree.reveal(p);
    if (node == null) return;
    _filter.clear();
    setState(() {
      _select(node.path);
      _epoch++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rows = _tree.visible();
      final i = rows.indexWhere((n) => n.path == node.path);
      if (i >= 0 && _scroll.hasClients) {
        final y = i * _rowH - _scroll.position.viewportDimension / 3;
        _scroll.jumpTo(y.clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  static const double _rowH = 22;

  Future<void> _chooseRoot() async {
    final dir = await FilePicker.getDirectoryPath(
      initialDirectory: Directory(widget.root).existsSync()
          ? widget.root
          : null,
    );
    if (dir != null) widget.onRootChanged(dir);
  }

  void _goUp() {
    final parent = Directory(widget.root).parent.path;
    if (parent != widget.root) widget.onRootChanged(parent);
  }

  void _select(String path) {
    _selected
      ..clear()
      ..add(path);
    _anchor = path;
  }

  Future<void> _onTap(ExplorerNode n) async {
    final kb = HardwareKeyboard.instance;
    final multi = kb.isControlPressed || kb.isMetaPressed;
    if (multi) {
      setState(() {
        if (!_selected.remove(n.path)) _selected.add(n.path);
        _anchor = n.path;
      });
      return;
    }
    if (kb.isShiftPressed && _anchor != null) {
      final rows = _tree.visible(filter: _filter.text);
      final a = rows.indexWhere((r) => r.path == _anchor);
      final b = rows.indexWhere((r) => r.path == n.path);
      if (a >= 0 && b >= 0) {
        setState(() {
          _selected.clear();
          for (var i = a < b ? a : b; i <= (a < b ? b : a); i++) {
            _selected.add(rows[i].path);
          }
        });
        return;
      }
    }
    setState(() => _select(n.path));
    if (n.isDir) {
      await _tree.toggle(n);
      _bump();
    } else {
      widget.onOpen(n.path);
    }
  }

  /// The paths an operation on [n] applies to: the selection when [n] is
  /// part of it, else just [n].
  List<String> _targetsFor(ExplorerNode n) =>
      _selected.contains(n.path) ? _selected.toList() : [n.path];

  // ── drag & drop move ──

  Future<void> _moveTo(
    List<String> paths,
    String destDir, {
    bool confirm = true,
  }) async {
    final l10n = _l10n;
    final plan = planMoves(paths, destDir);
    if (plan.isEmpty) return;
    final ok = !confirm
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.tr('explorer_move')),
              content: SizedBox(
                width: 420,
                child: Text(
                  l10n.trf('explorer_move_confirm', [
                    plan.length,
                    baseName(destDir),
                  ]),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n.tr('common_cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l10n.tr('explorer_move')),
                ),
              ],
            ),
          );
    if (ok != true || !mounted) return;
    var moved = 0;
    final newPaths = <String>[];
    for (final (src, dest) in plan) {
      try {
        if (await FileSystemEntity.type(dest) !=
            FileSystemEntityType.notFound) {
          _fail(l10n.trf('explorer_exists_named', [baseName(dest)]));
          continue;
        }
        if (!(await widget.onBeforeMutate?.call(src) ?? true)) break;
        await _retryFs(() => moveEntity(src, dest));
        widget.onAfterRename?.call(src, dest);
        moved++;
        newPaths.add(dest);
      } catch (e) {
        _fail(e);
      }
    }
    await _tree.reveal(destDir);
    await refresh();
    if (!mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(newPaths);
      _anchor = newPaths.lastOrNull;
      _dropTarget = null;
    });
    if (moved > 0) _toast(l10n.trf('explorer_moved', [moved]));
  }

  // ── keyboard + clipboard ──

  String get _pasteDir {
    final sel = _selected.toList();
    if (sel.length == 1) {
      final p = sel.single;
      return FileSystemEntity.isDirectorySync(p) ? p : parentPath(p);
    }
    return widget.root;
  }

  Future<void> _copyOrCut({required bool cut}) async {
    if (_selected.isEmpty) return;
    setState(() {
      _clip = _selected.toList();
      _clipCut = cut;
    });
    await Clipboard.setData(ClipboardData(text: _clip.join('\n')));
  }

  Future<void> _paste() async {
    if (_clip.isEmpty) return;
    final dest = _pasteDir;
    if (_clipCut) {
      final clip = _clip;
      setState(() {
        _clip = const [];
        _clipCut = false;
      });
      await _moveTo(clip, dest, confirm: false);
      return;
    }
    final l10n = _l10n;
    final plan = planCopies(
      _clip,
      dest,
      (p) => FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound,
    );
    if (plan.isEmpty) return;
    var copied = 0;
    final newPaths = <String>[];
    for (final (src, target) in plan) {
      try {
        await copyEntity(src, target);
        copied++;
        newPaths.add(target);
      } catch (e) {
        _fail(e);
      }
    }
    await _tree.reveal(dest);
    await refresh();
    if (!mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(newPaths);
      _anchor = newPaths.lastOrNull;
    });
    if (copied > 0) _toast(l10n.trf('explorer_copied', [copied]));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyC) {
      _copyOrCut(cut: false);
    } else if (ctrl && k == LogicalKeyboardKey.keyX) {
      _copyOrCut(cut: true);
    } else if (ctrl && k == LogicalKeyboardKey.keyV) {
      _paste();
    } else if (ctrl && k == LogicalKeyboardKey.keyA) {
      setState(() {
        _selected
          ..clear()
          ..addAll(_tree.visible(filter: _filter.text).map((n) => n.path));
      });
    } else if (k == LogicalKeyboardKey.delete && _selected.isNotEmpty) {
      _delete(_selected.toList());
    } else if (k == LogicalKeyboardKey.f2 && _selected.length == 1) {
      final p = _selected.single;
      _rename(
        ExplorerNode(
          p,
          baseName(p),
          FileSystemEntity.isDirectorySync(p),
          depth: 0,
        ),
      );
    } else if (k == LogicalKeyboardKey.escape && _clip.isNotEmpty) {
      setState(() {
        _clip = const [];
        _clipCut = false;
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── context menu + file operations ──

  Future<void> _showMenu(ExplorerNode? n, Offset pos) async {
    final l10n = _l10n;
    final targets = n == null ? const <String>[] : _targetsFor(n);
    final many = targets.length > 1;
    final dirPath = n == null
        ? widget.root
        : (n.isDir ? n.path : File(n.path).parent.path);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        if (n != null && (many || !n.isDir))
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'open',
            child: Text(l10n.tr('explorer_open')),
          ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'newFile',
          child: Text(l10n.tr('explorer_new_file')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'newFolder',
          child: Text(l10n.tr('explorer_new_folder')),
        ),
        if (n != null) ...[
          const PopupMenuDivider(),
          if (!many)
            PopupMenuItem(
              height: AppSettings.instance.menuRowHeight,
              value: 'rename',
              child: Text(l10n.tr('explorer_rename')),
            ),
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'delete',
            child: Text(
              many
                  ? l10n.trf('explorer_delete_n', [targets.length])
                  : l10n.tr('explorer_delete'),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'copy',
            child: Text(l10n.tr('explorer_copy')),
          ),
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'cut',
            child: Text(l10n.tr('explorer_cut')),
          ),
        ],
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'paste',
          enabled: _clip.isNotEmpty,
          child: Text(l10n.tr('explorer_paste')),
        ),
        if (n != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'copyPath',
            child: Text(l10n.tr('tab_copy_path')),
          ),
          PopupMenuItem(
            height: AppSettings.instance.menuRowHeight,
            value: 'reveal',
            child: Text(l10n.tr('tab_reveal')),
          ),
          if (n.isDir && !many)
            PopupMenuItem(
              height: AppSettings.instance.menuRowHeight,
              value: 'setRoot',
              child: Text(l10n.tr('explorer_set_root')),
            ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'refresh',
          child: Text(l10n.tr('explorer_refresh')),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        for (final p in targets) {
          if (!FileSystemEntity.isDirectorySync(p)) widget.onOpen(p);
        }
      case 'newFile':
        await _create(dirPath, isDir: false);
      case 'newFolder':
        await _create(dirPath, isDir: true);
      case 'rename':
        await _rename(n!);
      case 'delete':
        await _delete(targets);
      case 'copy':
        await _copyOrCut(cut: false);
      case 'cut':
        await _copyOrCut(cut: true);
      case 'paste':
        // Right-click on a row pastes into it (folder) / next to it (file);
        // on the background, into the root.
        if (n != null) setState(() => _select(n.path));
        if (n == null) setState(() => _selected.clear());
        await _paste();
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: targets.join('\n')));
      case 'reveal':
        widget.onRevealInOs(n!.path);
      case 'setRoot':
        widget.onRootChanged(n!.path);
      case 'refresh':
        await refresh();
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final l10n = _l10n;
    final ctl = TextEditingController(text: initial);
    // Preselect the stem so a rename replaces the name and keeps the ext.
    final dot = initial.lastIndexOf('.');
    ctl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : initial.length,
    );
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          void submit() {
            final v = ctl.text.trim();
            if (v.isEmpty || RegExp(r'[\\/:*?"<>|]').hasMatch(v)) {
              setDlg(() => error = l10n.tr('explorer_bad_name'));
              return;
            }
            Navigator.pop(ctx, v);
          }

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 360,
              child: TextField(
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.tr('explorer_name_hint'),
                  errorText: error,
                  isDense: true,
                ),
                onSubmitted: (_) => submit(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text(l10n.tr('common_cancel')),
              ),
              FilledButton(
                onPressed: submit,
                child: Text(l10n.tr('common_ok')),
              ),
            ],
          );
        },
      ),
    );
    disposeLater(ctl);
    return name;
  }

  void _fail(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(_l10n.trf('explorer_error', [e.toString()]))),
      );
  }

  Future<void> _create(String dir, {required bool isDir}) async {
    final name = await _askName(
      _l10n.tr(isDir ? 'explorer_new_folder' : 'explorer_new_file'),
    );
    if (name == null) return;
    final path = '$dir${Platform.pathSeparator}$name';
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
        _fail(_l10n.tr('explorer_exists'));
        return;
      }
      if (isDir) {
        await Directory(path).create();
      } else {
        await File(path).create();
      }
      await _tree.reveal(path);
      await refresh();
      setState(() => _select(path));
      if (!isDir) widget.onOpen(path);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _rename(ExplorerNode n) async {
    final name = await _askName(_l10n.tr('explorer_rename'), initial: n.name);
    if (name == null || name == n.name) return;
    final target =
        '${FileSystemEntity.parentOf(n.path)}'
        '${Platform.pathSeparator}$name';
    try {
      if (await FileSystemEntity.type(target) !=
          FileSystemEntityType.notFound) {
        _fail(_l10n.tr('explorer_exists'));
        return;
      }
      if (!(await widget.onBeforeMutate?.call(n.path) ?? true)) return;
      await _retryFs(
        () => n.isDir
            ? Directory(n.path).rename(target)
            : File(n.path).rename(target),
      );
      widget.onAfterRename?.call(n.path, target);
      await refresh();
      setState(() => _select(target));
    } catch (e) {
      _fail(e);
    }
  }

  // A pane closed just before still releases its file handle asynchronously
  // (Windows: sharing violation until then) — retry briefly before giving up.
  static Future<void> _retryFs(Future<Object?> Function() op) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await op();
        return;
      } on FileSystemException {
        if (attempt >= 30) rethrow; // ~1.5 s
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _delete(List<String> paths) async {
    final l10n = _l10n;
    if (paths.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('explorer_delete')),
        content: Text(
          paths.length == 1
              ? l10n.trf('explorer_delete_confirm', [baseName(paths.first)])
              : l10n.trf('explorer_delete_confirm_n', [paths.length]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('common_delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Nested selections: deleting the ancestor removes the rest.
    final tops = [
      for (final p in paths)
        if (!paths.any((o) => !samePath(o, p) && isInsidePath(p, o))) p,
    ];
    for (final p in tops) {
      try {
        if (!(await widget.onBeforeMutate?.call(p) ?? true)) break;
        final isDir = await FileSystemEntity.isDirectory(p);
        await _retryFs(
          () => isDir ? Directory(p).delete(recursive: true) : File(p).delete(),
        );
        _selected.remove(p);
      } catch (e) {
        _fail(e);
      }
    }
    await refresh();
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final bg = editorChromeBg;
    final fg = editorFg;
    final dim = editorGutterFg;
    final rows = _tree.visible(filter: _filter.text);
    final active = widget.activePath == null
        ? null
        : _canon(widget.activePath!);
    Widget btn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
    );
    return Material(
      color: bg,
      child: Column(
        children: [
          // ── header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 2, 0),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: widget.root,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      _tree.root.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                btn(
                  Icons.folder_open,
                  l10n.tr('explorer_choose_root'),
                  _chooseRoot,
                ),
                btn(Icons.arrow_upward, l10n.tr('explorer_up'), _goUp),
                btn(Icons.refresh, l10n.tr('explorer_refresh'), refresh),
                btn(Icons.unfold_less, l10n.tr('explorer_collapse'), () {
                  _tree.collapseAll();
                  _bump();
                }),
                btn(
                  Icons.my_location,
                  l10n.tr('explorer_locate'),
                  widget.activePath == null ? null : locateActive,
                ),
                btn(
                  Icons.close,
                  MaterialLocalizations.of(context).closeButtonTooltip,
                  widget.onClose,
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
                  hintText: l10n.tr('explorer_filter_hint'),
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
          // ── rows ──
          Expanded(
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _focus.requestFocus(),
                onSecondaryTapUp: (d) => _showMenu(null, d.globalPosition),
                child: _dropZone(
                  widget.root,
                  highlightWhenHover: false,
                  child: rows.isEmpty
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              _tree.root.loading
                                  ? l10n.tr('explorer_loading')
                                  : (_tree.root.error ??
                                        l10n.tr('explorer_empty')),
                              style: TextStyle(color: dim, fontSize: 12),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowH,
                          itemCount: rows.length,
                          itemBuilder: (_, i) => _row(rows[i], fg, dim, active),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _canon(String p) => Platform.isWindows ? p.toLowerCase() : p;

  Widget _row(ExplorerNode n, Color fg, Color dim, String? active) {
    final isActive = !n.isDir && active != null && _canon(n.path) == active;
    final isSel = _selected.contains(n.path);
    final isDrop = _dropTarget != null && samePath(_dropTarget!, n.path);
    final sel = editorSelColor;
    final dropDir = n.isDir ? n.path : parentPath(n.path);
    final isCut = _clipCut && _clip.any((c) => samePath(c, n.path));
    final row = GestureDetector(
      onSecondaryTapUp: (d) {
        _focus.requestFocus();
        if (!_selected.contains(n.path)) setState(() => _select(n.path));
        _showMenu(n, d.globalPosition);
      },
      child: Opacity(
        opacity: isCut ? 0.5 : 1,
        child: InkWell(
          onTap: () {
            _focus.requestFocus();
            _onTap(n);
          },
          child: Container(
            decoration: BoxDecoration(
              color: isSel
                  ? sel.withValues(alpha: 0.55)
                  : isActive
                  ? sel.withValues(alpha: 0.25)
                  : null,
              border: isDrop
                  ? Border.all(color: sel.withValues(alpha: 0.9), width: 1.5)
                  : null,
            ),
            padding: EdgeInsets.only(left: 6 + n.depth * 14.0, right: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: n.isDir
                      ? Icon(
                          n.expanded ? Icons.expand_more : Icons.chevron_right,
                          size: 16,
                          color: dim,
                        )
                      : null,
                ),
                Icon(
                  n.isDir
                      ? (n.expanded ? Icons.folder_open : Icons.folder)
                      : Icons.insert_drive_file_outlined,
                  size: 15,
                  color: n.isDir ? const Color(0xFFDCB67A) : dim,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    n.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: fg,
                      fontWeight: isActive
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (n.loading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Dragging a selected row carries the whole selection.
    final dragPaths = _selected.contains(n.path)
        ? _selected.toList()
        : [n.path];
    return Draggable<List<String>>(
      data: dragPaths,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(4),
        color: editorChromeBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            dragPaths.length == 1
                ? baseName(dragPaths.first)
                : _l10n.trf('explorer_items_n', [dragPaths.length]),
            style: TextStyle(color: fg, fontSize: 12.5),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: _dropZone(dropDir, highlightWhenHover: true, child: row),
    );
  }

  // A drop target that moves the dragged paths into [dir]; folders (and the
  // files' parent folder) highlight while hovered, the root area does not.
  Widget _dropZone(
    String dir, {
    required bool highlightWhenHover,
    required Widget child,
  }) => DragTarget<List<String>>(
    onWillAcceptWithDetails: (d) {
      final ok = planMoves(d.data, dir).isNotEmpty;
      if (ok && highlightWhenHover && _dropTarget != dir) {
        setState(() => _dropTarget = dir);
      }
      return ok;
    },
    onLeave: (_) {
      if (_dropTarget == dir) setState(() => _dropTarget = null);
    },
    onAcceptWithDetails: (d) {
      setState(() => _dropTarget = null);
      _moveTo(d.data, dir);
    },
    builder: (_, _, _) => child,
  );
}
