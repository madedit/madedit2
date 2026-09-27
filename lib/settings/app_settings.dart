// User-editable settings, persisted to `<exe>/settings/settings.json`.
//
// Everything here used to be a hard-coded constant in editor_view.dart / main.dart. The settings
// page (settings_page.dart) edits a draft copy and calls [adopt], which applies the values live
// (listeners re-render) and writes the file.
//
// Deliberately free of Flutter imports (colors are ARGB ints, listeners are plain callbacks, the
// logger is a hook) so it stays headless-testable — see tool/settings_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../editor/highlight.dart';
import 'settings_paths.dart';

const String settingsFileName = 'settings.json';

/// One complete color set: the editor chrome plus a color per syntax highlight style.
///
/// Two of these live in the settings (dark / light); [AppSettings.theme] picks the active one.
class ThemeColors {
  ThemeColors({
    required this.bg,
    required this.fg,
    required this.gutterBg,
    required this.gutterFg,
    required this.chromeBg,
    required this.caret,
    required this.selection,
    required this.currentLine,
    required this.whitespace,
    required this.syntax,
  });

  /// VS Code Dark style — what the editor used to hard-code.
  factory ThemeColors.dark() => ThemeColors(
    bg: 0xFF1E1E1E,
    fg: 0xFFD4D4D4,
    gutterBg: 0xFF252526,
    gutterFg: 0xFF858585,
    chromeBg: 0xFF252526,
    caret: 0xFFAEAFAD,
    selection: 0x553A6EA5,
    currentLine: 0x1AFFFFFF,
    whitespace: 0x59D4D4D4, // the foreground at 35%
    syntax: Map.of(defaultHlTheme),
  );

  /// VS Code Light+ style.
  factory ThemeColors.light() => ThemeColors(
    bg: 0xFFFFFFFF,
    fg: 0xFF1F1F1F,
    gutterBg: 0xFFF3F3F3,
    gutterFg: 0xFF6E7681,
    chromeBg: 0xFFF3F3F3,
    caret: 0xFF000000,
    selection: 0x779DE6FF,
    currentLine: 0x0A000000,
    whitespace: 0x591F1F1F,
    syntax: Map.of(defaultHlThemeLight),
  );

  int bg;
  int fg;
  int gutterBg;
  int gutterFg;

  /// The interface "chrome" around the editor: menu bar, status bar, search /
  /// goto bars, side panels (explorer, bookmarks, outline, find-in-files).
  /// Used to be the gutter background — changing the gutter recolored the
  /// whole window. Files from before this field follow their gutter color.
  int chromeBg;
  int caret;
  int selection;

  /// Backdrop of the caret's visual row (text mode) / caret byte cells (hex
  /// mode). Alpha-blended over [bg], drawn beneath the selection.
  int currentLine;

  /// Whitespace marks (View → Show Whitespace): the · → ¶ glyphs.
  int whitespace;

  /// Style id ([Hl]) → ARGB. A missing entry means "use the foreground color".
  final Map<int, int> syntax;

  ThemeColors copy() => ThemeColors(
    bg: bg,
    fg: fg,
    gutterBg: gutterBg,
    gutterFg: gutterFg,
    chromeBg: chromeBg,
    caret: caret,
    selection: selection,
    currentLine: currentLine,
    whitespace: whitespace,
    syntax: Map.of(syntax),
  );

  Map<String, Object?> toJson() => {
    'editor': {
      'background': _hex(bg),
      'foreground': _hex(fg),
      'gutterBackground': _hex(gutterBg),
      'gutterForeground': _hex(gutterFg),
      'chromeBackground': _hex(chromeBg),
      'caret': _hex(caret),
      'selection': _hex(selection),
      'currentLine': _hex(currentLine),
      'whitespace': _hex(whitespace),
    },
    'syntax': {
      for (final e in hlStyleKeys.entries)
        if (syntax[e.key] != null) e.value: _hex(syntax[e.key]!),
    },
  };

  /// Apply a decoded theme map; anything missing or malformed keeps [defaults]' value.
  void applyJson(Map<Object?, Object?> map, ThemeColors defaults) {
    final editor = _section(map['editor']);
    bg = _color(editor['background'], defaults.bg);
    fg = _color(editor['foreground'], defaults.fg);
    gutterBg = _color(editor['gutterBackground'], defaults.gutterBg);
    gutterFg = _color(editor['gutterForeground'], defaults.gutterFg);
    // A file from before the split: the chrome followed the gutter, so a
    // customized gutter keeps recoloring the chrome until the user sets it.
    chromeBg = editor.containsKey('chromeBackground')
        ? _color(editor['chromeBackground'], defaults.chromeBg)
        : (editor.containsKey('gutterBackground') ? gutterBg : defaults.chromeBg);
    caret = _color(editor['caret'], defaults.caret);
    selection = _color(editor['selection'], defaults.selection);
    currentLine = _color(editor['currentLine'], defaults.currentLine);
    whitespace = _color(editor['whitespace'], defaults.whitespace);

    final syn = _section(map['syntax']);
    for (final e in hlStyleKeys.entries) {
      final fallback = defaults.syntax[e.key];
      if (fallback == null) continue;
      syntax[e.key] = _color(syn[e.value], fallback);
    }
  }

