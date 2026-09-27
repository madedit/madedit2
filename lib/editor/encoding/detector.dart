// Encoding auto-detection over a sample of the file head (default 64KB,
// size configurable in settings).
//
// Detection list != support list: only statistically distinguishable
// encodings are guessed here (BOM, UTF-16/32 NUL patterns, strict UTF-8,
// DBCS structural scoring); every registered codec remains selectable
// manually from the menu. When nothing matches, the fallback is UTF-8
// (invalid sequences will show as U+FFFD until the user switches manually).
//
// Known limits of structural (table-free) scoring:
//   - A file whose sampled head is pure ASCII is reported as UTF-8 even if
//     later parts use a legacy DBCS — by design (we never scan GB files).
//   - GBK vs EUC-KR (and Big5 vs EUC-JP kana) overlap structurally; without
//     per-language frequency tables the earlier candidate in _dbcsSpecs
//     wins ties. Frequency tables can be added later if this bites.

import 'dart:typed_data';

class EncodingGuess {
  /// Canonical codec name (see codecs.dart); may name a codec whose table
  /// is not registered yet — callers must handle a null lookup.
  final String codecName;

  /// BOM length in bytes; 0 when no BOM was found.
  final int bomLength;

  /// False when we fell back to the default rather than detecting.
  final bool confident;

  /// Short English note for the log.
  final String reason;

  const EncodingGuess(
    this.codecName,
    this.bomLength,
    this.confident,
    this.reason,
  );

  @override
  String toString() =>
      '$codecName (bom=$bomLength, ${confident ? "detected" : "fallback"}: $reason)';
}

EncodingGuess detectEncoding(Uint8List s) {
  final n = s.length;
  if (n == 0) return const EncodingGuess('UTF-8', 0, false, 'empty sample');

  // 1. BOM. UTF-32 LE must be checked before UTF-16 LE (FF FE prefix).
  if (n >= 4 && s[0] == 0xFF && s[1] == 0xFE && s[2] == 0 && s[3] == 0) {
    return const EncodingGuess('UTF-32 LE', 4, true, 'BOM');
  }
  if (n >= 4 && s[0] == 0 && s[1] == 0 && s[2] == 0xFE && s[3] == 0xFF) {
    return const EncodingGuess('UTF-32 BE', 4, true, 'BOM');
  }
  if (n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF) {
    return const EncodingGuess('UTF-8', 3, true, 'BOM');
  }
  if (n >= 2 && s[0] == 0xFF && s[1] == 0xFE) {
    return const EncodingGuess('UTF-16 LE', 2, true, 'BOM');
  }
  if (n >= 2 && s[0] == 0xFE && s[1] == 0xFF) {
    return const EncodingGuess('UTF-16 BE', 2, true, 'BOM');
  }

  // 2. NUL-byte distribution -> UTF-16/32 without BOM. Text in legacy or
  // UTF-8 encodings never contains NUL, so any significant number of zeros
  // in a fixed byte-position pattern is a strong Unicode-units signal.
  final zeros = List<int>.filled(4, 0);
  var zeroTotal = 0;
  for (var i = 0; i < n; i++) {
    if (s[i] == 0) {
      zeros[i & 3]++;
      zeroTotal++;
    }
  }
  if (zeroTotal * 4 >= n) {
    final q = n / 4;
    bool high(int k) => zeros[k] > q * 0.7;
    bool low(int k) => zeros[k] < q * 0.3;
    if (high(1) && high(2) && high(3) && low(0)) {
      return const EncodingGuess('UTF-32 LE', 0, true, 'NUL pattern');
    }
    if (high(0) && high(1) && high(2) && low(3)) {
      return const EncodingGuess('UTF-32 BE', 0, true, 'NUL pattern');
    }
    final even = zeros[0] + zeros[2], odd = zeros[1] + zeros[3];
    final h = n / 2;
    if (odd > h * 0.7 && even < h * 0.3) {
      return const EncodingGuess('UTF-16 LE', 0, true, 'NUL pattern');
    }
    if (even > h * 0.7 && odd < h * 0.3) {
      return const EncodingGuess('UTF-16 BE', 0, true, 'NUL pattern');
    }
  }
  if (zeroTotal > 0) {
    // Few NULs (CJK-heavy UTF-16 text has almost none — they come from the
    // newlines and any ASCII): decode as UTF-16 and see whether it reads as
    // clean multi-line text. Newlines discriminate the endianness: the LE
    // newline unit read as BE is U+0A00, not a newline.
    final le = _utf16TextNewlines(s, littleEndian: true);
    final be = _utf16TextNewlines(s, littleEndian: false);
    if (le > 0 || be > 0) {
      return le >= be
          ? const EncodingGuess('UTF-16 LE', 0, true, 'UTF-16 text pattern')
          : const EncodingGuess('UTF-16 BE', 0, true, 'UTF-16 text pattern');
    }
    // NUL bytes but nothing reads as UTF-16 text: likely binary. Keep bytes
    // intact and let the user pick; UTF-8 shows U+FFFD for what's invalid.
    return const EncodingGuess('UTF-8', 0, false, 'NUL bytes, no unit pattern');
  }

  // 3. Strict UTF-8 validation (a sequence truncated by the sample edge is
  // not an error — the sample is a prefix cut at an arbitrary point).
  final u8 = _validateUtf8(s);
  if (u8 == _Utf8State.ascii) {
    return const EncodingGuess('UTF-8', 0, true, 'ASCII only');
  }
  if (u8 == _Utf8State.validMultibyte) {
    return const EncodingGuess('UTF-8', 0, true, 'valid UTF-8');
  }

  // 4. DBCS structural scoring.
  _DbcsSpec? best;
  var bestScore = 0.0;
  for (final spec in _dbcsSpecs) {
    final score = _scoreDbcs(s, spec);
    if (score > bestScore) {
      best = spec;
      bestScore = score;
    }
  }
  if (best != null && bestScore > 0.5) {
    return EncodingGuess(
      best.name,
      0,
      true,
      'DBCS score ${bestScore.toStringAsFixed(2)}',
    );
  }

  // 5. Nothing matched.
  return const EncodingGuess('UTF-8', 0, false, 'no match');
}

