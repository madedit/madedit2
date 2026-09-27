import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// One menu node defined by JSON (a top-level menu, a submenu, or an item).
///
/// Three kinds:
///   - **Separator**: `{ "type": "separator" }` → [isSeparator] = true.
///   - **Submenu**: has a `submenu` array → [children] is non-null (nestable).
///   - **Item**: has a `labelKey` (+ optional `shortcut` / `action` / `enabled`).
///
/// Text always comes from [labelKey] looked up dynamically via
/// [AppLocalizations.tr] (switches live with the locale); [action] is a
/// string handed to the owner's action map on click (decoupled from
/// translation and structure).
class MenuNode {
  const MenuNode({
    this.labelKey,
    this.action,
    this.shortcut,
    this.icon,
    this.dynamicId,
    this.enabled = true,
    this.isSeparator = false,
    this.children,
  });

  final String? labelKey;
  final String? action;
  final String? shortcut; // display-only shortcut label (e.g. "Ctrl+O"), not bound to the keyboard
  final String? icon; // optional: a key of menuIcons; unknown or missing = no icon

  /// Dynamic placeholder submenu (`"dynamic": "syntax"` / `"encoding"`): the
  /// position/title come from JSON, the expanded contents are generated at
  /// runtime by [JsonMenuBar.dynamicChildren] (the syntax/encoding item lists
  /// come from a registry and cannot be hard-coded in JSON).
  final String? dynamicId;

  final bool enabled;
  final bool isSeparator;
  final List<MenuNode>? children; // non-null = submenu

