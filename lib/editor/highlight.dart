// Shared model and interfaces for syntax highlighting.
//
// All backends (pure-Dart lexer / Tree-sitter FFI) produce the same output:
// **a list of color spans per line**, which the view layer's RenderTextViewport
// draws via multiple pushStyle calls. Span coordinates are "in-line UTF-16
// character indices" (matching Dart String / ParagraphBuilder; the Tree-sitter
// backend is responsible for byte→UTF-16 conversion).

// Pure Dart (no dependency on Flutter / dart:ui), so it can be tested standalone
// with `dart run`; colors are represented as ARGB ints, converted to Color by
// the view layer.
//
// The lexer configuration (per-language keywords / comment markers / string
// rules, extension mapping, plain-text extensions) is data, not code: it lives
// in `settings/highlight.json` (bundled default: `assets/highlight.json`) and
// is parsed into [HighlightConfig] — main() loads it via config_loader; tests
// feed the JSON in directly. This file does no file/asset I/O itself.

import 'dart:convert';

/// A single color span within a line: [start, end) are in-line UTF-16 indices,
/// and [style] maps to a theme color.
class HlSpan {
  const HlSpan(this.start, this.end, this.style);
  final int start;
  final int end;
  final int style;
}

/// Semantic categories (style ids). Backends map tokens to these; the theme then
/// maps them to colors.
class Hl {
  static const int none = 0;
  static const int keyword = 1;
  static const int string = 2;
  static const int comment = 3;
  static const int number = 4;
  static const int type = 5;
  static const int function = 6;
  static const int constant = 7;
  static const int property = 8;
  static const int operator = 9;
  static const int punctuation = 10;
  // Markdown-specific (color-only: bold/italic currently only get a color, no
  // font weight/style applied).
  static const int heading = 11; // heading (text.title / markup.heading)
  static const int link =
      12; // link / URL (text.uri / text.reference / markup.link)
  static const int emphasis = 13; // italic (text.emphasis / markup.italic)
  static const int strong = 14; // bold (text.strong / markup.strong)
  static const int raw =
      15; // inline code / code block (text.literal / markup.raw)
  // diff
  static const int diffAdd = 16; // added line (diff.plus)
  static const int diffDel = 17; // removed line (diff.minus)
}

/// Default dark theme (VS Code Dark style): style id → ARGB color. Anything not
/// listed uses the foreground color.
const Map<int, int> defaultHlTheme = {
  Hl.keyword: 0xFF569CD6,
  Hl.string: 0xFFCE9178,
  Hl.comment: 0xFF6A9955,
  Hl.number: 0xFFB5CEA8,
  Hl.type: 0xFF4EC9B0,
  Hl.function: 0xFFDCDCAA,
  Hl.constant: 0xFF4FC1FF,
  Hl.property: 0xFF9CDCFE,
  Hl.operator: 0xFFD4D4D4,
  Hl.punctuation: 0xFFD4D4D4,
  // Markdown
  Hl.heading: 0xFF569CD6, // blue (heading)
  Hl.link: 0xFF3794FF, // link blue (same as VS Code link)
  Hl.emphasis: 0xFFC586C0, // purple (italic)
  Hl.strong: 0xFFE5C07B, // gold (bold)
  Hl.raw: 0xFFCE9178, // orange (code, same as string)
  // diff
  Hl.diffAdd: 0xFF89D185, // green (added)
  Hl.diffDel: 0xFFF14C4C, // red (removed)
};

/// Default light theme (VS Code Light+ style), the counterpart of [defaultHlTheme].
const Map<int, int> defaultHlThemeLight = {
  Hl.keyword: 0xFF0000FF,
  Hl.string: 0xFFA31515,
  Hl.comment: 0xFF008000,
  Hl.number: 0xFF098658,
  Hl.type: 0xFF267F99,
  Hl.function: 0xFF795E26,
  Hl.constant: 0xFF0070C1,
  Hl.property: 0xFF001080,
  Hl.operator: 0xFF000000,
  Hl.punctuation: 0xFF000000,
  // Markdown
  Hl.heading: 0xFF800000,
  Hl.link: 0xFF0000EE,
  Hl.emphasis: 0xFF800080,
  Hl.strong: 0xFF7A3E00,
  Hl.raw: 0xFFA31515,
  // diff
  Hl.diffAdd: 0xFF107C10,
  Hl.diffDel: 0xFFCD3131,
};

