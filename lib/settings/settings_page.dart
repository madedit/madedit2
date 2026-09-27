// Settings page: edits the values that used to be hard-coded constants and writes them to
// `<exe>/settings/settings.json`.
//
// Works on a draft copy of [AppSettings] and only commits on "apply", which makes the change live
// (listeners re-render) and saves the file. The same file can also be hand-edited; it is re-read at
// startup.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import 'app_settings.dart';
import 'resizable_dialog.dart';

/// Show the settings page as a modal dialog. Returns true if the user applied changes.
Future<bool> showSettingsDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const SettingsDialog(),
    ) ??
    false;

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  // The draft being edited; only copied into AppSettings.instance on apply.
  late AppSettings _draft = AppSettings.from(AppSettings.instance);
  final _form = GlobalKey<FormState>();

  // Rebuilt on "reset to defaults" so every field shows the new value.
  Key _fieldsKey = UniqueKey();

  bool _restartHint = false; // logToFile only takes effect on restart

  AppLocalizations get _l10n => AppLocalizations.of(context);

  Future<void> _apply() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    _form.currentState!.save();
    await AppSettings.instance.adopt(_draft);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _resetToDefaults() {
    setState(() {
      _draft = AppSettings(); // built-in defaults
      _fieldsKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_l10n.tr('set_title')),
      content: ResizableDialogBox(
        id: 'settings',
        initialWidth: 560,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              key: _fieldsKey,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _l10n.trf('set_stored_at', [AppSettings.filePath]),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),

                _section(_l10n.tr('set_sec_perf')),
                _intField(
                  label: _l10n.tr('set_hl_max'),
                  help: _l10n.tr('set_hl_max_help'),
                  value: _draft.wholeFileHlMaxMB,
                  min: 0,
                  max: 512,
                  onSaved: (v) => _draft.wholeFileHlMaxMB = v,
                ),
                _intField(
                  label: _l10n.tr('set_hl_debounce'),
                  help: _l10n.tr('set_hl_debounce_help'),
                  value: _draft.wholeFileHlDebounceMs,
                  min: 0,
                  max: 10000,
                  onSaved: (v) => _draft.wholeFileHlDebounceMs = v,
                ),
                _intField(
                  label: _l10n.tr('set_index_max'),
                  help: _l10n.tr('set_index_max_help'),
                  value: _draft.autoIndexMaxMB,
                  min: 0,
                  max: 1 << 20,
                  onSaved: (v) => _draft.autoIndexMaxMB = v,
                ),
                _intField(
                  label: _l10n.tr('set_enc_sample'),
                  help: _l10n.tr('set_enc_sample_help'),
                  value: _draft.encodingSampleKB,
                  min: 1,
                  max: 8 << 10,
                  onSaved: (v) => _draft.encodingSampleKB = v,
                ),
                _intField(
                  label: _l10n.tr('set_script_max'),
                  help: _l10n.tr('set_script_max_help'),
                  value: _draft.scriptWholeFileMaxMB,
                  min: 0,
                  max: 2048,
                  onSaved: (v) => _draft.scriptWholeFileMaxMB = v,
                ),

                // Font (family/size/line height/columns) moved to the font
                // dialog (View → Font Settings…), appearance to the color editor
                // (View → Color Editor…).
                _section(_l10n.tr('set_sec_editing')),
                _intField(
                  label: _l10n.tr('set_tab_size'),
                  help: _l10n.tr('set_tab_size_help'),
                  value: _draft.tabSize,
                  min: AppSettings.tabSizeMin,
                  max: AppSettings.tabSizeMax,
                  onSaved: (v) => _draft.tabSize = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_insert_spaces')),
                  subtitle: Text(_l10n.tr('set_insert_spaces_help')),
                  value: _draft.insertSpaces,
                  onChanged: (v) => setState(() => _draft.insertSpaces = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_auto_indent')),
                  subtitle: Text(_l10n.tr('set_auto_indent_help')),
                  value: _draft.autoIndent,
                  onChanged: (v) => setState(() => _draft.autoIndent = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_auto_close')),
                  subtitle: Text(_l10n.tr('set_auto_close_help')),
                  value: _draft.autoCloseBrackets,
                  onChanged: (v) =>
                      setState(() => _draft.autoCloseBrackets = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_drag_drop')),
                  subtitle: Text(_l10n.tr('set_drag_drop_help')),
                  value: _draft.dragAndDrop,
                  onChanged: (v) => setState(() => _draft.dragAndDrop = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_auto_hex_binary')),
                  subtitle: Text(_l10n.tr('set_auto_hex_binary_help')),
                  value: _draft.autoHexBinary,
                  onChanged: (v) => setState(() => _draft.autoHexBinary = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_auto_complete')),
                  subtitle: Text(_l10n.tr('set_auto_complete_help')),
                  value: _draft.autoComplete,
                  onChanged: (v) => setState(() => _draft.autoComplete = v),
                ),
                _intField(
                  label: _l10n.tr('set_auto_complete_min'),
                  help: _l10n.tr('set_auto_complete_min_help'),
                  value: _draft.autoCompleteMinChars,
                  min: AppSettings.autoCompleteMinCharsMin,
                  max: AppSettings.autoCompleteMinCharsMax,
                  onSaved: (v) => _draft.autoCompleteMinChars = v,
                ),
                _intField(
                  label: _l10n.tr('set_undo_max'),
                  help: _l10n.tr('set_undo_max_help'),
                  value: _draft.undoMaxSteps,
                  min: AppSettings.undoMaxStepsMin,
                  max: AppSettings.undoMaxStepsMax,
                  onSaved: (v) => _draft.undoMaxSteps = v,
                ),
                _section(_l10n.tr('set_sec_backup')),
                _row(
                  _l10n.tr('set_auto_save'),
                  _l10n.tr('set_auto_save_help'),
                  DropdownButtonFormField<String>(
                    // Take the column's width; the intrinsic width (the
                    // longest item) overflows the row at a large UI scale.
                    isExpanded: true,
                    initialValue: _draft.autoSave,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (final c in AppSettings.autoSaveChoices)
                        DropdownMenuItem(
                          value: c,
                          child: Text(_l10n.tr('set_auto_save_$c')),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _draft.autoSave = v ?? 'off'),
                  ),
                ),
                _intField(
                  label: _l10n.tr('set_auto_save_delay'),
                  help: _l10n.tr('set_auto_save_delay_help'),
                  value: _draft.autoSaveDelaySec,
                  min: AppSettings.autoSaveDelayMin,
                  max: AppSettings.autoSaveDelayMax,
                  onSaved: (v) => _draft.autoSaveDelaySec = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_backup_on_save')),
                  subtitle: Text(_l10n.tr('set_backup_on_save_help')),
                  value: _draft.backupOnSave,
                  onChanged: (v) => setState(() => _draft.backupOnSave = v),
                ),
                _row(
                  _l10n.tr('set_backup_dir'),
                  _l10n.tr('set_backup_dir_help'),
                  TextFormField(
                    initialValue: _draft.backupDir,
                    decoration: const InputDecoration(isDense: true),
                    onSaved: (s) => _draft.backupDir = (s ?? '').trim(),
                  ),
                ),
                _section(_l10n.tr('set_sec_startup')),
                // Keymap lives in the menubar (View → Keyboard Layout) and the UI
                // language in the Language menu — neither is duplicated here.
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_l10n.tr('set_log_to_file')),
                  subtitle: Text(
                    _l10n.tr('set_log_help') +
                        (_restartHint ? _l10n.tr('set_restart_hint') : ''),
                  ),
                  value: _draft.logToFile,
                  onChanged: (v) => setState(() {
                    _draft.logToFile = v;
                    _restartHint = v != AppSettings.instance.logToFile;
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _resetToDefaults,
          child: Text(_l10n.tr('set_reset_defaults')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(_l10n.tr('common_cancel')),
        ),
        FilledButton(
          onPressed: _apply,
          child: Text(_l10n.tr('common_apply_save')),
        ),
      ],
    );
  }

  // ── field builders ────────────────────────────────────────────────────────

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _row(String label, String? help, Widget field) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(label),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              if (help != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    help,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _intField({
    required String label,
    String? help,
    required int value,
    required int min,
    required int max,
    required void Function(int) onSaved,
  }) => _row(
    label,
    help,
    TextFormField(
      initialValue: '$value',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(isDense: true, helperText: '$min – $max'),
      validator: (s) {
        final n = int.tryParse(s ?? '');
        if (n == null) return _l10n.tr('err_int');
        if (n < min || n > max) return _l10n.trf('err_range', [min, max]);
        return null;
      },
      onSaved: (s) => onSaved(int.parse(s!)),
    ),
  );
}