/// Newline count when [s] reads as clean multi-line UTF-16 text of the given
/// byte order; 0 when it doesn't. "Clean" is strict — no control units
/// (except tab/CR/LF), no lone surrogates, no noncharacters — so binaries
/// with scattered NULs don't slip through.
int _utf16TextNewlines(Uint8List s, {required bool littleEndian}) {
  final n = s.length - (s.length & 1);
  if (n < 16) return 0;
  var newlines = 0;
  var expectLow = false;
  for (var i = 0; i < n; i += 2) {
    final u = littleEndian ? s[i] | (s[i + 1] << 8) : (s[i] << 8) | s[i + 1];
    if (expectLow) {
      if (u < 0xDC00 || u > 0xDFFF) return 0; // broken surrogate pair
      expectLow = false;
      continue;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) return 0; // lone low surrogate
    if (u >= 0xD800 && u <= 0xDBFF) {
      expectLow = true;
      continue;
    }
    if (u == 10) {
      newlines++;
      continue;
    }
    if (u < 0x20 && u != 9 && u != 13) return 0; // control character
    if (u == 0xFFFE || u == 0xFFFF) return 0; // noncharacter
  }
  // A pair truncated by the sample edge is not an error (prefix sample).
  return newlines;
}

enum _Utf8State { ascii, validMultibyte, invalid }

_Utf8State _validateUtf8(Uint8List s) {
  final n = s.length;
  var i = 0;
  var multibyte = false;
  while (i < n) {
    final b0 = s[i];
    if (b0 < 0x80) {
      i++;
      continue;
    }
    int len;
    int lo1 = 0x80, hi1 = 0xBF;
    if (b0 >= 0xC2 && b0 <= 0xDF) {
      len = 2;
    } else if (b0 >= 0xE0 && b0 <= 0xEF) {
      len = 3;
      if (b0 == 0xE0) lo1 = 0xA0;
      if (b0 == 0xED) hi1 = 0x9F;
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
      len = 4;
      if (b0 == 0xF0) lo1 = 0x90;
      if (b0 == 0xF4) hi1 = 0x8F;
    } else {
      return _Utf8State.invalid;
    }
    if (i + len > n) {
      return multibyte ? _Utf8State.validMultibyte : _Utf8State.ascii;
    }
    if (s[i + 1] < lo1 || s[i + 1] > hi1) return _Utf8State.invalid;
    for (var k = 2; k < len; k++) {
      if ((s[i + k] & 0xC0) != 0x80) return _Utf8State.invalid;
    }
    multibyte = true;
    i += len;
  }
  return multibyte ? _Utf8State.validMultibyte : _Utf8State.ascii;
}

class _DbcsSpec {
  final String name;
  final bool Function(int b) isLead;
  final bool Function(int lead, int trail) isTrail;

  /// "Common text zone" bonus — the statistically frequent block of the
  /// encoding (main hanzi / kana / hangul area), used to break the heavy
  /// structural overlap between DBCS encodings.
  final bool Function(int lead, int trail) isCommon;

