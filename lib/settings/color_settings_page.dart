// Color settings page: the editor chrome colors plus one color per syntax highlight style, for
// each of the two themes (dark / light).
//
// Split out of settings_page.dart because it is by far the biggest group (6 + 17 colors × 2
// themes). Like the general page it edits a draft and only commits on apply; the sample at the top
// re-renders from the draft, so you see a change before committing it.

import 'package:flutter/material.dart';

import '../editor/highlight.dart';
import '../l10n/app_localizations.dart';
import '../util/dispose_later.dart';
import 'app_settings.dart';
import 'color_wheel.dart';
import 'resizable_dialog.dart';

/// Show the color settings as a modal dialog. Returns true if the user applied changes.
Future<bool> showColorSettingsDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const ColorSettingsDialog(),
    ) ??
    false;

/// l10n key per highlight style (`hl_<styleKey>`, see the .arb files), in the
/// order [hlStyleKeys] lists them.
String _styleLabelKey(int style) => 'hl_${hlStyleKeys[style]}';

class ColorSettingsDialog extends StatefulWidget {
  const ColorSettingsDialog({super.key});

  @override
  State<ColorSettingsDialog> createState() => _ColorSettingsDialogState();
}

class _ColorSettingsDialogState extends State<ColorSettingsDialog> {
  late final AppSettings _draft = AppSettings.from(AppSettings.instance);

  /// Which theme is being edited (independent of which one is currently active).
  late bool _editingDark = AppSettings.instance.isDark;

  ThemeColors get _colors => _editingDark ? _draft.dark : _draft.light;

