// Run menu dialogs: run an external command (with placeholders and an
// optional "save as…"), and manage the saved commands.

import 'package:flutter/material.dart';

import '../editor/run_commands.dart';
import '../l10n/app_localizations.dart';
import '../util/dispose_later.dart';
import 'resizable_dialog.dart';

/// What the run dialog produced: the command to run now (null = cancelled)
/// and, when the user filled the name, a command to save.
class RunDialogResult {
  const RunDialogResult(this.command, this.capture, {this.saveAs});
  final String command;
  final bool capture;
  final String? saveAs;
}

Future<RunDialogResult?> showRunDialog(
  BuildContext context, {
  String initialCommand = '',
}) async {
  final l10n = AppLocalizations.of(context);
  final cmdCtl = TextEditingController(text: initialCommand);
  final nameCtl = TextEditingController();
  var capture = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text(l10n.tr('run_title')),
        // Scrollable: the placeholder list plus two fields outgrow a short
        // window (or a large UI scale) and AlertDialog caps the content
        // height rather than letting the Column overflow.
        content: ResizableDialogBox(
          id: 'run',
          initialWidth: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: cmdCtl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.tr('run_command'),
                    isDense: true,
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  [
                    for (final (p, _) in runPlaceholders)
                      '$p  ${l10n.tr('run_ph_${_phKey(p)}')}',
                  ].join('\n'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(ctx).disabledColor,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: capture,
                  onChanged: (v) => setDlg(() => capture = v ?? true),
                  title: Text(l10n.tr('run_capture')),
                  subtitle: Text(l10n.tr('run_capture_help')),
                ),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: l10n.tr('run_save_as'),
                    helperText: l10n.tr('run_save_as_help'),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('run_run')),
          ),
        ],
      ),
    ),
  );
  final cmd = cmdCtl.text.trim();
  final name = nameCtl.text.trim();
  disposeLater(cmdCtl);
  disposeLater(nameCtl);
  if (ok != true || cmd.isEmpty) return null;
  return RunDialogResult(cmd, capture, saveAs: name.isEmpty ? null : name);
}

String _phKey(String placeholder) =>
    placeholder.replaceAll(r'$(', '').replaceAll(')', '').toLowerCase();

/// Manage saved commands: run / edit (reopens the run dialog) / delete.
Future<void> showRunManageDialog(
  BuildContext context, {
  required List<RunCommand> commands,
  required Future<void> Function(List<RunCommand>) onSave,
  required void Function(RunCommand) onRun,
}) async {
  final l10n = AppLocalizations.of(context);
  final list = List<RunCommand>.of(commands);
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text(l10n.tr('run_manage_title')),
        content: ResizableDialogBox(
          id: 'runManage',
          initialWidth: 520,
          child: list.isEmpty
              ? Text(l10n.tr('run_none'))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < list.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(list[i].name),
                        subtitle: Text(
                          list[i].command,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          onRun(list[i]);
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: l10n.tr('run_edit'),
                              icon: const Icon(Icons.edit, size: 18),
                              onPressed: () async {
                                final r = await showRunDialog(
                                  ctx,
                                  initialCommand: list[i].command,
                                );
                                if (r == null) return;
                                list[i] = RunCommand(
                                  r.saveAs ?? list[i].name,
                                  r.command,
                                  capture: r.capture,
                                );
                                await onSave(list);
                                setDlg(() {});
                              },
                            ),
                            IconButton(
                              tooltip: l10n.tr('common_delete'),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                list.removeAt(i);
                                await onSave(list);
                                setDlg(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.tr('common_close')),
          ),
        ],
      ),
    ),
  );
}
