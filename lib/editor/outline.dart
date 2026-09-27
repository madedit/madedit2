// Document outline (View → Document Outline): symbols found by per-language regex
// rules from settings/outline.json (seeded from assets/outline.json), scanned
// line by line over the document in 1MB windows.
//
// Rules are data, not code (like highlight.json): a language lists its file
// extensions and patterns; the first pattern matching a line wins, the
// named group is the symbol, depth comes from indentation (or a group's
// length, for Markdown headings). Pure Dart, headless-testable
// (tool/outline_test.dart).

import 'dart:convert';

import 'document.dart';

class OutlinePattern {
  OutlinePattern({
    required this.regex,
    required this.kind,
    this.nameGroup = 1,
    this.depthFromGroup,
  });
  final RegExp regex;
  final String
  kind; // function / method / class / heading / variable / section / other
  final int nameGroup;
  final int? depthFromGroup;
}

class OutlineLanguage {
  const OutlineLanguage({
    required this.name,
    required this.extensions,
    required this.patterns,
    this.indentUnit = 4,
  });
  final String name;
  final List<String> extensions;
  final List<OutlinePattern> patterns;
  final int indentUnit;
}

class OutlineConfig {
  OutlineConfig({this.byName = const {}, this.byExtension = const {}});

  static OutlineConfig instance = OutlineConfig();

  final Map<String, OutlineLanguage> byName;
  final Map<String, OutlineLanguage> byExtension;

  OutlineLanguage? forExtension(String ext) => byExtension[ext.toLowerCase()];

  /// Language for a file path (by extension), null when none has rules.
  OutlineLanguage? forPath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return forExtension(name.substring(dot + 1));
  }

  /// Lenient parse: broken languages / patterns are skipped, never fatal.
  static OutlineConfig fromJsonString(String s) => fromJson(jsonDecode(s));

  /// As [fromJsonString], for a config that was already decoded (and possibly
  /// layered over the bundled defaults — see loadConfigJsonMerged).
  static OutlineConfig fromJson(Object? j) {
    final byName = <String, OutlineLanguage>{};
    final byExt = <String, OutlineLanguage>{};
    final langs = j is Map ? j['languages'] : null;
    if (langs is Map) {
      for (final e in langs.entries) {
        final name = e.key.toString();
        final v = e.value;
        if (v is! Map) continue;
        final pats = <OutlinePattern>[];
        final rawPats = v['patterns'];
        if (rawPats is List) {
          for (final p in rawPats) {
            if (p is! Map) continue;
            final re = p['regex'];
            if (re is! String || re.isEmpty) continue;
            try {
              pats.add(
                OutlinePattern(
                  regex: RegExp(
                    re,
                    caseSensitive: p['caseInsensitive'] != true,
                  ),
                  kind: p['kind'] is String ? p['kind'] as String : 'other',
                  nameGroup: p['nameGroup'] is int ? p['nameGroup'] as int : 1,
                  depthFromGroup: p['depthFromGroup'] is int
                      ? p['depthFromGroup'] as int
                      : null,
                ),
              );
            } catch (_) {
              // bad regex: skip the pattern
            }
          }
        }
        if (pats.isEmpty) continue;
        final exts = <String>[
          if (v['extensions'] is List)
            for (final x in v['extensions'] as List)
              if (x is String && x.isNotEmpty) x.toLowerCase(),
        ];
        final unit = v['indentUnit'];
        final lang = OutlineLanguage(
          name: name,
          extensions: exts,
          patterns: pats,
          indentUnit: unit is int && unit > 0 ? unit : 4,
        );
        byName[name] = lang;
        for (final x in exts) {
          byExt.putIfAbsent(x, () => lang);
        }
      }
    }
    return OutlineConfig(byName: byName, byExtension: byExt);
  }
}

class OutlineItem {
  const OutlineItem({
    required this.name,
    required this.kind,
    required this.depth,
    required this.offset,
    required this.line,
  });
  final String name;
  final String kind;
  final int depth;
  final int offset; // line-start byte offset
  final int line; // 0-based
}

