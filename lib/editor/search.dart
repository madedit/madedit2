// Chunked text search over a Document.
//
// GB-scale files can never be decoded whole, so the search walks fixed
// windows (core [searchChunk] + [searchOverlap] lookahead) and maps match
// positions back to byte offsets through the decode map — never by
// re-encoding, which drifts on U+FFFD and decode-only code points.
//
// Window boundaries are handled so that matches are not lost there (see
// [scanSearchWindow]): the core is cut at a line end, a literal query gets a
// lookahead that fits it whole, and a match reaching the decoded end grows
// the window. What remains: a regex match that spans lines AND a >16MB line
// (the window cap), or a >16MB single line — the price of bounded memory.
//
// Pure Dart, no flutter imports (headless-testable).

import 'dart:math';
import 'dart:typed_data';

import 'document.dart';
import 'encoding/text_codec.dart' show DecodedText;

/// A hit, as byte offsets into the document ([start] inclusive, [end]
/// exclusive) — ready to become the selection. [groups] holds the regex
/// capture texts (index 0 = whole match) for replacement expansion.
class SearchMatch {
  const SearchMatch(this.start, this.end, [this.groups = const []]);

  final int start;
  final int end;
  final List<String?> groups;
}

/// Expand a replacement template against a match's [groups]: in regex mode
/// `$0`–`$9` insert the capture (empty when absent) and `$$` a literal `$`;
/// literal mode returns the template untouched.
String expandReplacement(
  String template,
  List<String?> groups, {
  required bool regex,
}) {
  if (!regex || !template.contains(r'$')) return template;
  final sb = StringBuffer();
  for (var i = 0; i < template.length; i++) {
    final c = template[i];
    if (c == r'$' && i + 1 < template.length) {
      final n = template.codeUnitAt(i + 1);
      if (n == 0x24) {
        sb.write(r'$');
        i++;
        continue;
      }
      if (n >= 0x30 && n <= 0x39) {
        final g = n - 0x30;
        if (g < groups.length) sb.write(groups[g] ?? '');
        i++;
        continue;
      }
    }
    sb.write(c);
  }
  return sb.toString();
}

List<String?> _groupsOf(Match m) =>
    List<String?>.generate(m.groupCount + 1, m.group);

/// Compile the find-bar query: literal text is escaped so one code path
/// serves both modes. Throws [FormatException] on a bad regex pattern.
/// multiLine so `^`/`$` anchor to line boundaries, the way find bars do.
RegExp compileQuery(
  String pattern, {
  required bool regex,
  required bool caseSensitive,
  bool wholeWord = false,
}) {
  final body = regex ? pattern : RegExp.escape(pattern);
  // Whole word = not touching a word character on either side. Dart's \b is
  // ASCII-only and the unicode flag would change how the user's own pattern
  // is parsed, so the class is spelled out: ASCII identifier chars plus the
  // Latin-extended, Greek, Cyrillic, Hebrew, Arabic (with its supplement,
  // extended-A and presentation-form blocks), CJK, kana and Hangul blocks.
  const w =
      r'[A-Za-z0-9_À-ɏͰ-ϿЀ-ӿ'
      r'֐-׿؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻾'
      r'぀-ヿ㐀-䶿一-鿿가-힯]';
  return RegExp(
    wholeWord ? '(?<!$w)(?:$body)(?!$w)' : body,
    caseSensitive: caseSensitive,
    multiLine: true,
  );
}

const int searchChunk = 1 << 20;
const int searchOverlap = 64 << 10;

/// Largest window one scan may grow to while looking for a line end or
/// completing a match that reaches the decoded end (see [scanSearchWindow]).
const int searchWindowCap = 16 << 20;

/// Lookahead past the core for [re]: at least [searchOverlap], and enough for
/// a literal query of any length — the escaped pattern is at least as long
/// as the literal, and 4 bytes per code unit covers every codec — capped so
/// the window stays under [searchWindowCap].
int searchOverlapFor(RegExp re) {
  final want = max(searchOverlap, re.pattern.length * 4 + 16);
  return min(want, searchWindowCap - searchChunk);
}

int _bytesOverlapFor(List<int?> pat) =>
    min(max(searchOverlap, pat.length), searchWindowCap - searchChunk);

/// One decoded, scanned search window (forward direction).
class SearchWindow {
  const SearchWindow(this.text, this.matches, this.cutCu, this.atEnd);

  final DecodedText text;

  /// Non-empty matches in order. Those starting at or past [cutCu] belong to
  /// the next window (unless [atEnd]).
  final List<RegExpMatch> matches;

  /// Code-unit index where this window's core ends; the next window starts
  /// at its byte offset.
  final int cutCu;