/// Stable key for each style id, used by settings.json and the color settings page. The order here
/// is the order the settings page lists them in.
const Map<int, String> hlStyleKeys = {
  Hl.keyword: 'keyword',
  Hl.string: 'string',
  Hl.comment: 'comment',
  Hl.number: 'number',
  Hl.type: 'type',
  Hl.function: 'function',
  Hl.constant: 'constant',
  Hl.property: 'property',
  Hl.operator: 'operator',
  Hl.punctuation: 'punctuation',
  Hl.heading: 'heading',
  Hl.link: 'link',
  Hl.emphasis: 'emphasis',
  Hl.strong: 'strong',
  Hl.raw: 'raw',
  Hl.diffAdd: 'diffAdd',
  Hl.diffDel: 'diffDel',
};

/// Highlighter interface: given a batch of "visible lines", return the color
/// spans for each line (aligned with [lines]).
///
/// Only the passed-in window is processed (cheap for GB-sized files); the cost is
/// that multi-line structures spanning past the top of the window (e.g. a block
/// comment that began above) can't be known — the pure-Dart backend carries state
/// line-by-line within the window, while the Tree-sitter backend window-parses.
/// False when `RustLib.init()` failed at startup (see main.dart): the
/// tree-sitter/WASM highlighters and the script engines live in the native
/// library, so the editor must not construct them and falls back to the
/// pure-Dart lexer. Set once, before the first frame.
bool nativeBackendAvailable = true;

abstract class Highlighter {
  List<List<HlSpan>> highlight(List<String> lines);

  /// Short human-readable description of which backend/grammar this is, for logging (e.g. which
  /// syntax a file ended up being highlighted with).
  String get description;

  /// Same result as [highlight], but allowed to do the work off the UI thread.
  ///
  /// Used for whole-file highlighting, where the batch is the entire file and a synchronous call
  /// would freeze the UI for seconds. Backends without an off-thread path just return the
  /// synchronous result.
  Future<List<List<HlSpan>>> highlightAsync(List<String> lines) async =>
      highlight(lines);

  /// An incremental whole-file session, or null when this backend can only re-highlight from
  /// scratch. The caller opens it with the whole file, then feeds line replacements and patches
  /// its cached spans with what comes back.
  HlSession? createSession() => null;
}

/// Lines re-highlighted by an [HlSession.edit]: `lines[i]` are the spans of line `start + i`
/// (new numbering).
class HlPatch {
  const HlPatch(this.start, this.lines);
  final int start;
  final List<List<HlSpan>> lines;
  int get end => start + lines.length;
}

/// Reads lines `[start, end)` of the document (current content) for a session that must look
/// beyond the edited lines.
typedef HlLineReader = Future<List<String>> Function(int start, int end);

/// Incremental whole-file highlighting: the backend keeps whatever state it needs (text, syntax
/// tree, per-line lexer state) so an edit costs work proportional to the change, not the file.
abstract class HlSession {
  /// Highlight the whole file once and remember it. Null = backend unavailable.
  Future<List<List<HlSpan>>?> open(List<String> lines);

  /// Replace lines `[start, oldEnd)` (numbering as of the previous call) with [newLines] and
  /// return the lines whose spans changed. Null = the session is gone (caller reopens). Calls on
  /// one session must not overlap. [read] fetches further current lines when the change
  /// cascades past [newLines] (e.g. an unclosed block comment).
  Future<HlPatch?> edit(
    int start,
    int oldEnd,
    List<String> newLines,
    HlLineReader read,
  );

  /// Foldable regions from the backend's syntax tree (current numbering);
  /// null = this backend has no tree (pure-Dart lexer).
  Future<List<FoldRange>?> folds();

  void close();
}

/// A foldable region: rows `startRow + 1 ..= endRow` hide when collapsed.
class FoldRange {
  const FoldRange(this.startRow, this.endRow);
  final int startRow;
  final int endRow;
}

