// Font settings dialog (View → Font Settings…): system font list split into
// monospace / CJK monospace / proportional (measured with the layout engine:
// ten 'i' as wide as ten 'W' → monospace, ten "中" = twenty cells → CJK),
// plus sliders for font size / line height / columns
// per row. Every change previews LIVE on the whole app
// (AppSettings.previewFont — notify without saving); "Apply and Save" persists,
// cancel/dismiss restores the original values on dispose.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../util/log.dart';
import 'app_settings.dart';
import 'font_display_names.dart';
import 'resizable_dialog.dart';
import 'system_fonts.dart';

/// Show the font settings dialog. Returns true if the user applied changes.
Future<bool> showFontSettingsDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      // Light barrier: the point is watching the editor update live.
      barrierColor: Colors.black26,
      builder: (_) => const FontSettingsDialog(),
    ) ??
    false;

// How the font dialog groups a family (measured, see _classify).
enum _FontKind { mono, monoCjk, prop }

class FontSettingsDialog extends StatefulWidget {
  const FontSettingsDialog({super.key, this.familiesOverride});

  /// Tests inject a fixed family list (no registry/fc-list involved).
  final List<String>? familiesOverride;

  @override
  State<FontSettingsDialog> createState() => _FontSettingsDialogState();
}

class _FontSettingsDialogState extends State<FontSettingsDialog> {
  // Originals for cancel-restore. NOT `late final` (lazily reading them in
  // dispose would capture the already-previewed values).
  final String _origFamily = AppSettings.instance.fontFamily;
  final double _origSize = AppSettings.instance.fontSize;
  final int _origLinePct = AppSettings.instance.lineHeightPercent;
  final int _origCols = AppSettings.instance.softWrapColumns;
  final String _origWrap = AppSettings.instance.softWrapMode;
  bool _applied = false;

  // Current picks (start from the live settings, preview as they change).
  late String _family = _origFamily;
  late double _size = _origSize;
  late int _linePct = _origLinePct; // line height, % of the font size
  late int _cols = _origCols;
  // Default soft-wrap mode for tabs that have no per-tab override (the View
  // menu / alt+z set the active tab only).
  late String _wrap = _origWrap;

  // Classified families; null while enumerating/measuring. Three disjoint
  // groups: monospace, CJK monospace (a CJK ideograph is exactly two Latin
  // cells wide — column mode lines up mixed text), proportional.
  List<String>? _mono;
  List<String>? _monoCjk;
  List<String>? _prop;

  // English family (lower-cased) → name in the UI language ("細明體" for
  // MingLiU), display only: the setting keeps the English name. Filled in
  // asynchronously after the list is up (font_display_names.dart).
  Map<String, String> _display = const {};

  AppLocalizations get _l10n => AppLocalizations.of(context);

  String _label(String family) => fontDisplayName(_display, family);

  int _byLabel(String a, String b) =>
      _label(a).toLowerCase().compareTo(_label(b).toLowerCase());

  @override
  void initState() {
    super.initState();
    fontNamesLog ??= (m) => Log.instance.i(m);
    () async {
      final families =
          widget.familiesOverride ?? await listSystemFontFamilies();
      if (!mounted) return;
      final mono = <String>[];
      final monoCjk = <String>[];
      final prop = <String>[];
      for (final f in families) {
        switch (_classify(f)) {
          case _FontKind.mono:
            mono.add(f);
          case _FontKind.monoCjk:
            monoCjk.add(f);
          case _FontKind.prop:
            prop.add(f);
        }
      }
      setState(() {
        _mono = mono;
        _monoCjk = monoCjk;
        _prop = prop;
      });
      // Localized display names (a few hundred small file reads on Windows,
      // fc-list / CoreText elsewhere): the list shows English meanwhile and
      // re-sorts by the displayed names once they arrive.
      if (widget.familiesOverride != null) return;
      final loc = Localizations.localeOf(context);
      final names = await localizedFontFamilyNames(
        loc.languageCode,
        loc.countryCode,
      );
      if (!mounted || names.isEmpty) return;
      setState(() {
        _display = names;
        mono.sort(_byLabel);
        monoCjk.sort(_byLabel);
        prop.sort(_byLabel);
      });
    }();
  }

  @override
  void dispose() {
    if (!_applied) {
      // Deferred: dispose can run while the tree is locked (finalize phase),
      // and the restore notifies listeners that call setState.
      scheduleMicrotask(
        () => AppSettings.instance.previewFont(
          family: _origFamily,
          size: _origSize,
          lineHeightPercent: _origLinePct,
          wrapColumns: _origCols,
          wrapMode: _origWrap,
        ),
      );
    }
    super.dispose();
  }

  // Monospace test: ten narrow glyphs as wide as ten wide ones. A family the
  // engine can't resolve measures with the fallback font and lands in the
  // proportional group — acceptable.
  //
  // CJK monospace is judged by what this machine actually renders with the
  // family — ideographs included, even when they come from the system's
  // fallback font: what matters to the user is whether "中" lands exactly
  // on two Latin cells here, not which font supplies the glyph.
  _FontKind _classify(String family) {
    double w(String s) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(fontFamily: family, fontSize: 20),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = tp.width;
      tp.dispose();
      return width;
    }