  /// The window reaches EOF (every match is final).
  final bool atEnd;
}

/// Decode and scan the window at [pos]. Three rules keep boundary matches
/// from being lost:
///  * the core is cut at a line end in the window's second half, growing the
///    window (up to [searchWindowCap]) until one is found, so a match on one
///    line never straddles the cut — only a >cap line meets a fixed cut;
///  * the lookahead fits any literal query whole ([searchOverlapFor]);
///  * a match reaching the decoded end may have been truncated (the regex saw
///    only part of it), so the window is re-read doubled until it ends inside.
Future<SearchWindow> scanSearchWindow(
  Document doc,
  RegExp re,
  int pos, {
  int? overlap,
}) async {
  final len = doc.length;
  var winLen = min(searchChunk + (overlap ?? searchOverlapFor(re)), len - pos);
  while (true) {
    final d = await doc.readRangeDecoded(pos, winLen);
    final text = d.text;
    final atEnd = pos + winLen >= len;
    final ms = [
      for (final m in re.allMatches(text))
        if (m.end > m.start) m, // empty match: useless and loop-prone
    ];
    final canGrow = !atEnd && winLen < searchWindowCap;
    int cut;
    if (atEnd) {
      cut = text.length;
    } else {
      final nl = text.lastIndexOf('\n');
      if (nl >= 0 && d.byteForCodeUnit(nl + 1) >= searchChunk ~/ 2) {
        cut = nl + 1;
      } else if (canGrow) {
        winLen = min(winLen * 2, len - pos);
        continue;
      } else {
        cut = d.codeUnitForByte(searchChunk);
      }
    }
    if (canGrow && ms.any((m) => m.start < cut && m.end == text.length)) {
      winLen = min(winLen * 2, len - pos);
      continue;
    }
    return SearchWindow(d, ms, cut, atEnd);
  }
}

/// First match starting at or after byte [from]; null when none before EOF.
Future<SearchMatch?> searchForward(Document doc, RegExp re, int from) async {
  final len = doc.length;
  final overlap = searchOverlapFor(re);
  var pos = from < 0 ? 0 : from;
  while (pos < len) {
    final w = await scanSearchWindow(doc, re, pos, overlap: overlap);
    final d = w.text;
    for (final m in w.matches) {
      if (!w.atEnd && m.start >= w.cutCu) break;
      final sb = pos + d.byteForCodeUnit(m.start);
      final eb = pos + d.byteForCodeUnit(m.end);
      if (eb > sb) return SearchMatch(sb, eb, _groupsOf(m));
    }
    if (w.atEnd) break;
    pos += d.byteForCodeUnit(w.cutCu);
  }
  return null;
}

/// Last match ending at or before byte [before]; null when none after BOF.
///
/// Windows step backward by a core each; matches starting before a window's
/// first line start belong to the previous (earlier) window, which reaches
/// past them, and a match reaching a window's decoded end grows it like the
/// forward scan does.
Future<SearchMatch?> searchBackward(Document doc, RegExp re, int before) async {
  final len = doc.length;
  final overlap = searchOverlapFor(re);
  final limit = before > len ? len : before;
  var end = limit;
  while (true) {
    final pos = max(0, end - searchChunk);
    var winLen = min(searchChunk + overlap, len - pos);
    DecodedText d;
    List<RegExpMatch> ms;
    while (true) {
      d = await doc.readRangeDecoded(pos, winLen);
      final text = d.text;
      ms = [
        for (final m in re.allMatches(text))
          if (m.end > m.start) m,
      ];
      final canGrow = pos + winLen < len && winLen < searchWindowCap;
      if (canGrow &&
          ms.any(
            (m) =>
                m.end == text.length && pos + d.byteForCodeUnit(m.end) <= limit,
          )) {
        winLen = min(winLen * 2, len - pos);
        continue;
      }
      break;
    }
    // Line alignment at the start: skip matches on the line that began before
    // this window when the previous window's lookahead covers that line.
    var floorCu = 0;
    if (pos > 0) {
      final nl = d.text.indexOf('\n');
      if (nl >= 0 && d.byteForCodeUnit(nl + 1) <= overlap) floorCu = nl + 1;
    }
    SearchMatch? best;
    for (final m in ms) {
      if (m.start < floorCu) continue;
      final sb = pos + d.byteForCodeUnit(m.start);
      final eb = pos + d.byteForCodeUnit(m.end);
      if (eb > limit) break; // past the boundary → not "before"
      if (eb > sb) best = SearchMatch(sb, eb, _groupsOf(m));
    }
    if (best != null) return best;
    if (pos == 0) return null;
    end =
        pos +
        d.byteForCodeUnit(
          floorCu,
        ); // strictly decreases (floor ≤ overlap < chunk)
  }
}