/// No highlighting (everything in the foreground color).
class NoHighlighter implements Highlighter {
  const NoHighlighter();

  @override
  String get description => 'no highlighting (plain text)';

  @override
  List<List<HlSpan>> highlight(List<String> lines) =>
      List.generate(lines.length, (_) => const <HlSpan>[]);

  @override
  Future<List<List<HlSpan>>> highlightAsync(List<String> lines) async =>
      highlight(lines);

  @override
  HlSession? createSession() => null;
}

/// Lexical configuration for one language.
class LangConfig {
  const LangConfig({
    required this.keywords,
    this.types = const {},
    this.constants = const {},
    this.lineComment = '//',
    this.hashComment = false,
    this.blockComment = true,
    this.backtickString = false,
  });

  final Set<String> keywords;
  final Set<String> types;
  final Set<String> constants;
  final String lineComment; // line-comment prefix (// for the C family)
  final bool
  hashComment; // whether # line comments are also supported (py/sh/yaml…)
  final bool blockComment; // whether /* */ is supported
  final bool
  backtickString; // whether backtick strings are supported (js templates)

  /// Tolerant parse: missing / wrongly typed fields keep their default, so one
  /// bad entry in a hand-edited highlight.json can't break the language.
  factory LangConfig.fromJson(Map<Object?, Object?> json) {
    Set<String> strs(Object? v) => {
      if (v is List)
        for (final e in v)
          if (e is String) e,
    };
    return LangConfig(
      keywords: strs(json['keywords']),
      types: strs(json['types']),
      constants: strs(json['constants']),
      lineComment: json['lineComment'] is String
          ? json['lineComment'] as String
          : '//',
      hashComment: json['hashComment'] == true,
      blockComment: json['blockComment'] is bool
          ? json['blockComment'] as bool
          : true,
      backtickString: json['backtickString'] == true,
    );
  }
}

/// The whole lexer configuration from highlight.json: plain-text extensions,
/// extension → [LangConfig], and the fallback config for unknown extensions.
///
/// [instance] starts empty (bare generic lexer, no keywords) and is replaced by
/// main() with the parsed settings/highlight.json — this file stays free of
/// file/asset I/O so it remains headless-testable.
class HighlightConfig {
  HighlightConfig({
    this.plainExtensions = const {},
    this.byExtension = const {},
    this.fallback = const LangConfig(keywords: {}),
  });

  static HighlightConfig instance = HighlightConfig();

  /// Extensions that get no highlighting at all (txt/log/…).
  final Set<String> plainExtensions;

  /// Lowercased extension → its language config.
  final Map<String, LangConfig> byExtension;

  /// Config for extensions not listed (the JSON's "default" entry).
  final LangConfig fallback;

  LangConfig forExt(String ext) => byExtension[ext.toLowerCase()] ?? fallback;

  factory HighlightConfig.fromJsonString(String s) =>
      HighlightConfig.fromJson(jsonDecode(s) as Map<Object?, Object?>);

  /// Tolerant parse: malformed language entries are skipped, not fatal.
  factory HighlightConfig.fromJson(Map<Object?, Object?> json) {
    final plain = <String>{
      if (json['plainExtensions'] is List)
        for (final e in json['plainExtensions'] as List)
          if (e is String) e.toLowerCase(),
    };
    final fallback = json['default'] is Map
        ? LangConfig.fromJson(json['default'] as Map<Object?, Object?>)
        : const LangConfig(keywords: {});
    final byExt = <String, LangConfig>{};
    if (json['languages'] is List) {
      for (final lang in json['languages'] as List) {
        if (lang is! Map) continue;
        final exts = lang['extensions'];
        if (exts is! List) continue;
        final cfg = LangConfig.fromJson(lang.cast<Object?, Object?>());
        for (final e in exts) {
          if (e is String) byExt[e.toLowerCase()] = cfg;
        }
      }
    }
    return HighlightConfig(
      plainExtensions: plain,
      byExtension: byExt,
      fallback: fallback,
    );
  }
}

