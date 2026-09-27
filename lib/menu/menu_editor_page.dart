// Menu editor dialog: rearrange the menubar structure (move up/down, cut &
// paste across menus, delete, insert separators) with a LIVE preview — the
// deleted items (separators excluded) collect in a trash area at the bottom
// and can be restored with the same cut & paste flow. The
// shell renders the same mutable draft tree this dialog edits, so every change
// shows in the menubar immediately. "Save" writes the tree to the external
// settings/menus/main_menu.json (which the loader already prefers); "Cancel"
// tells the shell to restore the original tree.
//
// Adding NEW items is out of scope (it would need action/labelKey knowledge);
// this is a re-arranger. "Restore Defaults" reloads the bundled asset default.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_localizations.dart';
import '../settings/resizable_dialog.dart';
import '../settings/settings_paths.dart';
import '../util/log.dart';
import 'json_menu_bar.dart';

/// Show the menu editor. [draft] is a mutable tree the caller is also
/// rendering (live preview); [onChanged] fires after every mutation so the
/// caller can setState. Returns true when the user saved.
Future<bool> showMenuEditorDialog(
  BuildContext context, {
  required List<MenuNode> draft,
  required List<MenuNode> trash,
  required VoidCallback onChanged,
}) async =>
    await showDialog<bool>(
      context: context,
      // Lighter barrier: the point is watching the menubar update live.
      barrierColor: Colors.black26,
      builder: (_) =>
          MenuEditorDialog(draft: draft, trash: trash, onChanged: onChanged),
    ) ??
    false;