// ── Byte-sequence search (hex mode) ───────────────────────────────────────

/// Parse a hex byte pattern into byte values, `null` = any byte (`??`).
/// Accepted forms, freely mixed: `FF 00 A1`, `ff00a1`, `0xFF,0x00`,
/// `FF ?? A1`. Separators are whitespace, `,`, `:`, `;`, `-`, `_`. Each token
/// (after an optional `0x`) must be an even run of hex digits / `??` pairs; a
/// lone hex digit is taken as one byte. Throws [FormatException] otherwise.
List<int?> parseHexPattern(String s) {
  final out = <int?>[];
  for (var tok in s.split(RegExp(r'[\s,:;\-_]+'))) {
    if (tok.isEmpty) continue;
    if (tok.length > 2 && (tok.startsWith('0x') || tok.startsWith('0X'))) {
      tok = tok.substring(2);
    }
    if (tok.length == 1) {
      final v = int.tryParse(tok, radix: 16);
      if (v == null) throw FormatException('bad hex byte: $tok');
      out.add(v);
      continue;
    }
    if (tok.length.isOdd) throw FormatException('odd hex digit count: $tok');
    for (var i = 0; i < tok.length; i += 2) {
      final pair = tok.substring(i, i + 2);
      if (pair == '??') {
        out.add(null);
        continue;
      }
      final v = int.tryParse(pair, radix: 16);
      if (v == null) throw FormatException('bad hex byte: $pair');
      out.add(v);
    }
  }
  return out;
}

/// `FF 00 A1` rendering of [bytes] (the search-bar seed for a byte selection).
String formatHexBytes(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Parse a go-to-offset entry: decimal by default, hex with a `0x` prefix
/// or an `h` suffix (`0x1F`, `1Fh`, `31`). null when malformed or negative.
int? parseOffsetInput(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('0x') || t.startsWith('0X')) {
    return int.tryParse(t.substring(2), radix: 16);
  }
  if (t.endsWith('h') || t.endsWith('H')) {
    t = t.substring(0, t.length - 1);
    return t.isEmpty ? null : int.tryParse(t, radix: 16);
  }
  final v = int.tryParse(t);
  return v == null || v < 0 ? null : v;
}

bool _bytesMatchAt(Uint8List buf, int at, List<int?> pat) {
  for (var j = 0; j < pat.length; j++) {
    final p = pat[j];
    if (p != null && buf[at + j] != p) return false;
  }
  return true;
}

/// First occurrence of byte pattern [pat] starting at or after [from]; same
/// chunk/overlap scheme as the text search, with the lookahead at least the
/// pattern's length so a match starting in the core always fits. An empty
/// pattern never matches.
Future<SearchMatch?> searchBytesForward(
  Document doc,
  List<int?> pat,
  int from,
) async {
  if (pat.isEmpty) return null;
  final len = doc.length;
  final overlap = _bytesOverlapFor(pat);
  var pos = from < 0 ? 0 : from;
  while (pos < len) {
    final readLen = min(searchChunk + overlap, len - pos);
    final buf = await doc.readRangeBytes(pos, readLen);
    final lastChunk = pos + readLen >= len;
    final stop = lastChunk ? buf.length - pat.length : searchChunk - 1;
    for (var i = 0; i <= stop && i + pat.length <= buf.length; i++) {
      if (_bytesMatchAt(buf, i, pat)) {
        return SearchMatch(pos + i, pos + i + pat.length);
      }
    }
    if (lastChunk) break;
    pos += searchChunk;
  }
  return null;
}

/// Last occurrence of [pat] ending at or before [before]; null when none.
Future<SearchMatch?> searchBytesBackward(
  Document doc,
  List<int?> pat,
  int before,
) async {
  if (pat.isEmpty) return null;
  final len = doc.length;
  final overlap = _bytesOverlapFor(pat);
  final limit = before > len ? len : before;
  var pos = limit - searchChunk;
  if (pos < 0) pos = 0;
  while (true) {
    final readLen = min(searchChunk + overlap, len - pos);
    final buf = await doc.readRangeBytes(pos, readLen);
    // Latest start whose end stays within [limit].
    var i = min(buf.length, limit - pos) - pat.length;
    for (; i >= 0; i--) {
      if (_bytesMatchAt(buf, i, pat)) {
        return SearchMatch(pos + i, pos + i + pat.length);
      }
    }
    if (pos == 0) return null;
    pos -= searchChunk;
    if (pos < 0) pos = 0;
  }
}
