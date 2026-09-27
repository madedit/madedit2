// Column editor dialog (Edit → Column Editor…, alt+c): insert a text or a
// number sequence into every line of the column block.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/column_editor.dart';
import '../l10n/app_localizations.dart';
import '../util/dispose_later.dart';
import 'resizable_dialog.dart';

Future<ColumnEditorSpec?> showColumnEditorDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  var isNumber = true;
  var radix = 10;
  var leadingZeros = false;
  final textCtl = TextEditingController();
  final initCtl = TextEditingController(text: '1');
  final stepCtl = TextEditingController(text: '1');
  final repeatCtl = TextEditingController(text: '1');
  Widget numField(
    TextEditingController c,
    String label, {
    bool signed = true,
  }) => SizedBox(
    width: 110,
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          RegExp(signed ? r'[-0-9]' : r'[0-9]'),
        ),
      ],
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text(l10n.tr('coled_title')),
        content: ResizableDialogBox(
          id: 'columnEditor',
          initialWidth: 420,
          child: RadioGroup<bool>(
            groupValue: isNumber,
            onChanged: (v) => setDlg(() => isNumber = v ?? true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.tr('coled_hint'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Radio<bool>(value: false),
                  title: Text(l10n.tr('coled_text')),
                  onTap: () => setDlg(() => isNumber = false),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: TextField(
                    controller: textCtl,
                    enabled: !isNumber,
                    decoration: InputDecoration(
                      hintText: l10n.tr('coled_text_hint'),
                      isDense: true,
                    ),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Radio<bool>(value: true),
                  title: Text(l10n.tr('coled_number')),
                  onTap: () => setDlg(() => isNumber = true),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          numField(initCtl, l10n.tr('coled_initial')),
                          numField(stepCtl, l10n.tr('coled_step')),
                          numField(
                            repeatCtl,
                            l10n.tr('coled_repeat'),
                            signed: false,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(l10n.tr('coled_format')),
                          const SizedBox(width: 8),
                          DropdownButton<int>(
                            value: radix,
                            items: const [
                              DropdownMenuItem(value: 10, child: Text('Dec')),
                              DropdownMenuItem(value: 16, child: Text('Hex')),
                              DropdownMenuItem(value: 8, child: Text('Oct')),
                              DropdownMenuItem(value: 2, child: Text('Bin')),
                            ],
                            onChanged: isNumber
                                ? (v) => setDlg(() => radix = v ?? 10)
                                : null,
                          ),
                          const SizedBox(width: 16),
                          Checkbox(
                            value: leadingZeros,
                            onChanged: isNumber
                                ? (v) => setDlg(() => leadingZeros = v ?? false)
                                : null,
                          ),
                          Text(l10n.tr('coled_leading_zeros')),
                        ],
                      ),
                    ],
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
            child: Text(l10n.tr('common_ok')),
          ),
        ],
      ),
    ),
  );
  final spec = ok != true
      ? null
      : isNumber
      ? ColumnEditorSpec.number(
          initial: int.tryParse(initCtl.text.trim()) ?? 1,
          step: int.tryParse(stepCtl.text.trim()) ?? 1,
          repeat: int.tryParse(repeatCtl.text.trim()) ?? 1,
          leadingZeros: leadingZeros,
          radix: radix,
        )
      : ColumnEditorSpec.text(textCtl.text);
  for (final c in [textCtl, initCtl, stepCtl, repeatCtl]) {
    disposeLater(c);
  }
  return spec;
}