class OutlineResult {
  const OutlineResult(this.items, {this.truncated = false});
  final List<OutlineItem> items;

  /// The scan stopped at the byte cap (huge file).
  final bool truncated;
}

const int outlineMaxBytes = 32 << 20;
const int outlineMaxItems = 20000;

/// Indentation depth of a line: leading spaces/tabs in columns (tab = 4)
/// divided by [unit].
int indentDepth(String line, int unit) {
  var cols = 0;
  for (var i = 0; i < line.length; i++) {
    final u = line.codeUnitAt(i);
    if (u == 0x20) {
      cols++;
    } else if (u == 0x09) {
      cols += 4 - cols % 4;
    } else {
      break;
    }
  }
  final d = cols ~/ unit;
  return d > 16 ? 16 : d;
}

/// Match one line against the language's patterns (first wins).
OutlineItem? matchLine(
  OutlineLanguage lang,
  String line, {
  int offset = 0,
  int lineNo = 0,
}) {
  if (line.isEmpty) return null;
  for (final p in lang.patterns) {
    final m = p.regex.firstMatch(line);
    if (m == null) continue;
    if (p.nameGroup > m.groupCount) continue;
    final name = (m.group(p.nameGroup) ?? '').trim();
    if (name.isEmpty) continue;
    int depth;
    final dg = p.depthFromGroup;
    if (dg != null && dg <= m.groupCount) {
      depth = (m.group(dg)?.length ?? 1) - 1;
      if (depth < 0) depth = 0;
    } else {
      depth = indentDepth(line, lang.indentUnit);
    }
    return OutlineItem(
      name: name.length > 200 ? name.substring(0, 200) : name,
      kind: p.kind,
      depth: depth,
      offset: offset,
      line: lineNo,
    );
  }
  return null;
}

/// Scan [doc] with [lang]'s rules. Chunked (1MB windows cut at a line
/// end), cooperative ([cancelled] polled per window), capped at [maxBytes].
Future<OutlineResult> scanOutline(
  Document doc,
  OutlineLanguage lang, {
  int maxBytes = outlineMaxBytes,
  int maxItems = outlineMaxItems,
  bool Function()? cancelled,
}) async {
  final items = <OutlineItem>[];
  final len = doc.length;
  final limit = len < maxBytes ? len : maxBytes;
  var pos = 0, lineNo = 0;
  const window = 1 << 20;
  while (pos < limit) {
    if (cancelled?.call() ?? false) break;
    var want = limit - pos;
    if (want > window) want = window;
    final d = await doc.readRangeDecoded(pos, want);
    final text = d.text;
    if (text.isEmpty) break;
    final last = pos + want >= limit;
    // Consume whole lines only (a partial tail line re-reads next window);
    // a single line longer than the window is scanned as-is.
    var end = text.length;
    if (!last) {
      final nl = text.lastIndexOf('\n');
      if (nl >= 0) end = nl + 1;
    }
    var ls = 0;
    while (ls < end) {
      var le = text.indexOf('\n', ls);
      if (le < 0 || le >= end) le = end;
      var ce = le;
      if (ce > ls && text.codeUnitAt(ce - 1) == 0x0D) ce--;
      final line = text.substring(ls, ce);
      final item = matchLine(
        lang,
        line,
        offset: pos + d.byteForCodeUnit(ls),
        lineNo: lineNo,
      );
      if (item != null) {
        items.add(item);
        if (items.length >= maxItems) {
          return OutlineResult(items, truncated: true);
        }
      }
      if (le < end) lineNo++;
      ls = le + 1;
      if (le == end) break;
    }
    final consumed = end >= text.length ? d.byteLength : d.byteForCodeUnit(end);
    if (consumed <= 0) break;
    pos += consumed;
  }
  return OutlineResult(items, truncated: limit < len);
}