  /// Apply the pre-theme flat `colors` section (settings.json written before light/dark existed).
  void applyLegacyEditorColors(Map<Object?, Object?> colors) {
    bg = _color(colors['background'], bg);
    fg = _color(colors['foreground'], fg);
    gutterBg = _color(colors['gutterBackground'], gutterBg);
    chromeBg = gutterBg; // the flat legacy form predates the split
    gutterFg = _color(colors['gutterForeground'], gutterFg);
    caret = _color(colors['caret'], caret);
    selection = _color(colors['selection'], selection);
  }
}

/// Where this module reports what it loaded/saved. main() points it at [Log]; keeping it a hook is
/// what lets this file stay free of package:flutter (util/log.dart imports it for debugPrint).
void Function(String message, {bool warn}) settingsLog =
    (String message, {bool warn = false}) {};

/// One file of the saved session: which pane id it occupied in the docking
/// layout, its path, the caret/scroll position, and a manually forced
/// encoding (null = auto-detect again on reopen).
///
/// [bookmark] is the macOS security-scoped bookmark (base64) that re-grants sandbox access to
/// [path] on the next launch; null on the other platforms, where the path alone is enough.
class SessionFile {
  SessionFile({
    required this.id,
    required this.path,
    this.caret = 0,
    this.anchor = 0,
    this.encoding,
    this.bookmark,
    this.bookmarks = const [],
    this.wrap,
  });

  final int id;
  final String path;
  final int caret;
  final int anchor;
  final String? encoding;

  /// Per-tab soft-wrap override ('off' / 'columns' / 'window'); null = the
  /// tab follows the global default [AppSettings.softWrapMode].
  final String? wrap;

  /// macOS security-scoped bookmark (sandbox re-authorization) — unrelated
  /// to the editor's line [bookmarks] below.
  final String? bookmark;

  /// Editor bookmarks: line-start byte offsets (capped at [maxBookmarks]).
  final List<int> bookmarks;

  static const int maxBookmarks = 1000;

  /// Same file, relocated — a bookmark can resolve to a path the user moved between runs.
  SessionFile withPath(String p) => SessionFile(
    id: id,
    path: p,
    caret: caret,
    anchor: anchor,
    encoding: encoding,
    bookmark: bookmark,
    bookmarks: bookmarks,
    wrap: wrap,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'caret': caret,
    'anchor': anchor,
    if (encoding != null) 'encoding': encoding,
    if (bookmark != null) 'bookmark': bookmark,
    if (bookmarks.isNotEmpty) 'bookmarks': bookmarks,
    if (wrap != null) 'wrap': wrap,
  };

  /// Null when [v] has no usable path.
  static SessionFile? fromJson(Object? v) {
    if (v is! Map) return null;
    final path = v['path'];
    if (path is! String || path.isEmpty) return null;
    final bm = v['bookmarks'];
    return SessionFile(
      id: _int(v['id'], -1, -1, 1 << 30),
      path: path,
      caret: _int(v['caret'], 0, 0, 1 << 62),
      anchor: _int(v['anchor'], 0, 0, 1 << 62),
      encoding: v['encoding'] is String ? v['encoding'] as String : null,
      bookmark: v['bookmark'] is String ? v['bookmark'] as String : null,
      bookmarks: bm is List
          ? [
              for (final b in bm.take(maxBookmarks))
                if (b is int && b >= 0) b,
            ]
          : const [],
      wrap: AppSettings.softWrapModeChoices.contains(v['wrap'])
          ? v['wrap'] as String
          : null,
    );
  }
}

/// Values the user can change, with the defaults the code used to hard-code.
///
/// [AppSettings.instance] is the live one the editor reads; other instances are drafts (the
/// settings page edits a copy and commits it with [adopt]).
class AppSettings {
  AppSettings();

  /// Deep copy — the settings page edits this and only commits on "apply".
  AppSettings.from(AppSettings o) {
    _copyFrom(o);
  }

  static final AppSettings instance = AppSettings();

  // ── Performance / highlighting ──────────────────────────────────────────────
  /// Files at or below this size highlight the whole file at once (0 = always window-parse).
  /// Whole-file parsing runs on a Rust worker thread, so this bounds how long colors take to
  /// settle, not a UI freeze; ~1.3 s/MB with a wasm grammar on a release build.
  int wholeFileHlMaxMB = 4;

  /// How long to wait after the last edit before re-parsing the whole file.
  int wholeFileHlDebounceMs = 120;

  /// Files at or below this size get their line index built automatically on open.
  int autoIndexMaxMB = 64;

  /// Largest range (selection, or the whole file) a user script's
  /// whole-text contract (`transformText`) may be given; above it the run is
  /// refused (the line contract streams and has no such cap). Bounds the
  /// memory a script can pull in: roughly 6–8× this in flight.
  int scriptWholeFileMaxMB = 32;

  /// How many bytes of the file head the encoding auto-detection samples.
  /// Bigger = better odds on files whose non-ASCII text starts late, at the
  /// cost of one larger read on open.
  int encodingSampleKB = 64;

  // ── Font ────────────────────────────────────────────────────────────────────
  /// Monospace family; empty = the platform default (Consolas / Menlo / monospace).
  String fontFamily = '';
  double fontSize = 16;

  /// Line height as a percentage of [fontSize] (100–200; the font dialog's
  /// slider). A percentage follows the font size — changing the size keeps
  /// the same proportions instead of leaving a fixed pixel height behind.
  /// Pre-percentage settings.json files carry `font.lineHeight` in pixels;
  /// applyJson converts them once.
  int lineHeightPercent = 140;
  static const int lineHeightPercentMin = 100;
  static const int lineHeightPercentMax = 200;