/// Pure-Dart generic lexical highlighter: keywords / strings / comments (line +
/// block) / numbers / function calls.
///
/// Carries the [_inBlock] state line-by-line within the window (a block comment
/// may span multiple lines inside the window); strings are bounded to a single
/// line (they don't span lines).
class SimpleHighlighter implements Highlighter {
  SimpleHighlighter(this.cfg, {this.label = ''});
  final LangConfig cfg;

  /// What the config was picked for (a file extension), for [description] only.
  final String label;

  /// Pick a config by file extension from [HighlightConfig.instance].
  factory SimpleHighlighter.forExtension(String ext) => SimpleHighlighter(
    HighlightConfig.instance.forExt(ext),
    label: ext.toLowerCase(),
  );

  bool _inBlock =
      false; // whether inside a multi-line block comment (carried line-by-line while highlighting a window)

  /// Lex one line given the lexer state at its start ([inBlock] = inside a block comment) and
  /// return the spans plus the state after it — the unit the incremental session works in.
  (List<HlSpan>, bool) lexLine(String line, bool inBlock) {
    _inBlock = inBlock;
    final spans = _line(line);
    return (spans, _inBlock);
  }

  @override
  HlSession? createSession() =>
      SimpleHlSession(SimpleHighlighter(cfg, label: label));

  @override
  String get description => label.isEmpty
      ? 'pure-Dart lexical highlighting'
      : 'pure-Dart lexical highlighting (.$label)';

  @override
  List<List<HlSpan>> highlight(List<String> lines) {
    _inBlock = false;
    return [for (final line in lines) _line(line)];
  }

  @override
  Future<List<List<HlSpan>>> highlightAsync(List<String> lines) async =>
      highlight(lines);

  List<HlSpan> _line(String line) {
    final spans = <HlSpan>[];
    final n = line.length;
    var i = 0;
    while (i < n) {
      if (_inBlock) {
        final end = line.indexOf('*/', i);
        if (end < 0) {
          spans.add(HlSpan(i, n, Hl.comment));
          return spans;
        }
        spans.add(HlSpan(i, end + 2, Hl.comment));
        i = end + 2;
        _inBlock = false;
        continue;
      }
      final c = line[i];
      if (c == ' ' || c == '\t') {
        i++;
        continue;
      }
      // line comment
      if (line.startsWith(cfg.lineComment, i) ||
          (cfg.hashComment && c == '#')) {
        spans.add(HlSpan(i, n, Hl.comment));
        return spans;
      }
      // block comment
      if (cfg.blockComment && line.startsWith('/*', i)) {
        final end = line.indexOf('*/', i + 2);
        if (end < 0) {
          spans.add(HlSpan(i, n, Hl.comment));
          _inBlock = true;
          return spans;
        }
        spans.add(HlSpan(i, end + 2, Hl.comment));
        i = end + 2;
        continue;
      }
      // string
      if (c == '"' || c == "'" || (cfg.backtickString && c == '`')) {
        final j = _scanString(line, i, c);
        spans.add(HlSpan(i, j, Hl.string));
        i = j;
        continue;
      }
      // number
      if (_isDigit(c)) {
        final j = _scanNumber(line, i);
        spans.add(HlSpan(i, j, Hl.number));
        i = j;
        continue;
      }
      // identifier / keyword / function call
      if (_isIdentStart(c)) {
        final j = _scanIdent(line, i);
        final w = line.substring(i, j);
        int style;
        if (cfg.keywords.contains(w)) {
          style = Hl.keyword;
        } else if (cfg.types.contains(w)) {
          style = Hl.type;
        } else if (cfg.constants.contains(w)) {
          style = Hl.constant;
        } else if (_isCall(line, j)) {
          style = Hl.function;
        } else {
          style = Hl.none;
        }
        if (style != Hl.none) spans.add(HlSpan(i, j, style));
        i = j;
        continue;
      }
      i++; // any other symbol → default color
    }
    return spans;
  }

  int _scanString(String s, int i, String quote) {
    var j = i + 1;
    while (j < s.length) {
      if (s[j] == '\\') {
        j += 2;
        continue;
      }
      if (s[j] == quote) return j + 1;
      j++;
    }
    return s.length; // unterminated → to end of line
  }

