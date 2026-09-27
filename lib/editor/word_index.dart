// Word completion (Edit → Auto Complete, ctrl+space; also as you type): the
// candidate words come from the document itself — identifier-like runs
// collected in a chunked scan — plus the language's keywords.
//
// Pure Dart, headless-testable (tool/word_index_test.dart).

import 'document.dart';

/// Identifier characters: ASCII letters/digits/_, Latin-1 & extended
/// letters, Greek, Cyrillic, Hebrew and Arabic (letters AND their combining
/// vowel points / harakat, which sit inside the same blocks — a word must
/// not split at a diacritic). CJK ideographs are deliberately NOT word
/// characters (a run would swallow whole sentences); completion is for
/// identifiers.
bool isWordCodeUnit(int u) {
  if (u < 0x80) {
    return (u >= 0x30 && u <= 0x39) ||
        (u >= 0x41 && u <= 0x5A) ||
        (u >= 0x61 && u <= 0x7A) ||
        u == 0x5F;
  }
  if (u >= 0xC0 && u <= 0x24F) return u != 0xD7 && u != 0xF7;
  if (u >= 0x370 && u <= 0x52F) return true;
  if (u >= 0x590 && u <= 0x5FF) return true; // Hebrew
  if (u >= 0x600 && u <= 0x6FF) {
    // Arabic: letters, points, digits — but not the punctuation at the start
    // of the block (،؛؟) nor the tatweel-free separators.
    return !(u == 0x60C || u == 0x61B || u == 0x61F || u == 0x66A || u == 0x66B || u == 0x66C || u == 0x6D4);
  }
  if (u >= 0x750 && u <= 0x77F) return true; // Arabic Supplement
  if (u >= 0x8A0 && u <= 0x8FF) return true; // Arabic Extended-A
  if (u >= 0xFB50 && u <= 0xFDFF) return true; // presentation forms A
  if (u >= 0xFE70 && u <= 0xFEFF) return u != 0xFEFF; // presentation forms B (not the BOM)
  return false;
}

const int wordMinLen = 3;
const int wordMaxLen = 64;
const int wordIndexMaxBytes = 8 << 20;
const int wordIndexMaxWords = 50000;

/// Add every word of [text] to [into] (stops adding at [maxWords]).
void extractWords(
  String text,
  Set<String> into, {
  int minLen = wordMinLen,
  int maxLen = wordMaxLen,
  int maxWords = wordIndexMaxWords,
}) {
  var i = 0;
  final n = text.length;
  while (i < n) {
    if (!isWordCodeUnit(text.codeUnitAt(i))) {
      i++;
      continue;
    }
    final s = i;
    while (i < n && isWordCodeUnit(text.codeUnitAt(i))) {
      i++;
    }
    final len = i - s;
    if (len >= minLen && len <= maxLen) {
      final w = text.substring(s, i);
      // Pure numbers are not worth completing.
      if (!RegExp(r'^\d+$').hasMatch(w)) {
        into.add(w);
        if (into.length >= maxWords) return;
      }
    }
  }
}

/// The words of [doc] (its first [maxBytes]), chunked; [cancelled] is
/// polled per chunk. A word cut by a chunk boundary is re-read whole from
/// the next chunk.
Future<Set<String>> scanDocumentWords(
  Document doc, {
  int maxBytes = wordIndexMaxBytes,
  int maxWords = wordIndexMaxWords,
  bool Function()? cancelled,
}) async {
  final out = <String>{};
  final len = doc.length;
  final limit = len < maxBytes ? len : maxBytes;
  var pos = 0;
  const window = 1 << 20;
  while (pos < limit && out.length < maxWords) {
    if (cancelled?.call() ?? false) break;
    var want = limit - pos;
    if (want > window) want = window;
    final d = await doc.readRangeDecoded(pos, want);
    final t = d.text;
    if (t.isEmpty) break;
    final last = pos + want >= limit;
    var end = t.length;
    if (!last) {
      // Back off to the last non-word char so a split word is not indexed
      // as two halves; a chunk that is one giant word is taken as-is.
      var k = t.length;
      while (k > 0 && isWordCodeUnit(t.codeUnitAt(k - 1))) {
        k--;
      }
      if (k > 0) end = k;
    }
    extractWords(t.substring(0, end), out, maxWords: maxWords);
    final consumed = end >= t.length ? d.byteLength : d.byteForCodeUnit(end);
    if (consumed <= 0) break;
    pos += consumed;
  }
  return out;
}

/// The identifier characters immediately before [caretCu] in [text].
String wordPrefixBefore(String text, int caretCu) {
  var s = caretCu;
  while (s > 0 && isWordCodeUnit(text.codeUnitAt(s - 1))) {
    s--;
  }
  return text.substring(s, caretCu);
}

/// One candidate: the word and whether it is a language keyword.
class Completion {
  const Completion(this.word, {this.keyword = false});
  final String word;
  final bool keyword;
}

/// Candidates for [prefix]: words and keywords that start with it
/// (case-insensitive), the prefix itself excluded, exact-case matches
/// first, then shorter, then alphabetical; at most [max].
List<Completion> completionsFor(
  Iterable<String> words,
  String prefix, {
  Iterable<String> keywords = const [],
  int max = 12,
}) {
  if (prefix.isEmpty) return const [];
  final lp = prefix.toLowerCase();
  final seen = <String>{};
  final out = <Completion>[];
  void consider(String w, bool kw) {
    if (w == prefix || w.length <= prefix.length) return;
    if (!w.toLowerCase().startsWith(lp)) return;
    if (!seen.add(w)) return;
    out.add(Completion(w, keyword: kw));
  }

  for (final k in keywords) {
    consider(k, true);
  }
  for (final w in words) {
    consider(w, false);
  }
  int rank(Completion c) => c.word.startsWith(prefix) ? 0 : 1;
  out.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final l = a.word.length.compareTo(b.word.length);
    if (l != 0) return l;
    return a.word.compareTo(b.word);
  });
  return out.length > max ? out.sublist(0, max) : out;
}