  /// Row height in logical pixels (the editor renders with the zoomed one).
  double get lineHeight => fontSize * lineHeightPercent / 100;

  /// Quick-zoom factor layered on top of [fontSize]/[lineHeight] (ctrl+wheel,
  /// ctrl+=/-, ctrl+0 resets). Kept apart from the base font values so the
  /// font dialog keeps editing the base and "reset zoom" has a meaning.
  double fontZoom = 1.0;
  static const double fontZoomMin = 0.3;
  static const double fontZoomMax = 5.0;
  static const double fontZoomStep = 0.1;

  /// Effective (zoomed) font size / line height the editor renders with.
  /// Row height of menu / popup items (Material default 48 is too tall for
  /// a desktop editor); scales with the UI text scale.
  double get menuRowHeight => 28 * uiScale;

  double get zoomedFontSize => fontSize * fontZoom;
  double get zoomedLineHeight => lineHeight * fontZoom;

  /// Soft-wrap mode in text mode: 'off' = no wrapping, 'columns' = by
  /// character count, 'window' = by window width. Wrapping only affects the
  /// display, never the file contents.
  String softWrapMode = 'window';

  /// Maximum characters per row in 'columns' mode.
  int softWrapColumns = 80;

  // ── Editing ─────────────────────────────────────────────────────────────────
  /// Tab stop width in cells: how a `\t` displays, how many spaces the Tab
  /// key inserts when [insertSpaces], and the indent/outdent step.
  int tabSize = 4;
  static const int tabSizeMin = 1;
  static const int tabSizeMax = 16;

  /// Tab key inserts spaces up to the next stop instead of a `\t`.
  bool insertSpaces = false;

  /// Enter copies the current line's leading whitespace onto the new line.
  bool autoIndent = true;

  /// Typing ( [ { " ' ` inserts the closing half too (and wraps a selection).
  bool autoCloseBrackets = true;

  /// Word completion popup while typing (ctrl+space always works).
  bool autoComplete = true;

  /// Pressing inside the selection and dragging carries the text to the drop
  /// point. Off = that drag selects like any other (VS Code's
  /// editor.dragAndDrop). Worth turning off where the mouse events are
  /// re-injected (remote desktop, some remapping tools): those split a
  /// double-click-and-hold into a fresh press on the selection, which lands
  /// on this feature instead of extending the selection.
  bool dragAndDrop = true;

  /// A file whose head looks binary (NULs / control bytes) opens in hex mode.
  bool autoHexBinary = true;

  /// Characters typed before the popup appears on its own.
  int autoCompleteMinChars = 2;
  static const int autoCompleteMinCharsMin = 1, autoCompleteMinCharsMax = 8;

  /// Undo steps kept per document (oldest dropped beyond this). The history
  /// now survives saving, so it is the only thing bounding its memory.
  int undoMaxSteps = 1000;
  static const int undoMaxStepsMin = 10, undoMaxStepsMax = 100000;

  // ── Auto save / backup (Settings → Advanced…) ───────────────────────────────
  static const List<String> autoSaveChoices = [
    'off',
    'afterDelay',
    'onFocusChange',
  ];

  /// 'off' | 'afterDelay' (every [autoSaveDelaySec]) | 'onFocusChange'
  /// (when the window loses focus). Saves modified, file-backed, writable
  /// panes only.
  String autoSave = 'off';
  int autoSaveDelaySec = 30;
  static const int autoSaveDelayMin = 1, autoSaveDelayMax = 3600;

  /// Copy the original before overwriting it on save.
  bool backupOnSave = false;

  /// Where backups go: '' = `<file>.bak` beside the file, otherwise
  /// `<dir>/<name>.<timestamp>.bak`.
  String backupDir = '';

  static const List<String> softWrapModeChoices = ['off', 'columns', 'window'];

  // ── Appearance ──────────────────────────────────────────────────────────────
  /// 'dark' | 'light' | 'system' — which of [dark] / [light] is in effect.
  String themeMode = 'light';

  /// Text/icon scale of the app's own UI (menus, tabs, dialogs, status bar) —
  /// the editor text has its own font size and is not affected. Applied as a
  /// MediaQuery text scaler at the MaterialApp root.
  double uiScale = 1.0;
  static const double uiScaleMin = 0.8;
  static const double uiScaleMax = 1.6;

  /// Draw spaces (·), tabs (→) and line ends (¶) as faint marks — three
  /// independent toggles (View → Show Spaces / Tabs / Newlines). A
  /// settings.json from before the split has one `showWhitespace` bool,
  /// which seeds all three.
  bool showSpaces = false;
  bool showTabs = false;
  bool showNewlines = false;

  /// Any whitespace mark on at all.
  bool get showWhitespace => showSpaces || showTabs || showNewlines;

  /// Draw a faint vertical line at each indent level (View → Indent Guides).
  bool indentGuides = false;

  /// Platform brightness, pushed in by the UI layer (this file stays free of dart:ui). Only
  /// consulted when [themeMode] is 'system'.
  bool systemIsDark = true;

  /// The two color sets; the active one ([theme]) is what the editor reads.
  ThemeColors dark = ThemeColors.dark();
  ThemeColors light = ThemeColors.light();

