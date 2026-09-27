// Keymap editor (Settings → Shortcut Editor…).
//
// Lists every keyable command — menu actions with their localized path,
// registered commands without a menu item, and the dynamic-menu items
// (scripts / syntax / encodings / saved macros) as argful commands — with
// its effective bindings on the active preset. Changes go straight into the
// user overlay (settings/keymaps/user.json, see user_keymap.dart): a new
// binding is appended, removing a preset binding records a `-command`
// entry, "reset" drops the overlay's entries for that command. Every pane
// and the menu labels follow through the UserKeymap listeners.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/keybinding/chord_from_event.dart';
import '../editor/keybinding/key_chord.dart';
import '../editor/keybinding/keymap.dart';
import '../editor/keybinding/user_keymap.dart';
import '../l10n/app_localizations.dart';
import '../util/mac_files.dart';
import 'resizable_dialog.dart';

/// One row of the editor: what the user sees, and the command (+args) it maps to.
class KeymapEntry {
  const KeymapEntry(this.label, this.command, {this.args});
  final String label;
  final String command;
  final Map<String, Object?>? args;
}

Future<void> showKeymapEditorDialog(
  BuildContext context, {
  required String presetName,
  required List<KeyBinding> presetBindings,
  required String? defaultMode,
  required List<KeymapEntry> entries,
}) => showDialog<void>(
  context: context,
  builder: (_) => _KeymapEditorDialog(
    presetName: presetName,
    presetBindings: presetBindings,
    defaultMode: defaultMode,
    entries: entries,
  ),
);

class _KeymapEditorDialog extends StatefulWidget {
  const _KeymapEditorDialog({
    required this.presetName,
    required this.presetBindings,
    required this.defaultMode,
    required this.entries,
  });
  final String presetName;
  final List<KeyBinding> presetBindings;
  final String? defaultMode;
  final List<KeymapEntry> entries;

  @override
  State<_KeymapEditorDialog> createState() => _KeymapEditorDialogState();
}

class _KeymapEditorDialogState extends State<_KeymapEditorDialog> {
  final TextEditingController _filter = TextEditingController();

  /// The user's overrides as they were when this dialog opened. Every edit here
  /// writes straight through to user.json (each pane rebuilds its resolver on
  /// the spot), so "cancel" means putting this back rather than dropping a
  /// draft.
  late final List<KeyBinding> _onOpen = List.of(UserKeymap.instance.bindings);
  late List<KeyBinding> _effective;