    final wi = w('iiiiiiiiii');
    if (wi <= 0 || (wi - w('WWWWWWWWWW')).abs() >= 0.5) {
      return _FontKind.prop;
    }
    // Ten ideographs vs twenty Latin cells: sub-pixel drift adds up over
    // ten glyphs, so a font that is truly 2:1 still lands well inside 1px.
    final wc = w('中中中中中中中中中中');
    return (wc - wi * 2).abs() < 1.0 ? _FontKind.monoCjk : _FontKind.mono;
  }

  void _preview() => AppSettings.instance.previewFont(
    family: _family,
    size: _size,
    lineHeightPercent: _linePct,
    wrapColumns: _cols,
    wrapMode: _wrap,
  );

  Future<void> _apply() async {
    _applied = true;
    final d = AppSettings.from(AppSettings.instance)
      ..fontFamily = _family
      ..fontSize = _size
      ..lineHeightPercent = _linePct
      ..softWrapColumns = _cols
      ..softWrapMode = _wrap;
    // Diagnostic breadcrumbs around the apply (a freeze has been seen right
    // after "settings saved"); the timestamps show which step never returns.
    final sw = Stopwatch()..start();
    Log.instance.d(
      'font apply: adopt "$_family" $_size/$_linePct% cols $_cols',
    );
    await AppSettings.instance.adopt(d);
    Log.instance.d(
      'font apply: adopted in ${sw.elapsedMilliseconds} ms, closing dialog',
    );
    if (mounted) Navigator.of(context).pop(true);
    Log.instance.d('font apply: dialog closed (${sw.elapsedMilliseconds} ms)');
  }

  Widget _familyTile(String family, {String? label}) {
    final selected =
        family == _family || (family.isEmpty && _family.trim().isEmpty);
    return ListTile(
      dense: true,
      selected: selected,
      // A "*" marker in a fixed-width slot so the chosen face stands out
      // beyond the (subtle) selected tint and the names stay aligned.
      minLeadingWidth: 0,
      horizontalTitleGap: 4,
      leading: SizedBox(
        width: 14,
        child: Text(
          selected ? '*' : '',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(
        label ?? _label(family),
        // The list doubles as the font preview: each name in its own face.
        style: TextStyle(fontFamily: family.isEmpty ? null : family),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        setState(() => _family = family);
        _preview();
      },
    );
  }

  Widget _groupHeader(String text) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 8, bottom: 2),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _fontList() {
    final mono = _mono, monoCjk = _monoCjk, prop = _prop;
    if (mono == null || monoCjk == null || prop == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        _familyTile('', label: _l10n.tr('ft_default')),
        if (mono.isNotEmpty) _groupHeader(_l10n.tr('ft_mono')),
        for (final f in mono) _familyTile(f),
        if (monoCjk.isNotEmpty) _groupHeader(_l10n.tr('ft_mono_cjk')),
        for (final f in monoCjk) _familyTile(f),
        if (prop.isNotEmpty) _groupHeader(_l10n.tr('ft_prop')),
        for (final f in prop) _familyTile(f),
      ],
    );
  }

  Widget _sliderRow({
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required void Function(double) onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 48, child: Text(valueText, textAlign: TextAlign.right)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_l10n.tr('ft_title')),
      content: ResizableDialogBox(
        id: 'font',
        initialWidth: 680,
        initialHeight: 480,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 250,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _fontList(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              // Scrollable: at a large UI scale the sliders' rows grow past
              // the dialog's fixed height.
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Sample rendered with the current picks (the open editor
                    // behind the dialog previews live as well).
                    Container(
                      height: MediaQuery.textScalerOf(context).scale(120),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          'AaBbCc 0123456789 ilI| oO0\n'
                          '中文字型範例 フォント見本\n'
                          'the quick brown fox jumps over the lazy dog',
                          style: TextStyle(
                            fontFamily: _family.trim().isEmpty ? null : _family,
                            fontSize: _size,
                            height: _linePct / 100,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _sliderRow(
                      label: _l10n.tr('set_font_size'),
                      valueText: _size.round().toString(),
                      value: _size,
                      min: 6,
                      max: 40,
                      divisions: 34,
                      onChanged: (v) {
                        setState(() => _size = v.roundToDouble());
                        _preview();
                      },
                    ),
                    _sliderRow(
                      label: _l10n.tr('set_line_height'),
                      valueText: '$_linePct%',
                      value: _linePct.toDouble(),
                      min: AppSettings.lineHeightPercentMin.toDouble(),
                      max: AppSettings.lineHeightPercentMax.toDouble(),
                      divisions:
                          AppSettings.lineHeightPercentMax -
                          AppSettings.lineHeightPercentMin,
                      onChanged: (v) {
                        setState(() => _linePct = v.round());
                        _preview();
                      },
                    ),
                    // Default wrap mode (labels reuse the View → Word wrap
                    // strings; "(default)" is the encoding menu's tag).
                    Row(
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            '${_l10n.tr('menu_wrap')}${_l10n.tr('enc_default_tag')}',
                          ),
                        ),
                        Expanded(
                          child: DropdownButton<String>(
                            value: _wrap,
                            isExpanded: true,
                            items: [
                              for (final m in AppSettings.softWrapModeChoices)
                                DropdownMenuItem(
                                  value: m,
                                  child: Text(_l10n.tr('item_wrap_$m')),
                                ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _wrap = v);
                              _preview();
                            },
                          ),
                        ),
                      ],
                    ),
                    _sliderRow(
                      label: _l10n.tr('set_wrap_cols'),
                      valueText: '$_cols',
                      value: _cols.toDouble(),
                      min: 20,
                      max: 1024,
                      divisions: 251,
                      onChanged: (v) {
                        setState(() => _cols = (v / 4).round() * 4);
                        _preview();
                      },
                    ),
                  ],
                ),
              ),
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