  /// Whether the active theme is the dark one.
  bool get isDark => switch (themeMode) {
    'light' => false,
    'system' => systemIsDark,
    _ => true,
  };

  /// The color set currently in effect.
  ThemeColors get theme => isDark ? dark : light;

  // Editor colors of the active theme (kept as top-level getters: the view reads these by name).
  int get bgArgb => theme.bg;
  int get fgArgb => theme.fg;
  int get gutterBgArgb => theme.gutterBg;
  int get chromeBgArgb => theme.chromeBg;
  int get gutterFgArgb => theme.gutterFg;
  int get caretArgb => theme.caret;
  int get selectionArgb => theme.selection;
  int get currentLineArgb => theme.currentLine;
  int get whitespaceArgb => theme.whitespace;

  /// Color for a syntax highlight style id ([Hl]); null = use the foreground color.
  int? hlColor(int style) => theme.syntax[style];

  // ── Startup / preferences ───────────────────────────────────────────────────
  /// Keymap preset applied to every editor pane: 'default' | 'vim'. (The old
  /// 'vscode' preset was folded into default; a saved 'vscode' falls back.)
  String keymap = 'default';

  /// UI language: '' = follow the system, otherwise 'en' | 'zh_TW' | 'ja' | 'ar'.
  String locale = '';

  /// Also write the log to `settings/logs/<start time>.log` (takes effect on restart).
  bool logToFile = false;

  // ── Session (window/tabs state restored on startup) ─────────────────────────
  // Written directly on [instance] by the shell (window close / debounced
  // changes) — deliberately NOT copied by [_copyFrom], so a settings-page
  // draft adopted later can't clobber a session saved in the meantime, and
  // "reset to defaults" doesn't wipe the open tabs.

  /// Last window geometry; null = never saved (use the platform default).
  double? winX, winY, winW, winH;
  bool winMaximized = false;

  /// Docking layout in the `docking` package's stringify format ('' = none).
  String sessionLayout = '';

  /// Files that were open, with their pane ids (referenced by the layout).
  List<SessionFile> sessionFiles = [];

  /// Pane id that was active (-1 = none).
  int sessionActiveId = -1;

  // ── File explorer sidebar (View → File Explorer) ───────────────────────────
  // Written directly on [instance] by the shell, like the session fields
  // (NOT part of [_copyFrom]).
  bool explorerOpen = false;
  double explorerWidth = 260;
  static const double explorerWidthMin = 160, explorerWidthMax = 800;

  /// Root folder shown in the sidebar ('' = pick one when first opened).
  String explorerRoot = '';

  // ── Extension → syntax overrides (Settings → File Associations…) ────────────
  /// User-chosen highlighting language per extension (lower-case ext without
  /// the dot → grammar name as in the Syntax menu, or 'plain'). Consulted
  /// before the grammar registry's own extension lists — the bundled
  /// assets/grammars cannot be edited, this is how a user maps `.vue` to
  /// html or `.nfo` to plain. Written directly on [instance] by the dialog;
  /// like the other per-machine state it is NOT part of [_copyFrom].
  Map<String, String> syntaxByExt = {};

  /// Remembered sizes of the resizable dialogs (ResizableDialogBox), by
  /// dialog id → (width, height). Per-machine UI state like the explorer
  /// width: written directly on [instance], NOT part of [_copyFrom].
  Map<String, (double, double)> dialogSizes = {};

  (double, double)? dialogSize(String id) => dialogSizes[id];

  void setDialogSize(String id, double w, double h) {
    final cur = dialogSizes[id];
    if (cur != null && cur.$1 == w && cur.$2 == h) return;
    dialogSizes = {...dialogSizes, id: (w, h)};
    saveSoon(); // a drag fires many updates; one write when it settles
  }

