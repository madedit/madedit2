// Appearance dialog (Settings → Appearance…): the app's own look, as opposed to the
// editor text — the color mode (dark / light / system) and the UI text scale
// (menus, tabs, dialogs, status bar; applied as a MediaQuery text scaler at
// the MaterialApp root, see main.dart). Both preview LIVE while the dialog is
// open (AppSettings.previewThemeMode / previewUiScale — notify without
// saving); "Apply and Save" persists via adopt, cancel/dismiss restores the
// originals on dispose.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'app_settings.dart';
import 'resizable_dialog.dart';

/// Show the appearance dialog. Returns true if the user applied changes.
Future<bool> showAppearanceDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      // Light barrier: the point is watching the app update live.
      barrierColor: Colors.black26,
      builder: (_) => const AppearanceDialog(),
    ) ??
    false;

class AppearanceDialog extends StatefulWidget {
  const AppearanceDialog({super.key});

  @override
  State<AppearanceDialog> createState() => _AppearanceDialogState();
}

class _AppearanceDialogState extends State<AppearanceDialog> {
  // Originals for cancel-restore. NOT `late final` (lazily reading them in
  // dispose would capture the already-previewed values).
  final String _origMode = AppSettings.instance.themeMode;
  final double _origScale = AppSettings.instance.uiScale;
  bool _applied = false;

  late String _mode = _origMode;
  late double _scale = _origScale;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void dispose() {
    if (!_applied) {
      // Deferred: dispose can run while the tree is locked (finalize phase),
      // and the restore notifies listeners that call setState.
      final mode = _origMode, scale = _origScale;
      scheduleMicrotask(() {
        AppSettings.instance.previewThemeMode(mode);
        AppSettings.instance.previewUiScale(scale);
      });
    }
    super.dispose();
  }

  void _setMode(String mode) {
    setState(() => _mode = mode);
    AppSettings.instance.previewThemeMode(mode);
  }

  void _setScale(double v) {
    // Steps of 0.1 (the slider's divisions), rounded so the stored value
    // stays clean.
    final s = (v * 10).round() / 10;
    setState(() => _scale = s);
    AppSettings.instance.previewUiScale(s);
  }

  Future<void> _apply() async {
    _applied = true;
    final d = AppSettings.from(AppSettings.instance)
      ..themeMode = _mode
      ..uiScale = _scale;
    await AppSettings.instance.adopt(d);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    const min = AppSettings.uiScaleMin, max = AppSettings.uiScaleMax;
    return AlertDialog(
      title: Text(_l10n.tr('ap_title')),
      content: ResizableDialogBox(
        id: 'appearance',
        initialWidth: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wrap, not Row: the UI scale slider below previews live, and
            // at 140%+ the label plus the three segments no longer fit in
            // 480px — the segmented button then drops to its own line
            // instead of overflowing.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(_l10n.tr('set_theme_mode')),
                SegmentedButton<String>(
                  segments: [
                    for (final m in AppSettings.themeModeChoices)
                      ButtonSegment(
                        value: m,
                        label: Text(_l10n.tr('theme_$m')),
                      ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => _setMode(s.first),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(_l10n.tr('ap_ui_scale')),
                Expanded(
                  child: Slider(
                    value: _scale.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: ((max - min) * 10).round(),
                    onChanged: _setScale,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '${(_scale * 100).round()}%',
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            Text(
              _l10n.tr('ap_ui_scale_help'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
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
}