  int _scanNumber(String s, int i) {
    var j = i;
    while (j < s.length && _isNumberChar(s[j])) {
      j++;
    }
    return j;
  }

  int _scanIdent(String s, int i) {
    var j = i;
    while (j < s.length && _isIdentChar(s[j])) {
      j++;
    }
    return j;
  }

  bool _isCall(String s, int j) {
    var k = j;
    while (k < s.length && (s[k] == ' ' || s[k] == '\t')) {
      k++;
    }
    return k < s.length && s[k] == '(';
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isNumberChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 48 && u <= 57) || // 0-9
        (u >= 97 && u <= 102) || // a-f
        (u >= 65 && u <= 70) || // A-F
        c == '.' ||
        c == 'x' ||
        c == 'X' ||
        c == '_';
  }

  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 97 && u <= 122) ||
        (u >= 65 && u <= 90) ||
        c == '_' ||
        c == r'$';
  }

  static bool _isIdentChar(String c) => _isIdentStart(c) || _isDigit(c);
}

/// Pick a highlighter by file extension (no extension / plain text → no
/// highlighting). Extension mapping comes from [HighlightConfig.instance].
Highlighter highlighterForPath(String? path) {
  if (path == null) return const NoHighlighter();
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return const NoHighlighter();
  final ext = path.substring(dot + 1).toLowerCase();
  if (HighlightConfig.instance.plainExtensions.contains(ext)) {
    return const NoHighlighter();
  }
  return SimpleHighlighter.forExtension(ext);
}

/// Incremental session for [SimpleHighlighter]. The only state the lexer carries between lines
/// is "inside a block comment", so an edit re-lexes the replaced lines from the state at their
/// start and keeps going only while the state entering the next untouched line differs from what
/// it was — the usual line-lexer cascade (an opened `/*` recolors everything down to its `*/`).
class SimpleHlSession implements HlSession {
  SimpleHlSession(this._lexer);

  final SimpleHighlighter _lexer;

  @override
  Future<List<FoldRange>?> folds() async => null; // no syntax tree

  // _state[i] = inBlock at the start of line i; one extra trailing entry = the state after the
  // last line (what an appended line would start in).
  List<bool> _state = [];
  bool _open = false;

  @override
  Future<List<List<HlSpan>>?> open(List<String> lines) async {
    final out = <List<HlSpan>>[];
    final st = List<bool>.filled(lines.length + 1, false, growable: true);
    var s = false;
    for (var i = 0; i < lines.length; i++) {
      st[i] = s;
      final (spans, next) = _lexer.lexLine(lines[i], s);
      out.add(spans);
      s = next;
    }
    st[lines.length] = s;
    _state = st;
    _open = true;
    return out;
  }

  @override
  Future<HlPatch?> edit(
    int start,
    int oldEnd,
    List<String> newLines,
    HlLineReader read,
  ) async {
    if (!_open) return null;
    final oldCount = _state.length - 1;
    if (start > oldEnd || oldEnd > oldCount) return null;
    var s = _state[start];
    final out = <List<HlSpan>>[];
    final newStates = <bool>[];
    for (final line in newLines) {
      newStates.add(s);
      final (spans, next) = _lexer.lexLine(line, s);
      out.add(spans);
      s = next;
    }
    _state.replaceRange(start, oldEnd, newStates);
    final count = _state.length - 1;
    // Cascade past the edit while the state entering the next line changed.
    var k = start + newLines.length;
    while (k < count && _state[k] != s) {
      final batchEnd = k + 256 < count ? k + 256 : count;
      final lines = await read(k, batchEnd);
      if (lines.length != batchEnd - k) {
        return null; // document moved underneath → reopen
      }
      var settled = false;
      for (final line in lines) {
        if (_state[k] == s) {
          settled = true;
          break;
        }
        _state[k] = s;
        final (spans, next) = _lexer.lexLine(line, s);
        out.add(spans);
        s = next;
        k++;
      }
      if (settled) break;
    }
    if (k == count) _state[count] = s;
    return HlPatch(start, out);
  }

  @override
  void close() {
    _open = false;
    _state = [];
  }
}