  Future<void> setSyntaxByExt(Map<String, String> m) async {
    final next = <String, String>{
      for (final e in m.entries)
        if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
          e.key.trim().toLowerCase(): e.value.trim(),
    };
    if (_sameMap(next, syntaxByExt)) return;
    syntaxByExt = next;
    _notify(); // open panes re-resolve their highlighter
    await save();
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  // ── Recent files (File → Recent Files) ──────────────────────────────────────
  /// Most-recently opened files, newest first, capped at [recentFilesMax].
  /// Written directly on [instance] by the shell on every user-driven open
  /// (session restore excluded) — like the session fields it is deliberately
  /// NOT part of [_copyFrom].
  List<String> recentFiles = [];

  static const int recentFilesMax = 10;

  // ── Donation ────────────────────────────────────────────────────────────────
  /// Hide the AppBar donate button ("I already donated"). Like the session
  /// fields this is written directly on [instance] and deliberately NOT part
  /// of [_copyFrom]: a settings-page draft or "reset to defaults" must not
  /// bring the button back (or hide it) as a side effect.
  bool donateHidden = false;

  /// Hide/show the AppBar donate button, notify listeners, and persist.
  Future<void> setDonateHidden(bool hidden) async {
    if (donateHidden == hidden) return;
    donateHidden = hidden;
    _notify();
    await save();
  }

  // ── Derived (what the editor actually uses) ─────────────────────────────────
  int get wholeFileHlMaxBytes => wholeFileHlMaxMB << 20;
  int get autoIndexMaxBytes => autoIndexMaxMB << 20;
  int get encodingSampleBytes => encodingSampleKB << 10;

  static const List<String> themeModeChoices = ['dark', 'light', 'system'];
  static const List<String> keymapChoices = ['default', 'vim'];
  /// '' (follow the system) or a `language[_COUNTRY]` tag such as `en`, `zh_TW`.
  static bool isLocaleTag(String v) =>
      v.isEmpty || RegExp(r'^[a-z]{2,3}(_[A-Za-z]{2,4})?$').hasMatch(v);

  // ── Change notification (plain callbacks; no Flutter dependency) ────────────
  final List<void Function()> _listeners = [];

  void addListener(void Function() f) => _listeners.add(f);
  void removeListener(void Function() f) => _listeners.remove(f);

  void _notify() {
    // Iterate a copy: a listener may remove itself (e.g. a disposed editor pane).
    for (final f in List.of(_listeners)) {
      f();
    }
  }

  /// Take [o]'s values as the live ones, persist them, and notify listeners.
  Future<void> adopt(AppSettings o) async {
    _copyFrom(o);
    _notify();
    await save();
  }

  /// Live font preview (notify, no save) — same contract as
  /// [previewThemeMode]: the font dialog applies values as the user picks,
  /// cancel calls it again with the originals, apply persists via [adopt].
  void previewFont({
    String? family,
    double? size,
    int? lineHeightPercent,
    int? wrapColumns,
    String? wrapMode,
  }) {
    var changed = false;
    if (family != null && family != fontFamily) {
      fontFamily = family;
      changed = true;
    }
    if (wrapMode != null &&
        wrapMode != softWrapMode &&
        softWrapModeChoices.contains(wrapMode)) {
      softWrapMode = wrapMode;
      changed = true;
    }
    if (size != null && size != fontSize) {
      fontSize = size;
      changed = true;
    }
    if (lineHeightPercent != null &&
        lineHeightPercent != this.lineHeightPercent) {
      this.lineHeightPercent = lineHeightPercent;
      changed = true;
    }
    if (wrapColumns != null && wrapColumns != softWrapColumns) {
      softWrapColumns = wrapColumns;
      changed = true;
    }
    if (changed) _notify();
  }

  /// Step the quick-zoom factor by [steps] (±1 per key press / wheel notch);
  /// `steps == 0` resets to 100%. Notifies immediately and persists with a
  /// short debounce (a wheel burst would otherwise overlap writes to
  /// settings.json). Returns true when the value actually changed.
  bool zoomFont(int steps) {
    final target = steps == 0
        ? 1.0
        : ((fontZoom + steps * fontZoomStep) * 100).round() / 100;
    final next = target.clamp(fontZoomMin, fontZoomMax).toDouble();
    if (next == fontZoom) return false;
    fontZoom = next;
    _notify();
    saveSoon();
    return true;
  }

  Timer? _saveTimer;

  /// Debounced [save] for high-frequency changes (zoom); trailing edge only.
  void saveSoon({Duration delay = const Duration(milliseconds: 400)}) {
    _saveTimer?.cancel();
    _saveTimer = Timer(delay, () {
      _saveTimer = null;
      save();
    });
  }

  /// Set the color mode on the live settings and notify — WITHOUT saving.
  /// The color editor uses this for live preview; cancel calls it again with
  /// the previous value, apply persists via [adopt].
  void previewThemeMode(String mode) {
    if (themeMode == mode || !themeModeChoices.contains(mode)) return;
    themeMode = mode;
    _notify();
  }

  /// Live preview of the UI scale (notify, no save) — same contract as
  /// [previewThemeMode]; the appearance dialog uses it.
  void previewUiScale(double scale) {
    final s = scale.clamp(uiScaleMin, uiScaleMax);
    if (s == uiScale) return;
    uiScale = s;
    _notify();
  }

  /// The platform's light/dark preference changed (pushed in by the UI layer). Only affects the
  /// active theme when [themeMode] is 'system'.
  void setSystemBrightness({required bool isDark}) {
    if (systemIsDark == isDark) return;
    systemIsDark = isDark;
    if (themeMode == 'system') _notify();
  }

  /// Reset every value back to the built-in default (not saved until [adopt]/[save]).
  void resetToDefaults() => _copyFrom(AppSettings());

  void _copyFrom(AppSettings o) {
    wholeFileHlMaxMB = o.wholeFileHlMaxMB;
    wholeFileHlDebounceMs = o.wholeFileHlDebounceMs;
    scriptWholeFileMaxMB = o.scriptWholeFileMaxMB;
    autoIndexMaxMB = o.autoIndexMaxMB;
    encodingSampleKB = o.encodingSampleKB;
    fontFamily = o.fontFamily;
    fontSize = o.fontSize;
    lineHeightPercent = o.lineHeightPercent;
    fontZoom = o.fontZoom;
    softWrapMode = o.softWrapMode;
    softWrapColumns = o.softWrapColumns;
    tabSize = o.tabSize;
    insertSpaces = o.insertSpaces;
    autoIndent = o.autoIndent;
    autoCloseBrackets = o.autoCloseBrackets;
    autoComplete = o.autoComplete;
    dragAndDrop = o.dragAndDrop;
    autoHexBinary = o.autoHexBinary;
    autoCompleteMinChars = o.autoCompleteMinChars;
    undoMaxSteps = o.undoMaxSteps;
    autoSave = o.autoSave;
    autoSaveDelaySec = o.autoSaveDelaySec;
    backupOnSave = o.backupOnSave;
    backupDir = o.backupDir;
    themeMode = o.themeMode;
    uiScale = o.uiScale;
    showSpaces = o.showSpaces;
    showTabs = o.showTabs;
    showNewlines = o.showNewlines;
    indentGuides = o.indentGuides;
    // systemIsDark is runtime state (the platform's brightness), not a user value — never copied
    // or reset, or "reset to defaults" would claim the OS is dark.
    dark = o.dark.copy();
    light = o.light.copy();
    keymap = o.keymap;
    locale = o.locale;
    logToFile = o.logToFile;
  }

  // ── Persistence ─────────────────────────────────────────────────────────────

  /// Absolute path of `<exe>/settings/settings.json`.
  static String get filePath => settingsPath(settingsFileName);

  /// Load `settings/settings.json` into this instance.
  ///
  /// Missing file → keep the defaults and write one out (so the user has something to edit).
  /// Unreadable / malformed file → keep the defaults and warn; individual bad values fall back to
  /// their default rather than failing the whole load.
  Future<void> load() async {
    final f = File(filePath);
    if (!await f.exists()) {
      settingsLog('settings: no $filePath yet, writing defaults');
      await save();
      return;
    }
    try {
      final map = jsonDecode(await f.readAsString(encoding: utf8));
      if (map is! Map) throw const FormatException('root is not an object');
      applyJson(map);
      settingsLog('settings loaded: ${f.path}');
    } catch (e) {
      settingsLog(
        'settings read failed, using defaults: ${f.path} ($e)',
        warn: true,
      );
      // Keep the unreadable file: the next save() writes defaults over
      // this path, which used to wipe the session, recent files, theme…
      // with nothing left to recover from (a half-written file after a
      // crash was enough). The user can diff/merge the copy back by hand.
      try {
        final t = DateTime.now().toIso8601String().replaceAll(':', '-');
        final keep = '${f.path}.corrupt-$t';
        await f.rename(keep);
        settingsLog('settings: unreadable file kept as $keep', warn: true);
      } catch (e2) {
        settingsLog('settings: could not keep unreadable file ($e2)', warn: true);
      }
    }
  }

  // Saves run one after another on this chain and go through a temp file +
  // rename. Two concurrent writeAsString calls (three files dropped at once
  // → three _touchRecent saves) interleaved their open/truncate/write steps
  // and could leave a truncated or garbled JSON; a crash mid-write did too.
  Future<void> _saveChain = Future<void>.value();

  /// Write the current values to `settings/settings.json` (UTF-8, no BOM,
  /// indented). Atomic (temp + rename) and serialized with other saves.
  Future<void> save() {
    final done = Completer<void>();
    _saveChain = _saveChain.then((_) async {
      try {
        await _saveNow();
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Future<void> _saveNow() async {
    final f = File(filePath);
    final tmp = File('${f.path}.tmp');
    try {
      await f.parent.create(recursive: true);
      await tmp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
        encoding: utf8,
        flush: true,
      );
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        // Windows: rename over an existing file fails → replace in two steps.
        if (await f.exists()) await f.delete();
        await tmp.rename(f.path);
      }
      settingsLog('settings saved: ${f.path}');
    } catch (e) {
      settingsLog('settings save failed: ${f.path} ($e)', warn: true);
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Map<String, Object?> toJson() => {
    'performance': {
      'wholeFileHighlightMaxMB': wholeFileHlMaxMB,
      'wholeFileHighlightDebounceMs': wholeFileHlDebounceMs,
      'autoIndexMaxMB': autoIndexMaxMB,
      'scriptWholeFileMaxMB': scriptWholeFileMaxMB,
      'encodingSampleKB': encodingSampleKB,
    },
    'font': {
      'family': fontFamily,
      'size': fontSize,
      'lineHeightPercent': lineHeightPercent,
      'zoom': fontZoom,
      'softWrapMode': softWrapMode,
      'softWrapColumns': softWrapColumns,
    },
    'appearance': {
      'themeMode': themeMode,
      'uiScale': uiScale,
      'showSpaces': showSpaces,
      'showTabs': showTabs,
      'showNewlines': showNewlines,
      'indentGuides': indentGuides,
    },
    'editing': {
      'tabSize': tabSize,
      'insertSpaces': insertSpaces,
      'autoIndent': autoIndent,
      'autoCloseBrackets': autoCloseBrackets,
      'autoComplete': autoComplete,
      'autoHexBinary': autoHexBinary,
      'dragAndDrop': dragAndDrop,
      'autoCompleteMinChars': autoCompleteMinChars,
      'undoMaxSteps': undoMaxSteps,
    },
    'backup': {
      'autoSave': autoSave,
      'autoSaveDelaySec': autoSaveDelaySec,
      'backupOnSave': backupOnSave,
      'backupDir': backupDir,
    },
    'themes': {'dark': dark.toJson(), 'light': light.toJson()},
    'startup': {'keymap': keymap, 'locale': locale, 'logToFile': logToFile},
    'recent': {'files': recentFiles},
    'explorer': {
      'open': explorerOpen,
      'width': explorerWidth,
      'root': explorerRoot,
    },
    'syntax': {'extensions': syntaxByExt},
    'dialogs': {
      'sizes': {
        for (final e in dialogSizes.entries) e.key: [e.value.$1, e.value.$2],
      },
    },
    'donation': {'hideButton': donateHidden},
    'session': {
      'window': {
        if (winX != null) 'x': winX,
        if (winY != null) 'y': winY,
        if (winW != null) 'w': winW,
        if (winH != null) 'h': winH,
        'maximized': winMaximized,
      },
      'layout': sessionLayout,
      'activeId': sessionActiveId,
      'files': [for (final f in sessionFiles) f.toJson()],
    },
  };

  /// Apply a decoded settings map; every value is range-checked and falls back to the default,
  /// so a hand-edited file with one bad entry still loads the rest.
  void applyJson(Map<Object?, Object?> map) {
    final d = AppSettings(); // defaults to fall back to
    final perf = _section(map['performance']);
    wholeFileHlMaxMB = _int(
      perf['wholeFileHighlightMaxMB'],
      d.wholeFileHlMaxMB,
      0,
      512,
    );
    wholeFileHlDebounceMs = _int(
      perf['wholeFileHighlightDebounceMs'],
      d.wholeFileHlDebounceMs,
      0,
      10000,
    );
    autoIndexMaxMB = _int(perf['autoIndexMaxMB'], d.autoIndexMaxMB, 0, 1 << 20);
    scriptWholeFileMaxMB = _int(
      perf['scriptWholeFileMaxMB'],
      d.scriptWholeFileMaxMB,
      0,
      2048,
    );
    encodingSampleKB = _int(
      perf['encodingSampleKB'],
      d.encodingSampleKB,
      1,
      8 << 10,
    );

    final font = _section(map['font']);
    fontFamily = font['family'] is String
        ? font['family'] as String
        : d.fontFamily;
    fontSize = _double(font['size'], d.fontSize, 4, 96);
    if (font['lineHeightPercent'] != null) {
      lineHeightPercent = _int(
        font['lineHeightPercent'],
        d.lineHeightPercent,
        lineHeightPercentMin,
        lineHeightPercentMax,
      );
    } else if (font['lineHeight'] is num) {
      // Pre-percentage file: pixels relative to the size it was saved with.
      final px = (font['lineHeight'] as num).toDouble();
      lineHeightPercent = (px / fontSize * 100).round().clamp(
        lineHeightPercentMin,
        lineHeightPercentMax,
      );
    } else {
      lineHeightPercent = d.lineHeightPercent;
    }
    fontZoom = _double(font['zoom'], d.fontZoom, fontZoomMin, fontZoomMax);
    softWrapColumns = _int(
      font['softWrapColumns'],
      d.softWrapColumns,
      0,
      100000,
    );
    // Old settings have no softWrapMode: derive it from the column count
    // (0 = no wrapping, anything else = by character count).
    softWrapMode = _choice(
      font['softWrapMode'],
      font.containsKey('softWrapColumns')
          ? (softWrapColumns <= 0 ? 'off' : 'columns')
          : d.softWrapMode,
      softWrapModeChoices,
    );

    themeMode = _choice(
      _section(map['appearance'])['themeMode'],
      d.themeMode,
      themeModeChoices,
    );
    uiScale = _double(
      _section(map['appearance'])['uiScale'],
      d.uiScale,
      uiScaleMin,
      uiScaleMax,
    );
    final appearance = _section(map['appearance']);
    // Pre-split files have a single showWhitespace: it seeds all three.
    final legacyWs = appearance['showWhitespace'] is bool
        ? appearance['showWhitespace'] as bool
        : null;
    bool wsFlag(String key, bool def) =>
        appearance[key] is bool ? appearance[key] as bool : (legacyWs ?? def);
    showSpaces = wsFlag('showSpaces', d.showSpaces);
    showTabs = wsFlag('showTabs', d.showTabs);
    showNewlines = wsFlag('showNewlines', d.showNewlines);
    indentGuides = appearance['indentGuides'] is bool
        ? appearance['indentGuides'] as bool
        : d.indentGuides;
    final editing = _section(map['editing']);
    tabSize = _int(editing['tabSize'], d.tabSize, tabSizeMin, tabSizeMax);
    insertSpaces = editing['insertSpaces'] is bool
        ? editing['insertSpaces'] as bool
        : d.insertSpaces;
    autoIndent = editing['autoIndent'] is bool
        ? editing['autoIndent'] as bool
        : d.autoIndent;
    autoCloseBrackets = editing['autoCloseBrackets'] is bool
        ? editing['autoCloseBrackets'] as bool
        : d.autoCloseBrackets;
    autoHexBinary = editing['autoHexBinary'] is bool
        ? editing['autoHexBinary'] as bool
        : d.autoHexBinary;
    autoComplete = editing['autoComplete'] is bool
        ? editing['autoComplete'] as bool
        : d.autoComplete;
    dragAndDrop = editing['dragAndDrop'] is bool
        ? editing['dragAndDrop'] as bool
        : d.dragAndDrop;
    autoCompleteMinChars = _int(
      editing['autoCompleteMinChars'],
      d.autoCompleteMinChars,
      autoCompleteMinCharsMin,
      autoCompleteMinCharsMax,
    );
    undoMaxSteps = _int(
      editing['undoMaxSteps'],
      d.undoMaxSteps,
      undoMaxStepsMin,
      undoMaxStepsMax,
    );

    final backup = _section(map['backup']);
    autoSave = autoSaveChoices.contains(backup['autoSave'])
        ? backup['autoSave'] as String
        : d.autoSave;
    autoSaveDelaySec = _int(
      backup['autoSaveDelaySec'],
      d.autoSaveDelaySec,
      autoSaveDelayMin,
      autoSaveDelayMax,
    );
    backupOnSave = backup['backupOnSave'] is bool
        ? backup['backupOnSave'] as bool
        : d.backupOnSave;
    backupDir = backup['backupDir'] is String
        ? backup['backupDir'] as String
        : d.backupDir;
    final themes = _section(map['themes']);
    dark = ThemeColors.dark()
      ..applyJson(_section(themes['dark']), ThemeColors.dark());
    light = ThemeColors.light()
      ..applyJson(_section(themes['light']), ThemeColors.light());
    if (!themes.containsKey('dark') && map['colors'] is Map) {
      // settings.json written before light/dark existed: its flat `colors` were the dark set.
      dark.applyLegacyEditorColors(map['colors']! as Map<Object?, Object?>);
    }

    final startup = _section(map['startup']);
    keymap = _choice(startup['keymap'], d.keymap, keymapChoices);
    // Settings written before the zh_TW rename stored 'zh-Hant'. Any
    // well-formed tag is kept: the language list is discovered from the .arb
    // files at startup (AppLocalizations.discover), not known here; a tag
    // with no file simply resolves to "follow the system".
    final rawLocale = startup['locale'] == 'zh-Hant'
        ? 'zh_TW'
        : startup['locale'];
    locale = rawLocale is String && isLocaleTag(rawLocale)
        ? rawLocale
        : d.locale;
    logToFile = startup['logToFile'] is bool
        ? startup['logToFile'] as bool
        : d.logToFile;

    final recent = _section(map['recent']);
    final recentRaw = recent['files'];
    recentFiles = recentRaw is List
        ? recentRaw.whereType<String>().take(recentFilesMax).toList()
        : <String>[];

    final donation = _section(map['donation']);
    donateHidden = donation['hideButton'] is bool
        ? donation['hideButton'] as bool
        : false;

    final explorer = _section(map['explorer']);
    explorerOpen = explorer['open'] is bool ? explorer['open'] as bool : false;
    explorerWidth = explorer['width'] is num
        ? (explorer['width'] as num).toDouble().clamp(
            explorerWidthMin,
            explorerWidthMax,
          )
        : 260;
    explorerRoot = explorer['root'] is String ? explorer['root'] as String : '';

    final syntax = _section(map['syntax']);
    final extsRaw = syntax['extensions'];
    syntaxByExt = {
      if (extsRaw is Map)
        for (final e in extsRaw.entries)
          if (e.key is String &&
              e.value is String &&
              (e.key as String).trim().isNotEmpty &&
              (e.value as String).trim().isNotEmpty)
            (e.key as String).trim().toLowerCase(): (e.value as String).trim(),
    };

    final sizesRaw = _section(map['dialogs'])['sizes'];
    dialogSizes = {
      if (sizesRaw is Map)
        for (final e in sizesRaw.entries)
          if (e.key is String &&
              e.value is List &&
              (e.value as List).length == 2 &&
              (e.value as List)[0] is num &&
              (e.value as List)[1] is num &&
              ((e.value as List)[0] as num) > 0 &&
              ((e.value as List)[1] as num) > 0)
            e.key as String: (
              ((e.value as List)[0] as num).toDouble(),
              ((e.value as List)[1] as num).toDouble(),
            ),
    };

    final session = _section(map['session']);
    final win = _section(session['window']);
    double? dim(Object? v) => v is num ? v.toDouble() : null;
    winX = dim(win['x']);
    winY = dim(win['y']);
    winW = dim(win['w']);
    winH = dim(win['h']);
    winMaximized = win['maximized'] is bool ? win['maximized'] as bool : false;
    sessionLayout = session['layout'] is String
        ? session['layout'] as String
        : '';
    sessionActiveId = _int(session['activeId'], -1, -1, 1 << 30);
    sessionFiles = [
      if (session['files'] is List)
        for (final v in session['files'] as List) ?SessionFile.fromJson(v),
    ];
  }
}

Map<Object?, Object?> _section(Object? v) => v is Map ? v : const {};

int _int(Object? v, int fallback, int min, int max) {
  final n = v is num ? v.toInt() : int.tryParse('$v');
  if (n == null) return fallback;
  return n < min ? min : (n > max ? max : n);
}

double _double(Object? v, double fallback, double min, double max) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  if (n == null) return fallback;
  return n < min ? min : (n > max ? max : n);
}

String _choice(Object? v, String fallback, List<String> allowed) =>
    v is String && allowed.contains(v) ? v : fallback;

int _color(Object? v, int fallback) => parseColor('$v') ?? fallback;

/// `#AARRGGBB` / `#RRGGBB` (with or without `#`) → ARGB int; null if unparseable.
/// 6 digits are treated as fully opaque.
int? parseColor(String s) {
  var t = s.trim();
  if (t.startsWith('#')) t = t.substring(1);
  if (t.length != 6 && t.length != 8) return null;
  final v = int.tryParse(t, radix: 16);
  if (v == null) return null;
  return t.length == 6 ? 0xFF000000 | v : v;
}

String _hex(int argb) =>
    '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Public formatter for the settings page's color fields.
String colorToHex(int argb) => _hex(argb);
