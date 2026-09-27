// File associations dialog (Settings → File Associations…).
//
// Windows, Linux and macOS: checkbox chips for common text extensions plus a
// free-form field for custom ones; apply writes per-user registry entries
// through file_assoc.dart (registry / freedesktop .desktop+MIME / LaunchServices).
// Opening the dialog queries the complete current
// set, so extensions added in an earlier session (including custom ones)
// show up checked.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../editor/highlight.dart' show HighlightConfig;
import '../editor/wasm_grammar.dart';
import '../l10n/app_localizations.dart';
import '../util/log.dart';
import '../util/mac_files.dart';
import 'app_settings.dart';
import 'resizable_dialog.dart';
import 'file_assoc.dart';
import 'file_assoc_linux.dart' show isFlatpakSandbox;
import 'file_assoc_mac.dart';

Future<void> showFileAssocDialog(BuildContext context) {
  // file_assoc.dart is flutter-free; route its logging into the global Log.
  assocLog = (m, {warn = false}) =>
      warn ? Log.instance.w(m) : Log.instance.i(m);
  // macOS goes through the native plugin (NSWorkspace); file_assoc_mac.dart
  // stays flutter-free, so hand it the channel calls here.
  if (Platform.isMacOS) {
    macAssocQueryHook = MacFiles.assocQuery;
    macAssocSetHook = MacFiles.assocSet;
  }
  return showDialog<void>(
    context: context,
    builder: (_) => const FileAssocDialog(),
  );
}

class FileAssocDialog extends StatefulWidget {
  const FileAssocDialog({super.key});

  @override
  State<FileAssocDialog> createState() => _FileAssocDialogState();
}

class _FileAssocDialogState extends State<FileAssocDialog> {
  bool _loading = true;
  bool _applying = false;
  String? _error;
  Set<String> _current = {}; // as registered right now
  final Set<String> _checked = {}; // dialog state
  final List<String> _extras = []; // checked-able exts beyond the common list
  bool _ctxCurrent = false; // "Edit in madedit2" verb, as registered
  bool _ctxChecked = false; // dialog state
  final TextEditingController _customCtl = TextEditingController();

  // Flatpak: the OS registration cannot reach the host (private home, no
  // xdg-mime) — only the syntax table below is offered.
  final bool _flatpak = Platform.isLinux && isFlatpakSandbox();