  /// Single high bytes that are legal on their own (Shift-JIS halfwidth
  /// katakana); null when the encoding has none.
  final bool Function(int b)? isSingleHigh;

  const _DbcsSpec(
    this.name,
    this.isLead,
    this.isTrail,
    this.isCommon, [
    this.isSingleHigh,
  ]);
}

// Candidate order breaks exact ties (earlier wins) — Big5 first per the
// project's primary audience.
final List<_DbcsSpec> _dbcsSpecs = [
  _DbcsSpec(
    'Big5',
    (b) => b >= 0x81 && b <= 0xFE,
    (l, t) => (t >= 0x40 && t <= 0x7E) || (t >= 0xA1 && t <= 0xFE),
    (l, t) => l >= 0xA4 && l <= 0xC6, // common hanzi zone
  ),
  _DbcsSpec(
    'GBK',
    (b) => b >= 0x81 && b <= 0xFE,
    (l, t) => t >= 0x40 && t <= 0xFE && t != 0x7F,
    (l, t) => l >= 0xB0 && l <= 0xF7 && t >= 0xA1 && t <= 0xFE, // GB2312 hanzi
  ),
  _DbcsSpec(
    'Shift-JIS',
    (b) => (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC),
    (l, t) => t >= 0x40 && t <= 0xFC && t != 0x7F,
    // Kana rows (0x82/0x83) and level-1 kanji (0x88..0x9F).
    (l, t) => l == 0x82 || l == 0x83 || (l >= 0x88 && l <= 0x9F),
    (b) => b >= 0xA1 && b <= 0xDF, // halfwidth katakana
  ),
  _DbcsSpec(
    'EUC-KR',
    (b) => b >= 0x81 && b <= 0xFE,
    (l, t) => t >= 0x41 && t <= 0xFE,
    (l, t) => l >= 0xB0 && l <= 0xC8 && t >= 0xA1 && t <= 0xFE, // hangul zone
  ),
  _DbcsSpec(
    'EUC-JP',
    (b) => (b >= 0xA1 && b <= 0xFE) || b == 0x8E,
    (l, t) => l == 0x8E ? (t >= 0xA1 && t <= 0xDF) : (t >= 0xA1 && t <= 0xFE),
    // Kana rows (A4/A5) and JIS level-1 kanji (B0..CF).
    (l, t) => l == 0xA4 || l == 0xA5 || (l >= 0xB0 && l <= 0xCF),
  ),
];

/// Normalized score: high-byte tokens that parse cleanly (with a bonus for
/// the encoding's common text zone) minus a heavy penalty for bytes that
/// cannot be parsed at all. <= 0 means "not this encoding".
double _scoreDbcs(Uint8List s, _DbcsSpec spec) {
  var pairs = 0, common = 0, singles = 0, bad = 0;
  final n = s.length;
  var i = 0;
  while (i < n) {
    final b = s[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    if (spec.isLead(b) && i + 1 < n && spec.isTrail(b, s[i + 1])) {
      pairs++;
      if (spec.isCommon(b, s[i + 1])) common++;
      i += 2;
      continue;
    }
    if (spec.isSingleHigh != null && spec.isSingleHigh!(b)) {
      singles++;
      i++;
      continue;
    }
    bad++;
    i++;
  }
  final tokens = pairs + singles + bad;
  if (tokens == 0 || pairs + singles == 0) return -1;
  return (pairs + singles * 0.5 + common - bad * 5.0) / tokens;
}

/// Whether the head sample looks like a binary file rather than text (the
/// editor then opens it in hex mode): NUL bytes that do not form a UTF-16/32
/// text pattern, or a sizeable share of other control bytes. A BOM, or a
/// clean Unicode-units pattern, means text. Pure heuristic — the user can
/// always switch the view mode back.
bool looksBinary(Uint8List s) {
  final n = s.length;
  if (n == 0) return false;
  final g = detectEncoding(s);
  if (g.bomLength > 0 ||
      g.codecName.startsWith('UTF-16') ||
      g.codecName.startsWith('UTF-32')) {
    return false;
  }
  var controls = 0;
  for (var i = 0; i < n; i++) {
    final b = s[i];
    if (b == 0) return true;
    // Tab, LF, CR, FF, ESC (ANSI colour codes in logs) are ordinary in text.
    if ((b < 0x20 &&
            b != 0x09 &&
            b != 0x0A &&
            b != 0x0D &&
            b != 0x0C &&
            b != 0x1B) ||
        b == 0x7F) {
      controls++;
    }
  }
  return controls >= 8 && controls * 10 > n;
}