/// Same editor, pointed at the toolbar config (`settings/toolbar.json`,
/// `items` root, separators allowed at the top level). [menuSource] is the
/// main-menu tree: its action items feed the "unused" area, so anything in
/// the menu can be added to the toolbar. No trash here — a deleted item just
/// reappears in the unused area, so toolbar.json never records `deleted`.
Future<bool> showToolbarEditorDialog(
  BuildContext context, {
  required List<MenuNode> draft,
  required VoidCallback onChanged,
  List<MenuNode>? menuSource,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierColor: Colors.black26,
      builder: (_) => MenuEditorDialog(
        draft: draft,
        trash: <MenuNode>[],
        onChanged: onChanged,
        titleKey: 'tb_title',
        saveRel: 'toolbar.json',
        defaultAsset: 'assets/toolbar.json',
        rootKey: 'items',
        allowRootSeparator: true,
        unusedSource: menuSource,
      ),
    ) ??
    false;

class MenuEditorDialog extends StatefulWidget {
  const MenuEditorDialog({
    super.key,
    required this.draft,
    required this.trash,
    required this.onChanged,
    this.titleKey = 'me_title',
    this.saveRel = 'menus/main_menu.json',
    this.defaultAsset = 'assets/menus/main_menu.json',
    this.rootKey = 'menus',
    this.allowRootSeparator = false,
    this.unusedSource,
  });

  final List<MenuNode> draft;

  /// Deleted items (persisted in the config's `deleted` array so they
  /// survive restarts); mutable draft like [draft].
  final List<MenuNode> trash;

  final VoidCallback onChanged;

  /// l10n key of the dialog title.
  final String titleKey;

  /// settings-relative path "Save" writes to.
  final String saveRel;

  /// Bundled asset "Restore Defaults" reloads.
  final String defaultAsset;

  /// Root JSON key of the node list ('menus' / 'items').
  final String rootKey;

  /// The toolbar is a flat list: separators live at depth 0 there.
  final bool allowRootSeparator;

  /// Non-null → show an "unused" area: this tree's action items (dynamic
  /// nodes excluded) that are not in [draft]/[trash]/clipboard yet. Derived,
  /// never persisted — used by the toolbar editor with the main-menu tree.
  final List<MenuNode>? unusedSource;

  @override
  State<MenuEditorDialog> createState() => _MenuEditorDialogState();
}

/// One visible row: the node plus where it lives (parent list + index), so
/// operations can mutate the tree in place.
class _Row {
  _Row(this.list, this.index, this.node, this.depth);
  final List<MenuNode> list;
  final int index;
  final MenuNode node;
  final int depth;
}

class _MenuEditorDialogState extends State<MenuEditorDialog> {
  MenuNode? _clipboard;

  // Deleted items (separators excluded — those just vanish) collect in
  // widget.trash, shown at the bottom of the list; cut one and paste it back
  // into the tree to restore it. Saved to main_menu.json's `deleted` array.
  // Toolbar mode has no trash: deleted items reappear in the unused area.
  List<MenuNode> get _trash => widget.trash;

  bool get _toolbarMode => widget.unusedSource != null;

  List<_Row> _rows() {
    final rows = <_Row>[];
    void walk(List<MenuNode> list, int depth) {
      for (var i = 0; i < list.length; i++) {
        final n = list[i];
        rows.add(_Row(list, i, n, depth));
        if (n.children != null) walk(n.children!, depth + 1);
      }
    }

    walk(widget.draft, 0);
    return rows;
  }

  void _mutate(void Function() f) {
    f();
    widget.onChanged(); // live preview: the shell re-renders the same tree
    setState(() {});
  }

  String _label(AppLocalizations l10n, MenuNode n) => n.isSeparator
      ? l10n.tr('me_separator')
      : l10n.tr(n.labelKey ?? n.action ?? '?');

  AppLocalizations get _l10n => AppLocalizations.of(context);

  Future<void> _restoreDefault() async {
    final raw = await rootBundle.loadString(widget.defaultAsset);
    final nodes = MenuNode.parseNodes(
      ((jsonDecode(raw) as Map).cast<String, Object?>())[widget.rootKey],
    );
    _mutate(() {
      _clipboard = null;
      _trash.clear(); // starting over — stale deleted items would confuse
      widget.draft
        ..clear()
        ..addAll(nodes);
    });
  }

  // Not awaited before pop: the write is a plain settings-file save (errors
  // only get logged), and fake-async widget tests can't await real I/O.
  void _save() {
    final f = File(settingsPath(widget.saveRel));
    () async {
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({
            widget.rootKey: [for (final m in widget.draft) m.toJson()],
            if (_trash.isNotEmpty)
              'deleted': [for (final m in _trash) m.toJson()],
          })}\n',
          encoding: utf8,
        );
        Log.instance.i('menu editor: saved ${f.path}');
      } catch (e) {
        Log.instance.w('menu editor: save failed: ${f.path} ($e)');
      }
    }();
    Navigator.of(context).pop(true);
  }

  Widget _btn(String tooltip, IconData icon, VoidCallback? onTap) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 16),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    onPressed: onTap,
  );

  Widget _row(AppLocalizations l10n, _Row r, int ordinal) {
    final clip = _clipboard;
    final isSub = r.node.children != null;
    // Row coloring for readability: without it, tracking from the label on
    // the left to its op buttons on the right is hard. Menu/submenu rows get
    // a type tint + colored label; plain items get zebra striping.
    final cs = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (r.node.isSeparator) {
      fg = cs.outline;
    } else if (r.depth == 0 && !_toolbarMode) {
      // Toolbar mode: top-level rows are plain action items, not menus —
      // they zebra-stripe like items instead of taking the menu tint.
      fg = cs.primary;
      bg = cs.primary.withValues(alpha: 0.10);
    } else if (isSub) {
      fg = cs.tertiary;
      bg = cs.tertiary.withValues(alpha: 0.08);
    }
    bg ??= ordinal.isOdd ? cs.onSurface.withValues(alpha: 0.05) : null;
    final row = Row(
      children: [
        SizedBox(width: 12.0 + r.depth * 20),
        Icon(
          r.node.isSeparator
              ? Icons.horizontal_rule
              // Dynamic placeholder (syntax/encoding): contents are runtime-built.
              : r.node.dynamicId != null
              ? Icons.extension_outlined
              : isSub
              ? Icons.folder_outlined
              : Icons.label_outline,
          size: 16,
          color: fg,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _label(l10n, r.node),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontWeight: isSub || r.depth == 0 ? FontWeight.bold : null,
            ),
          ),
        ),
        _btn(
          _l10n.tr('me_up'),
          Icons.arrow_upward,
          r.index > 0
              ? () => _mutate(() {
                  final t = r.list.removeAt(r.index);
                  r.list.insert(r.index - 1, t);
                })
              : null,
        ),
        _btn(
          _l10n.tr('me_down'),
          Icons.arrow_downward,
          r.index < r.list.length - 1
              ? () => _mutate(() {
                  final t = r.list.removeAt(r.index);
                  r.list.insert(r.index + 1, t);
                })
              : null,
        ),
        _btn(
          _l10n.tr('me_cut'),
          Icons.content_cut,
          clip == null
              ? () => _mutate(() => _clipboard = r.list.removeAt(r.index))
              : null,
        ),
        _btn(
          _l10n.tr('me_paste_after'),
          Icons.content_paste,
          clip != null
              ? () => _mutate(() {
                  r.list.insert(r.index + 1, clip);
                  _clipboard = null;
                })
              : null,
        ),
        _btn(
          _l10n.tr('me_paste_into'),
          Icons.subdirectory_arrow_right,
          clip != null && isSub
              ? () => _mutate(() {
                  r.node.children!.insert(0, clip);
                  _clipboard = null;
                })
              : null,
        ),
        _btn(
          _l10n.tr('me_add_sep'),
          Icons.horizontal_rule,
          r.depth > 0 || widget.allowRootSeparator
              ? () => _mutate(
                  () => r.list.insert(
                    r.index + 1,
                    const MenuNode(isSeparator: true),
                  ),
                )
              : null,
        ),
        _btn(
          _l10n.tr(_toolbarMode ? 'me_delete_toolbar' : 'me_delete'),
          Icons.delete_outline,
          () => _mutate(() {
            final n = r.list.removeAt(r.index);
            if (!_toolbarMode && !n.isSeparator) _trash.add(n);
          }),
        ),
      ],
    );
    return Container(color: bg, child: row);
  }

  // The derived "unused" list: action items of [unusedSource] not yet on the
  // toolbar (draft/trash/clipboard), deduped by action.
  List<MenuNode> _unused() {
    final src = widget.unusedSource;
    if (src == null) return const [];
    final used = <String>{};
    void collectUsed(List<MenuNode> ns) {
      for (final n in ns) {
        if (n.action != null) used.add(n.action!);
        if (n.children != null) collectUsed(n.children!);
      }
    }

    collectUsed(widget.draft);
    collectUsed(_trash);
    if (_clipboard?.action != null) used.add(_clipboard!.action!);
    final out = <MenuNode>[];
    final seen = <String>{};
    void walk(List<MenuNode> ns) {
      for (final n in ns) {
        if (n.children != null) {
          walk(n.children!);
        } else if (n.action != null &&
            n.dynamicId == null &&
            !used.contains(n.action) &&
            seen.add(n.action!)) {
          out.add(n);
        }
      }
    }

    walk(src);
    return out;
  }

  // A toolbar entry made from a menu item: label/action/icon only (the
  // shortcut column is a menu concept).
  MenuNode _asToolbarItem(MenuNode n) =>
      MenuNode(labelKey: n.labelKey, action: n.action, icon: n.icon);

  Widget _unusedRow(AppLocalizations l10n, MenuNode n, int ordinal) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: ordinal.isOdd ? cs.onSurface.withValues(alpha: 0.05) : null,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            MenuNode.menuIcons[n.icon] ?? Icons.label_outline,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_label(l10n, n), overflow: TextOverflow.ellipsis),
          ),
          _btn(
            l10n.tr('me_unused_add'),
            Icons.add,
            () => _mutate(() => widget.draft.add(_asToolbarItem(n))),
          ),
          _btn(
            l10n.tr('me_cut'),
            Icons.content_cut,
            _clipboard == null
                ? () => _mutate(() => _clipboard = _asToolbarItem(n))
                : null,
          ),
        ],
      ),
    );
  }

  // A row in the deleted area: cut it (then paste back into the tree) to
  // restore. No permanent-delete — the area is the safety net.
  Widget _trashRow(AppLocalizations l10n, int index) {
    final n = _trash[index];
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        const SizedBox(width: 12),
        Icon(
          n.children != null ? Icons.folder_outlined : Icons.label_outline,
          size: 16,
          color: cs.outline,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _label(l10n, n),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.outline),
          ),
        ),
        _btn(
          _l10n.tr('me_trash_cut'),
          Icons.content_cut,
          _clipboard == null
              ? () => _mutate(() => _clipboard = _trash.removeAt(index))
              : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final clip = _clipboard;
    return AlertDialog(
      title: Text(l10n.tr(widget.titleKey)),
      content: ResizableDialogBox(
        id: 'menuEditor',
        initialWidth: 620,
        initialHeight: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              clip != null
                  ? l10n.trf('me_cut_hint', [_label(l10n, clip)])
                  : l10n.tr('me_hint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final (i, r) in _rows().indexed) _row(l10n, r, i),
                  if (!_toolbarMode && _trash.isNotEmpty) ...[
                    const Divider(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 4),
                      child: Text(
                        l10n.tr('me_trash_header'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    for (var i = 0; i < _trash.length; i++) _trashRow(l10n, i),
                  ],
                  if (widget.unusedSource != null) ...[
                    for (final (i, n) in _unused().indexed) ...[
                      if (i == 0) ...[
                        const Divider(height: 16),
                        Padding(
                          padding: const EdgeInsets.only(left: 12, bottom: 4),
                          child: Text(
                            l10n.tr('me_unused_header'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                      _unusedRow(l10n, n, i),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _restoreDefault,
          child: Text(l10n.tr('me_restore_default')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.tr('common_cancel')),
        ),
        FilledButton(
          // A cut node still on the clipboard would be silently lost.
          onPressed: clip == null ? _save : null,
          child: Text(l10n.tr('common_save')),
        ),
      ],
    );
  }
}