  factory MenuNode.fromJson(Map<String, dynamic> json) {
    if (json['type'] == 'separator') {
      return const MenuNode(isSeparator: true);
    }
    final sub = json['submenu'];
    return MenuNode(
      labelKey: json['labelKey'] as String?,
      action: json['action'] as String?,
      shortcut: json['shortcut'] as String?,
      icon: json['icon'] as String?,
      dynamicId: json['dynamic'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      children: sub is List
          ? sub
                .whereType<Map>()
                .map((e) => MenuNode.fromJson(e.cast<String, dynamic>()))
                .toList()
          : null,
    );
  }

  /// Serialize back to the main_menu.json shape (defaults omitted) — the menu
  /// editor writes the edited tree to settings/menus/main_menu.json with this.
  Map<String, Object?> toJson() => isSeparator
      ? {'type': 'separator'}
      : {
          if (labelKey != null) 'labelKey': labelKey,
          if (shortcut != null) 'shortcut': shortcut,
          if (action != null) 'action': action,
          if (icon != null) 'icon': icon,
          if (dynamicId != null) 'dynamic': dynamicId,
          if (!enabled) 'enabled': false,
          if (children != null)
            'submenu': [for (final c in children!) c.toJson()],
        };

  /// Deep copy (the menu editor edits a mutable draft of the live tree).
  MenuNode deepCopy() => MenuNode.fromJson(toJson().cast<String, dynamic>());

  /// JSON `icon` name → Material icon. Dart has no runtime reflection to get
  /// `Icons.xxx` by name, so this is a sufficient whitelist table; names not
  /// in the table are silently ignored (a typo in an external settings/ menu
  /// file must not break the menu).
  static const Map<String, IconData> menuIcons = {
    'note_add': Icons.note_add,
    'folder_open': Icons.folder_open,
    'save': Icons.save,
    'save_as': Icons.save_as,
    'refresh': Icons.refresh,
    'format_list_numbered': Icons.format_list_numbered,
    'exit_to_app': Icons.exit_to_app,
    'undo': Icons.undo,
    'redo': Icons.redo,
    'content_copy': Icons.content_copy,
    'content_cut': Icons.content_cut,
    'content_paste': Icons.content_paste,
    'search': Icons.search,
    'find_replace': Icons.find_replace,
    'arrow_back': Icons.arrow_back,
    'arrow_forward': Icons.arrow_forward,
    'vertical_split': Icons.vertical_split,
    'tag': Icons.tag,
    'translate': Icons.translate,
    'keyboard': Icons.keyboard,
    'wrap_text': Icons.wrap_text,
    'visibility': Icons.visibility,
    'settings': Icons.settings,
    'palette': Icons.palette,
    'text_fields': Icons.text_fields,
    'format_size': Icons.format_size,
    'favorite': Icons.favorite,
    'info_outline': Icons.info_outline,
    'help_outline': Icons.help_outline,
    'description': Icons.description,
    'code': Icons.code,
    'edit': Icons.edit,
    'close': Icons.close,
    'fiber_manual_record': Icons.fiber_manual_record,
    'difference': Icons.difference_outlined,
    'call_merge': Icons.call_merge,
    'segment': Icons.segment,
    'print': Icons.print,
    'play_arrow': Icons.play_arrow,
    'terminal': Icons.terminal,
    'history': Icons.history,
    'view_column': Icons.view_column,
    'restore_page': Icons.restore_page,
    'open_in_new': Icons.open_in_new,
    'keyboard_return': Icons.keyboard_return,
    'bookmark_add': Icons.bookmark_add_outlined,
    'calculate': Icons.calculate_outlined,
    'zoom_in': Icons.zoom_in,
    'zoom_out': Icons.zoom_out,
  };

  /// Parse a JSON array of nodes (menus / toolbar items / deleted entries).
  static List<MenuNode> parseNodes(Object? v) {
    if (v is! List) return [];
    return v
        .whereType<Map>()
        .map((e) => MenuNode.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// The config's `deleted` array: items removed in the menu/toolbar editor,
  /// kept in the file so they survive restarts and can be restored later.
  /// Never rendered.
  static List<MenuNode> parseDeleted(Map<String, dynamic> json) =>
      parseNodes(json['deleted']);

  /// Parses a whole menu config (`{ "menus": [ ... ] }`) into the list of top-level menus.
  static List<MenuNode> parseConfig(Map<String, dynamic> json) =>
      parseNodes(json['menus']);
}

/// Native menubar (`MenuBar` + `SubmenuButton` + `MenuItemButton`): the
/// structure is described by [menus] (parsed from JSON), the text is
/// localized dynamically from ARB, and behaviour is dispatched via [onAction].
///
/// Hover auto-expand, keyboard navigation and accessibility semantics are all
/// built into Flutter's native MenuBar.
class JsonMenuBar extends StatelessWidget {
  const JsonMenuBar({
    super.key,
    required this.menus,
    required this.onAction,
    this.topLevelColor,
    this.isChecked,
    this.dynamicChildren,
    this.shortcutOverride,
    this.firstMenuController,
    this.firstMenuFocusNode,
  });

  /// Handles for opening the menu bar from the keyboard (F10 / Alt tap /
  /// ⌃F2, see menu_bar_keys.dart): attached to the FIRST top-level menu.
  /// The owner requests focus on [firstMenuFocusNode] and then opens
  /// [firstMenuController]; with the button focused, MenuBar's own arrow-key
  /// traversal takes over (↓ into the items, ←→ across menus, Esc closes and
  /// hands focus back to where it was).
  final MenuController? firstMenuController;
  final FocusNode? firstMenuFocusNode;

  /// Shortcut label to show for an action instead of the JSON's static
  /// `shortcut`: the live keymap (preset + user overrides). null = keep the
  /// static label; '' = show none.
  final String? Function(String action)? shortcutOverride;

  final List<MenuNode> menus;

  /// Called when a menu item is clicked, with the item's `action` string (the
  /// owner looks it up and executes it).
  final void Function(String action) onAction;

  /// Text colour of the top-level menu titles. null = inherit the text colour
  /// of the surrounding widget (the AppBar's foregroundColor), so the light
  /// theme does not end up with white text on white.
  final Color? topLevelColor;

  /// Whether this action is a "checkable" item and whether it is currently
  /// checked (e.g. the three-way "Mode" choice). Returns null = not checkable
  /// (no space reserved for a check mark); true/false = checkable and its state.
  final bool? Function(String action)? isChecked;

  /// Contents of a dynamic placeholder submenu ([MenuNode.dynamicId]) when
  /// expanded (the syntax/encoding lists are generated from a registry). Not
  /// provided or unknown id → empty submenu.
  final List<Widget> Function(String id)? dynamicChildren;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labelColor =
        topLevelColor ??
        AppBarTheme.of(context).foregroundColor ??
        DefaultTextStyle.of(context).style.color;
    return MenuBar(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      children: [
        for (final (i, menu) in menus.indexed)
          if (menu.dynamicId != null)
            SubmenuButton(
              controller: i == 0 ? firstMenuController : null,
              focusNode: i == 0 ? firstMenuFocusNode : null,
              menuChildren: dynamicChildren?.call(menu.dynamicId!) ?? const [],
              child: _topLabel(l10n, menu, labelColor),
            )
          else if (menu.children != null)
            SubmenuButton(
              controller: i == 0 ? firstMenuController : null,
              focusNode: i == 0 ? firstMenuFocusNode : null,
              menuChildren: _buildItems(context, l10n, menu.children!),
              child: _topLabel(l10n, menu, labelColor),
            ),
      ],
    );
  }

  String _label(AppLocalizations l10n, MenuNode node) =>
      node.labelKey == null ? '' : l10n.tr(node.labelKey!);

  /// Whether Alt+letter menu mnemonics apply: Windows and Linux only. macOS
  /// has no such convention (Flutter's MenuAcceleratorLabel is inert there
  /// too), and the "(F)" suffix would just be noise.
  static bool get platformHasMnemonics => switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux => true,
    _ => false,
  };

  /// Top-level menu title. On Windows/Linux it is a [MenuAcceleratorLabel]
  /// whose mnemonic letter comes from the `mnemonic_<labelKey>` l10n string
  /// (see [acceleratedLabel]): holding Alt underlines it, Alt+letter opens
  /// the menu. Elsewhere, and without a mnemonic string, a plain [Text].
  Widget _topLabel(AppLocalizations l10n, MenuNode menu, Color? color) {
    final label = _label(l10n, menu);
    final key = menu.labelKey;
    final mn = key == null ? null : l10n.tr('mnemonic_$key');
    final hasMn = mn != null && mn.length == 1; // tr() echoes the key when missing
    if (!platformHasMnemonics || !hasMn) {
      return Text(label, style: TextStyle(color: color));
    }
    return DefaultTextStyle.merge(
      style: TextStyle(color: color),
      child: MenuAcceleratorLabel(acceleratedLabel(label, mn)),
    );
  }

  /// [label] with an `&` accelerator marker for [mnemonic] the way
  /// [MenuAcceleratorLabel] expects: before the letter's first occurrence
  /// (case-insensitive; "&File"), or, when the label has no such letter, as a
  /// trailing "(&F)" — the Windows convention for CJK UIs ("File(F)" with a
  /// CJK label). A
  /// literal `&` in [label] is escaped as `&&`.
  static String acceleratedLabel(String label, String mnemonic) {
    final escaped = label.replaceAll('&', '&&');
    if (mnemonic.isEmpty) return escaped;
    final at = escaped.toLowerCase().indexOf(mnemonic.toLowerCase());
    if (at < 0) return '$escaped(&${mnemonic.toUpperCase()})';
    // An `&` produced by escaping never matches a letter, so `at` never
    // points inside an `&&` pair.
    return '${escaped.substring(0, at)}&${escaped.substring(at)}';
  }

  /// The item's leading icon per its JSON `icon` name — or an equally wide
  /// placeholder when absent or unknown, so every item's text lines up (an
  /// outdated external menu file must not break the menu either).
  Widget _iconOf(MenuNode node) {
    final data = node.icon == null ? null : MenuNode.menuIcons[node.icon];
    return data == null ? const SizedBox(width: 18) : Icon(data, size: 18);
  }

  List<Widget> _buildItems(
    BuildContext context,
    AppLocalizations l10n,
    List<MenuNode> items,
  ) {
    final widgets = <Widget>[];
    for (final item in items) {
      if (item.isSeparator) {
        widgets.add(const Divider(height: 1));
      } else if (item.dynamicId != null) {
        // Dynamic placeholder submenu (may sit under any other menu)
        widgets.add(
          SubmenuButton(
            leadingIcon: _iconOf(item),
            menuChildren: dynamicChildren?.call(item.dynamicId!) ?? const [],
            child: Text(_label(l10n, item)),
          ),
        );
      } else if (item.children != null) {
        // Nested submenu
        widgets.add(
          SubmenuButton(
            leadingIcon: _iconOf(item),
            menuChildren: _buildItems(context, l10n, item.children!),
            child: Text(_label(l10n, item)),
          ),
        );
      } else {
        final action = item.action;
        final enabled = item.enabled && action != null;
        final checked = action == null ? null : isChecked?.call(action);
        final live = action == null ? null : shortcutOverride?.call(action);
        final shortcut = live ?? item.shortcut;
        widgets.add(
          MenuItemButton(
            // Checkable items: the check mark wins (that slot is reserved for
            // it); other items use the icon named in JSON.
            leadingIcon: checked == null
                ? _iconOf(item)
                : checked
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: enabled ? () => onAction(action) : null,
            trailingIcon: shortcut == null || shortcut.isEmpty
                ? null
                : Text(
                    shortcut,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
            child: Text(_label(l10n, item)),
          ),
        );
      }
    }
    return widgets;
  }
}
