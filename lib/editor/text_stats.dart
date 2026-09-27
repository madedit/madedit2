// Word-count statistics (View → Word Count…): a streaming accumulator fed
// decoded text chunk by chunk, so GB-scale files count in bounded memory.
//
// Counting rules:
//   - chars: Unicode code points (a surrogate pair is ONE char)
//   - words: each CJK ideograph / kana / hangul counts as one word; a run of
//     letters/digits/underscore counts as one word (the usual CJK-aware
//     convention). Word runs spanning a chunk boundary count once — the
//     accumulator carries the "ended inside a word" state across feeds.
//   - lines: newline count + 1 (only when the range is non-empty)
//   - whitespace: ASCII blanks/terminators, U+3000 ideographic space, and
//     the U+2000-block spaces
//
// Pure Dart, no flutter imports (headless-testable: tool/text_stats_test.dart).

/// Totals gathered by [StatsAccumulator].
class TextStats {
  const TextStats({
    required this.bytes,
    required this.chars,
    required this.charsNoWs,
    required this.words,
    required this.cjk,
    required this.newlines,
  });

  final int bytes;
  final int chars;
  final int charsNoWs;
  final int words;

  /// CJK ideographs + kana + hangul (each also counted as one word).
  final int cjk;
  final int newlines;

  /// Line count: newlines + 1 for any non-empty text.
  int get lines => chars == 0 ? 0 : newlines + 1;
}

bool _isWs(int cp) =>
    cp == 0x20 ||
    cp == 0x09 ||
    cp == 0x0A ||
    cp == 0x0D ||
    cp == 0x0B ||
    cp == 0x0C ||
    cp == 0x3000 ||
    (cp >= 0x2000 && cp <= 0x200B) ||
    cp == 0x00A0;

bool _isCjk(int cp) =>
    (cp >= 0x4E00 && cp <= 0x9FFF) || // CJK unified
    (cp >= 0x3400 && cp <= 0x4DBF) || // extension A
    (cp >= 0x20000 && cp <= 0x2FA1F) || // extensions B+ (astral)
    (cp >= 0xF900 && cp <= 0xFAFF) || // compatibility ideographs
    (cp >= 0x3040 && cp <= 0x30FF) || // hiragana + katakana
    (cp >= 0x31F0 && cp <= 0x31FF) || // katakana extensions
    (cp >= 0xAC00 && cp <= 0xD7AF); // hangul syllables

bool _isWordChar(int cp) =>
    (cp >= 0x30 && cp <= 0x39) || // 0-9
    (cp >= 0x41 && cp <= 0x5A) || // A-Z
    (cp >= 0x61 && cp <= 0x7A) || // a-z
    cp == 0x5F || // _
    (cp >= 0xC0 && cp <= 0x2AF) || // Latin-1/-Extended letters
    (cp >= 0x370 && cp <= 0x1FFF); // Greek/Cyrillic/etc. letters (rough)

/// Feed decoded text in document order; read the totals from [finish].
class StatsAccumulator {
  int _chars = 0, _charsNoWs = 0, _words = 0, _cjk = 0, _newlines = 0;
  bool _inWordRun = false; // an alnum run continues across the feed boundary

  void feed(String text) {
    for (final cp in text.runes) {
      _chars++;
      if (cp == 0x0A) _newlines++;
      if (_isWs(cp)) {
        _inWordRun = false;
        continue;
      }
      _charsNoWs++;
      if (_isCjk(cp)) {
        _cjk++;
        _words++;
        _inWordRun = false;
      } else if (_isWordChar(cp)) {
        if (!_inWordRun) _words++;
        _inWordRun = true;
      } else {
        _inWordRun = false; // punctuation and the rest: separators
      }
    }
  }

  TextStats finish(int bytes) => TextStats(
    bytes: bytes,
    chars: _chars,
    charsNoWs: _charsNoWs,
    words: _words,
    cjk: _cjk,
    newlines: _newlines,
  );
}