  // Extension → syntax table (AppSettings.syntaxByExt): independent of the
  // OS registration above — it only decides which highlighter a file gets.
  final Map<String, String> _syntax = {};
  final TextEditingController _syntaxExtCtl = TextEditingController();
  late final List<String> _syntaxChoices = [
    'plain',
    ...WasmGrammarRegistry.instance.languages,
  ];
  late String _syntaxPick = _syntaxChoices.length > 1
      ? _syntaxChoices[1]
      : _syntaxChoices.first;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _syntax.addAll(AppSettings.instance.syntaxByExt);
    _load();
  }

  @override
  void dispose() {
    _customCtl.dispose();
    _syntaxExtCtl.dispose();
    super.dispose();
  }

  void _addSyntax() {
    final parts = _syntaxExtCtl.text.split(RegExp(r'[,\s;]+'));
    var added = false;
    final builtin = _builtinExts(_syntaxPick);
    for (final p in parts) {
      final e = normalizeExt(p);
      if (e == null) continue;
      // Already built in for this very syntax: an override would be a no-op.
      if (builtin.contains(e)) {
        _syntax.remove(e);
      } else {
        _syntax[e] = _syntaxPick;
      }
      added = true;
    }
    if (added) {
      _syntaxExtCtl.clear();
      setState(() {});
    }
  }

  bool get _syntaxChanged {
    final live = AppSettings.instance.syntaxByExt;
    if (live.length != _syntax.length) return true;
    for (final e in _syntax.entries) {
      if (live[e.key] != e.value) return true;
    }
    return false;
  }

  String _syntaxLabel(String mode) =>
      mode == 'plain' ? _l10n.tr('syntax_plain') : mode;

  /// Extensions that open with [mode] out of the box (bundled grammar lists
  /// / plain-text list) — shown grey, not editable here.
  List<String> _builtinExts(String mode) => mode == 'plain'
      ? (HighlightConfig.instance.plainExtensions.toList()..sort())
      : WasmGrammarRegistry.instance.extensionsFor(mode);

  /// The user's own extensions currently mapped to [mode].
  List<String> _userExts(String mode) =>
      [for (final e in _syntax.entries) if (e.value == mode) e.key]..sort();

  // Pick a syntax → its extensions: built-in (grey, locked) + user-added
  // (removable) + a field to add more. Adding an extension that is built in
  // for another syntax simply overrides it (the table wins in
  // _pickHighlighter); adding one already mapped elsewhere moves it here.
  Widget _syntaxSection(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final builtin = _builtinExts(_syntaxPick);
    final user = _userExts(_syntaxPick);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.tr('assoc_syntax_title'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.tr('assoc_syntax_help'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(l10n.tr('assoc_syntax_pick')),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                value: _syntaxPick,
                isExpanded: true,
                isDense: true,
                items: [
                  for (final m in _syntaxChoices)
                    DropdownMenuItem(value: m, child: Text(_syntaxLabel(m))),
                ],
                onChanged: _applying
                    ? null
                    : (v) {
                        if (v != null) setState(() => _syntaxPick = v);
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (builtin.isEmpty && user.isEmpty)
          Text(
            l10n.tr('assoc_syntax_none'),
            style: theme.textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in builtin)
                if (!_syntax.containsKey(e)) // overridden ones show under their new syntax
                  Tooltip(
                    message: l10n.tr('assoc_syntax_builtin'),
                    child: Chip(
                      label: Text('.$e'),
                      avatar: const Icon(Icons.lock_outline, size: 14),
                      visualDensity: VisualDensity.compact,
                      labelStyle: TextStyle(color: theme.disabledColor),
                    ),
                  ),
              for (final e in user)
                InputChip(
                  label: Text('.$e'),
                  visualDensity: VisualDensity.compact,
                  onDeleted: _applying
                      ? null
                      : () => setState(() => _syntax.remove(e)),
                  deleteIcon: const Icon(Icons.remove_circle_outline, size: 16),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _syntaxExtCtl,
                enabled: !_applying,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.tr('assoc_syntax_ext_hint'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addSyntax(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: l10n.tr('assoc_add_tip'),
              onPressed: _applying ? null : _addSyntax,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _load() async {
    if (_flatpak) {
      setState(() => _loading = false);
      return;
    }
    final st = await queryFileAssociations();
    if (!mounted) return;
    setState(() {
      _current = st.exts;
      _checked
        ..clear()
        ..addAll(st.exts);
      _extras
        ..clear()
        ..addAll(
          st.exts.where((e) => !commonAssocExts.contains(e)).toList()..sort(),
        );
      _ctxCurrent = st.contextMenu;
      _ctxChecked = st.contextMenu;
      _loading = false;
    });
  }

  void _addCustom() {
    final parts = _customCtl.text.split(RegExp(r'[,\s;]+'));
    var added = false;
    for (final p in parts) {
      final e = normalizeExt(p);
      if (e == null) continue;
      if (!commonAssocExts.contains(e) && !_extras.contains(e)) {
        _extras
          ..add(e)
          ..sort();
      }
      _checked.add(e);
      added = true;
    }
    if (added) {
      _customCtl.clear();
      setState(() {});
    }
  }

  Future<void> _apply() async {
    final add = _checked.difference(_current);
    final remove = _current.difference(_checked);
    final bool? ctx = _ctxChecked == _ctxCurrent ? null : _ctxChecked;
    // The syntax table is plain settings: save it first (open panes re-pick
    // their highlighter on the notification), then do the OS part if any.
    if (_syntaxChanged) {
      await AppSettings.instance.setSyntaxByExt(Map.of(_syntax));
      if (!mounted) return;
    }
    if (_flatpak || (add.isEmpty && remove.isEmpty && ctx == null)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _applying = true;
      _error = null;
    });
    List<int>? icon;
    if (Platform.isLinux) {
      try {
        icon = (await rootBundle.load(
          'assets/icons/madedit2.png',
        )).buffer.asUint8List();
      } catch (_) {}
    }
    final err = await applyFileAssociations(
      add: add,
      remove: remove,
      contextMenu: Platform.isWindows ? ctx : null,
      iconPng: icon,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _applying = false;
        _error = err;
      });
    }
  }

  Widget _chips(Iterable<String> exts) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final e in exts)
        FilterChip(
          label: Text('.$e'),
          selected: _checked.contains(e),
          onSelected: _applying
              ? null
              : (v) => setState(() => v ? _checked.add(e) : _checked.remove(e)),
          visualDensity: VisualDensity.compact,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final supported =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final hintKey = Platform.isLinux
        ? 'assoc_hint_linux'
        : Platform.isMacOS
        ? 'assoc_hint_mac'
        : 'assoc_hint';
    final Widget body;
    if (!supported) {
      body = Text(l10n.tr('assoc_win_only'));
    } else if (_loading) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    } else if (_flatpak) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.tr('assoc_flatpak_hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          const Divider(height: 8),
          const SizedBox(height: 4),
          _syntaxSection(l10n),
        ],
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.tr(hintKey), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          _chips(commonAssocExts),
          if (_extras.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 8),
            const SizedBox(height: 4),
            _chips(_extras),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customCtl,
                  enabled: !_applying,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.tr('assoc_custom_hint'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addCustom(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l10n.tr('assoc_add_tip'),
                onPressed: _applying ? null : _addCustom,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 8),
            const Divider(height: 8),
            CheckboxListTile(
              value: _ctxChecked,
              onChanged: _applying
                  ? null
                  : (v) => setState(() => _ctxChecked = v ?? false),
              title: Text(l10n.trf('assoc_context_menu', [assocShellLabel])),
              subtitle: Text(l10n.tr('assoc_context_menu_help')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
          const SizedBox(height: 12),
          const Divider(height: 8),
          const SizedBox(height: 4),
          _syntaxSection(l10n),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.trf('assoc_apply_failed', [_error!]),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      );
    }
    return AlertDialog(
      title: Text(l10n.tr('assoc_title')),
      content: ResizableDialogBox(
        id: 'fileAssoc',
        initialWidth: 560,
        child: SingleChildScrollView(child: body),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_cancel')),
        ),
        if (supported)
          FilledButton(
            onPressed: _loading || _applying ? null : _apply,
            child: _applying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.tr('common_apply_save')),
          ),
      ],
    );
  }
}