  UserKeymap get _user => UserKeymap.instance;
  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _recompute();
    _user.addListener(_onUser);
  }

  @override
  void dispose() {
    _user.removeListener(_onUser);
    _filter.dispose();
    super.dispose();
  }

  void _onUser() {
    if (mounted) setState(_recompute);
  }

  // Presets carry platform-conditional pairs (alt+→ is "go forward" on
  // Windows/Linux but "word right" on macOS); only the ones live on this
  // platform are listed, or every such key would look double-bound. The
  // `when` context here has nothing but the platform, so only expressions
  // that mention it are evaluated — anything else stays listed.
  void _recompute() => _effective = activeOnPlatform(
    mergeBindings(widget.presetBindings, _user.bindings),
    Platform.operatingSystem,
  );

  bool _hasUserEntries(KeymapEntry e) => _user.bindings.any(
    (b) => b.targetCommand == e.command && b.argsEqual(e.args),
  );

  Future<void> _record(KeymapEntry e) async {
    final res = await showDialog<(List<KeyChord>, String?)>(
      context: context,
      builder: (_) => _RecordDialog(
        defaultMode: widget.defaultMode,
        effective: _effective,
        forCommand: e.command,
        forArgs: e.args,
      ),
    );
    if (res == null) return;
    final (chords, mode) = res;
    await _user.add(
      KeyBinding(chords: chords, command: e.command, args: e.args, mode: mode),
    );
  }

  Future<void> _removeBinding(KeyBinding b) =>
      _user.owns(b) ? _user.remove(b) : _user.addRemoval(b);

  Future<void> _import() async {
    final picked = await MacFiles.openFile(extensions: ['json']);
    if (picked == null) return;
    try {
      final j = (jsonDecode(await File(picked.path).readAsString()) as Map)
          .cast<String, Object?>();
      await _user.replaceAll(
        Keymap.fromJson(j, isMac: Platform.isMacOS).bindings,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.trf('km_import_failed', [e.toString()]))),
      );
    }
  }

  Future<void> _resetAll() async {
    final l10n = _l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.tr('km_reset_all_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('common_ok')),
          ),
        ],
      ),
    );
    if (ok == true) await _user.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final q = _filter.text.trim().toLowerCase();
    final rows = q.isEmpty
        ? widget.entries
        : [
            for (final e in widget.entries)
              if (e.label.toLowerCase().contains(q) ||
                  e.command.toLowerCase().contains(q) ||
                  bindingsFor(
                    _effective,
                    e.command,
                    e.args,
                  ).any((b) => chordsLabel(b.chords).toLowerCase().contains(q)))
                e,
          ];
    return AlertDialog(
      title: Text('${l10n.tr('km_title')}  (${widget.presetName})'),
      content: ResizableDialogBox(
        id: 'keymap',
        initialWidth: 760,
        initialHeight: 520,
        child: Column(
          children: [
            TextField(
              controller: _filter,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: l10n.tr('km_filter_hint'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (Platform.isMacOS) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  // The filter matches against chordsLabel, which renders the
                  // mac glyphs — so inserting one is how you list every ⌘
                  // binding. They are hard to type on most keyboards.
                  for (final glyph in const ['⌃', '⌥', '⇧', '⌘'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(
                          glyph,
                          style: const TextStyle(fontSize: 15),
                        ),
                        selected: _filter.text.contains(glyph),
                        onSelected: (on) => setState(() {
                          _filter.text = on
                              ? '${_filter.text}$glyph'
                              : _filter.text.replaceAll(glyph, '');
                          _filter.selection = TextSelection.collapsed(
                            offset: _filter.text.length,
                          );
                        }),
                      ),
                    ),
                  if (_filter.text.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(_filter.clear),
                      child: Text(_l10n.tr('km_filter_clear')),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (_, i) => _row(rows[i], theme),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.trf('km_file_hint', [_user.path]),
                style: TextStyle(fontSize: 11, color: theme.disabledColor),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _import, child: Text(l10n.tr('km_import'))),
        TextButton(
          onPressed: _user.bindings.isEmpty ? null : _resetAll,
          child: Text(l10n.tr('km_reset_all')),
        ),
        TextButton(
          onPressed: () async {
            await _user.replaceAll(_onOpen);
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(l10n.tr('common_cancel')),
        ),
        // "Done" rather than "Close": with Cancel beside it, closing has to
        // read as "keep what I changed".
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.tr('common_done')),
        ),
      ],
    );
  }

  Widget _row(KeymapEntry e, ThemeData theme) {
    final l10n = _l10n;
    final bound = bindingsFor(_effective, e.command, e.args);
    final argText = e.args == null || e.args!.isEmpty
        ? ''
        : ' ${e.args!.values.join(' ')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.label, overflow: TextOverflow.ellipsis),
                Text(
                  '${e.command}$argText',
                  style: TextStyle(fontSize: 11, color: theme.disabledColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                if (bound.isEmpty)
                  Text(
                    l10n.tr('km_none'),
                    style: TextStyle(color: theme.disabledColor, fontSize: 12),
                  ),
                for (final b in bound)
                  Tooltip(
                    message: _user.owns(b)
                        ? l10n.tr('km_user_tip')
                        : l10n.tr('km_preset_tip'),
                    child: InputChip(
                      label: Text(
                        b.mode == null
                            ? chordsLabel(b.chords)
                            : '${chordsLabel(b.chords)} [${b.mode}]',
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _user.owns(b)
                          ? theme.colorScheme.primaryContainer
                          : null,
                      onDeleted: () => _removeBinding(b),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.tr('km_add'),
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => _record(e),
          ),
          IconButton(
            tooltip: l10n.tr('km_reset'),
            icon: const Icon(Icons.restart_alt, size: 18),
            onPressed: _hasUserEntries(e)
                ? () => _user.resetCommand(e.command, e.args)
                : null,
          ),
        ],
      ),
    );
  }
}

/// "Press a shortcut": records chords from key events (multi-chord
/// sequences allowed), shows conflicts, lets a modal preset pick the mode.
class _RecordDialog extends StatefulWidget {
  const _RecordDialog({
    required this.defaultMode,
    required this.effective,
    required this.forCommand,
    required this.forArgs,
  });
  final String? defaultMode;
  final List<KeyBinding> effective;
  final String forCommand;
  final Map<String, Object?>? forArgs;

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  final List<KeyChord> _chords = [];
  String? _mode;
  final FocusNode _focus = FocusNode();

  /// Modifiers picked with the buttons below, folded into the next key press
  /// and then cleared — a one-shot, like macOS Sticky Keys. Lets someone bind
  /// ⌘-something on a keyboard that cannot produce ⌘ (a PC keyboard whose
  /// Command key the OS reports as Control, a remapper that swallows the
  /// modifier events, …), which is otherwise impossible from this dialog.
  final Set<String> _sticky = {};

  static const _macMods = [
    ('ctrl', '⌃'),
    ('alt', '⌥'),
    ('shift', '⇧'),
    ('meta', '⌘'),
  ];

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final c = chordFromKeyEvent(e);
    if (c == null) return KeyEventResult.handled; // bare modifier
    setState(() {
      _chords.add(
        _sticky.isEmpty ? c : KeyChord({...c.mods, ..._sticky}, c.key),
      );
      _sticky.clear();
    });
    return KeyEventResult.handled;
  }

  /// What the capture box shows: the chords so far, plus the modifiers that
  /// are armed and waiting for a key (so the buttons visibly do something).
  String _recordText(AppLocalizations l10n) {
    final pending = [
      for (final (id, glyph) in _macMods)
        if (_sticky.contains(id)) glyph,
    ].join();
    if (_chords.isEmpty && pending.isEmpty) return l10n.tr('km_record_hint');
    final done = _chords.isEmpty ? '' : chordsLabel(_chords);
    if (pending.isEmpty) return done;
    return done.isEmpty ? '$pending…' : '$done $pending…';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final key = _chords.map((c) => c.canonical).join(' ');
    final conflicts = _chords.isEmpty
        ? const <KeyBinding>[]
        : [
            for (final b in conflictsFor(widget.effective, key, _mode))
              if (!(b.command == widget.forCommand &&
                  b.argsEqual(widget.forArgs)))
                b,
          ];
    return AlertDialog(
      title: Text(l10n.tr('km_record_title')),
      content: ResizableDialogBox(
        id: 'keymapRecord',
        initialWidth: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: GestureDetector(
                  onTap: _focus.requestFocus,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.primary),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _recordText(l10n),
                      style: TextStyle(
                        fontSize: 16,
                        color: _chords.isEmpty && _sticky.isEmpty
                            ? theme.disabledColor
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              if (Platform.isMacOS) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final (id, glyph) in _macMods)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(
                            glyph,
                            style: const TextStyle(fontSize: 15),
                          ),
                          selected: _sticky.contains(id),
                          onSelected: (on) {
                            setState(() {
                              if (on) {
                                _sticky.add(id);
                              } else {
                                _sticky.remove(id);
                              }
                            });
                            // The chip stole the focus; the next key press has to
                            // land back in the capture box.
                            _focus.requestFocus();
                          },
                        ),
                      ),
                    Expanded(
                      child: Text(
                        l10n.tr('km_sticky_hint'),
                        style: TextStyle(fontSize: 11, color: theme.hintColor),
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.defaultMode != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(l10n.tr('km_mode')),
                    const SizedBox(width: 8),
                    DropdownButton<String?>(
                      value: _mode,
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.tr('km_mode_all')),
                        ),
                        for (final m in const ['normal', 'insert', 'visual'])
                          DropdownMenuItem(value: m, child: Text(m)),
                      ],
                      onChanged: (v) => setState(() => _mode = v),
                    ),
                  ],
                ),
              ],
              if (conflicts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.trf('km_conflict', [
                    conflicts
                        .map(
                          (b) => b.mode == null
                              ? b.command
                              : '${b.command} [${b.mode}]',
                        )
                        .join(', '),
                  ]),
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _chords.isEmpty ? null : () => setState(_chords.clear),
          child: Text(l10n.tr('km_record_clear')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.tr('common_cancel')),
        ),
        FilledButton(
          onPressed: _chords.isEmpty
              ? null
              : () => Navigator.pop(context, (List.of(_chords), _mode)),
          child: Text(l10n.tr('common_ok')),
        ),
      ],
    );
  }
}