  Future<void> _apply() async {
    // The draft was copied from the live settings, so adopting it keeps the
    // color mode / UI scale as they are now (Settings → Appearance owns those).
    _draft.themeMode = AppSettings.instance.themeMode;
    _draft.uiScale = AppSettings.instance.uiScale;
    await AppSettings.instance.adopt(_draft);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _resetTheme() {
    setState(() {
      if (_editingDark) {
        _draft.dark = ThemeColors.dark();
      } else {
        _draft.light = ThemeColors.light();
      }
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_l10n.tr('col_title')),
      content: ResizableDialogBox(
        id: 'colors',
        initialWidth: 640,
        initialHeight: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The color mode (dark / light / system) lives in Settings → Appearance;
            // this editor only edits the two palettes.
            Row(
              children: [
                Text(_l10n.tr('col_edit_which')),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text(_l10n.tr('theme_dark')),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text(_l10n.tr('theme_light')),
                    ),
                  ],
                  selected: {_editingDark},
                  onSelectionChanged: (s) =>
                      setState(() => _editingDark = s.first),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    _l10n.trf('col_active_note', [
                      _l10n.tr(_draft.isDark ? 'theme_dark' : 'theme_light'),
                    ]),
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // A menu-bar strip in the interface background color, so the
            // "Chrome background" row shows its effect before applying (the editor
            // sample below only covers the text area and the gutter).
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: Color(_colors.chromeBg),
                border: Border.all(color: Colors.grey),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(4),
                ),
              ),
              child: Text(
                [
                  for (final k in const ['menu_file', 'menu_edit', 'menu_view'])
                    _l10n.tr(k),
                ].join('    '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Color(_colors.fg), fontSize: 13),
              ),
            ),
            _Preview(colors: _colors, settings: _draft),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(_l10n.tr('col_sec_editor')),
                    _colorRow(
                      _l10n.tr('col_bg'),
                      _colors.bg,
                      (v) => _colors.bg = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_fg'),
                      _colors.fg,
                      (v) => _colors.fg = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_gutter_bg'),
                      _colors.gutterBg,
                      (v) => _colors.gutterBg = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_gutter_fg'),
                      _colors.gutterFg,
                      (v) => _colors.gutterFg = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_chrome_bg'),
                      _colors.chromeBg,
                      (v) => _colors.chromeBg = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_caret'),
                      _colors.caret,
                      (v) => _colors.caret = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_selection'),
                      _colors.selection,
                      (v) => _colors.selection = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_current_line'),
                      _colors.currentLine,
                      (v) => _colors.currentLine = v,
                    ),
                    _colorRow(
                      _l10n.tr('col_whitespace'),
                      _colors.whitespace,
                      (v) => _colors.whitespace = v,
                    ),
                    _header(_l10n.tr('col_sec_syntax')),
                    for (final e in hlStyleKeys.entries)
                      if (_colors.syntax[e.key] != null)
                        _colorRow(
                          '${_l10n.tr(_styleLabelKey(e.key))}（${e.value}）',
                          _colors.syntax[e.key]!,
                          (v) => _colors.syntax[e.key] = v,
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
          onPressed: _resetTheme,
          child: Text(
            _l10n.trf('col_restore_set', [
              _l10n.tr(_editingDark ? 'theme_dark' : 'theme_light'),
            ]),
          ),
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

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  /// One color: label + swatch that opens a picker + hex field. Editing either updates the draft
  /// (and therefore the preview) immediately.
  Widget _colorRow(String label, int value, void Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 220, child: Text(label)),
          _Swatch(
            color: value,
            onPick: (c) => setState(() => onChanged(c)),
            label: label,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: TextFormField(
              key: ValueKey(
                '$label/$value',
              ), // refresh when changed via the picker
              initialValue: colorToHex(value),
              decoration: const InputDecoration(isDense: true),
              onChanged: (s) {
                final c = parseColor(s);
                if (c != null) setState(() => onChanged(c));
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Clickable color swatch; tapping opens a small palette + alpha slider.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.onPick,
    required this.label,
  });

  final int color;
  final String label;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDialog<int>(
          context: context,
          builder: (_) => _PickerDialog(initial: color, label: label),
        );
        if (picked != null) onPick(picked);
      },
      child: Container(
        width: 40,
        height: 28,
        decoration: BoxDecoration(
          color: Color(color),
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// Color picker: an HSV wheel (any color), a grid of common colors and an
/// opacity slider — without pulling in a picker package (color_wheel.dart).
class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.initial, required this.label});

  final int initial;
  final String label;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  // HSV is the source of truth: converting back and forth through RGB would
  // lose the hue/saturation at black or white, and the wheel's markers
  // would jump while dragging along the square's edges.
  late HSVColor _hsv = HSVColor.fromColor(
    Color(0xFF000000 | (widget.initial & 0x00FFFFFF)),
  );
  late double _alpha = ((widget.initial >> 24) & 0xFF).toDouble();

  int get _rgb => _hsv.toColor().toARGB32() & 0x00FFFFFF;
  set _rgb(int rgb) => _hsv = HSVColor.fromColor(Color(0xFF000000 | rgb));

  // The editable hex field mirrors the picks; edits typed into it flow the
  // other way (a valid #AARRGGBB / #RRGGBB sets wheel, swatch and opacity)
  // without rewriting the field under the user's caret.
  late final TextEditingController _hexCtl = TextEditingController(
    text: colorToHex(_value),
  );

  @override
  void dispose() {
    disposeLater(_hexCtl); // the dialog still rebuilds during its exit animation
    super.dispose();
  }

  /// A pick from the wheel / palette / slider: update and refresh the hex.
  void _pick(void Function() change) {
    setState(change);
    _hexCtl.text = colorToHex(_value);
  }

  void _hexTyped(String s) {
    final c = parseColor(s);
    if (c == null) return;
    setState(() {
      _rgb = c & 0x00FFFFFF;
      _alpha = ((c >> 24) & 0xFF).toDouble();
    });
  }

  static const List<int> _palette = [
    0x000000, 0x1E1E1E, 0x252526, 0x3C3C3C, 0x6E7681, 0x858585, 0xAEAFAD,
    0xD4D4D4, 0xF3F3F3, 0xFFFFFF, //
    0xF14C4C, 0xCD3131, 0xA31515, 0xE5C07B, 0xDCDCAA, 0x795E26, 0x89D185,
    0x107C10, 0x008000, 0x098658, //
    0x4EC9B0, 0x267F99, 0x9CDCFE, 0x569CD6, 0x3794FF, 0x0000FF, 0x0070C1,
    0x001080, 0xC586C0, 0x800080,
  ];

  int get _value => (_alpha.round() << 24) | _rgb;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.trf('col_pick_title', [widget.label])),
      content: ResizableDialogBox(
        id: 'colorPicker',
        initialWidth: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ColorWheel(
                  color: _hsv,
                  onChanged: (c) => _pick(() => _hsv = c),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in _palette)
                    InkWell(
                      onTap: () => _pick(() => _rgb = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(0xFF000000 | c),
                          border: Border.all(
                            color: _rgb == c ? Colors.blue : Colors.grey,
                            width: _rgb == c ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // [live swatch] #hex   opacity [slider]
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(_value),
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _hexCtl,
                      decoration: const InputDecoration(isDense: true),
                      onChanged: _hexTyped,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(l10n.tr('col_opacity')),
                  Expanded(
                    child: Slider(
                      value: _alpha,
                      min: 0,
                      max: 255,
                      divisions: 255,
                      label: '${(_alpha / 255 * 100).round()}%',
                      onChanged: (v) => _pick(() => _alpha = v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: Text(l10n.tr('common_ok')),
        ),
      ],
    );
  }
}

/// Sample code rendered with the theme being edited, so the effect is visible before applying.
class _Preview extends StatelessWidget {
  const _Preview({required this.colors, required this.settings});

  final ThemeColors colors;
  final AppSettings settings;

  // (text, style id) runs per line; -1 = plain foreground, _ws = a whitespace
  // mark drawn with the whitespace color (· space, → tab, ¶ line end — the
  // glyphs the editor paints when Show Whitespace is on).
  static const int _ws = -2;
  static const List<List<(String, int)>> _lines = [
    [('// color preview', Hl.comment), ('¶', _ws)],
    [
      ('class', Hl.keyword),
      (' ', -1),
      ('Editor', Hl.type),
      (' {', Hl.punctuation),
    ],
    [
      ('··', _ws),
      ('final', Hl.keyword),
      (' ', -1),
      ('name', Hl.property),
      (' ', -1),
      ('=', Hl.operator),
      (' ', -1),
      ('"madedit2"', Hl.string),
      (';', Hl.punctuation),
    ],
    [
      ('··', _ws),
      ('int', Hl.type),
      (' ', -1),
      ('lines', Hl.property),
      (' ', -1),
      ('=', Hl.operator),
      (' ', -1),
      ('1234', Hl.number),
      (';', Hl.punctuation),
    ],
    [
      ('··', _ws),
      ('void', Hl.type),
      (' ', -1),
      ('open', Hl.function),
      ('() =>', Hl.punctuation),
      ('→', _ws),
      ('null', Hl.constant),
      (';', Hl.punctuation),
    ],
    [('}', Hl.punctuation)],
  ];

  @override
  Widget build(BuildContext context) {
    final family = settings.fontFamily.trim();
    return Container(
      // The sample text obeys the UI scale (MediaQuery textScaler), so the
      // box must grow with it or the five lines overflow at 140%+.
      height: MediaQuery.textScalerOf(context).scale(150),
      decoration: BoxDecoration(
        color: Color(colors.bg),
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 44,
            color: Color(colors.gutterBg),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 1; i <= _lines.length; i++)
                  Text(
                    '$i',
                    style: TextStyle(
                      color: Color(colors.gutterFg),
                      fontSize: 13,
                      height: 1.4,
                      fontFamily: family.isEmpty ? null : family,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _lines.length; i++)
                    Stack(
                      children: [
                        // Third line doubles as the selection-color sample.
                        if (i == 2)
                          Positioned.fill(
                            child: ColoredBox(color: Color(colors.selection)),
                          ),
                        Text.rich(
                          TextSpan(
                            children: [
                              for (final (text, style) in _lines[i])
                                TextSpan(
                                  text: text,
                                  style: TextStyle(
                                    color: Color(
                                      style == _ws
                                          ? colors.whitespace
                                          : style < 0
                                          ? colors.fg
                                          : (colors.syntax[style] ?? colors.fg),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            fontFamily: family.isEmpty ? null : family,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
