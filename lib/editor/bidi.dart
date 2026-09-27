// Base text direction of a line: the Unicode bidi "first strong character"
// rule (UAX #9 P2/P3). A line whose first letter is right-to-left (Hebrew,
// Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic and the RTL supplementary
// scripts) is laid out with an RTL base direction and shown right-aligned;
// digits, punctuation and spaces are neutral and skipped. Pure Dart.

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

bool _isRtlRune(int r) =>
    (r >= 0x0590 && r <= 0x08FF) || // Hebrew … Arabic Extended-A/B
    (r >= 0xFB1D && r <= 0xFDFF) || // Hebrew / Arabic presentation forms A
    (r >= 0xFE70 && r <= 0xFEFE) || // Arabic presentation forms B (not the BOM)
    (r >= 0x10800 && r <= 0x10FFF) || // Cypriot, Phoenician, Imperial Aramaic…
    (r >= 0x1E800 && r <= 0x1EFFF); // Mende Kikakui, Adlam, Arabic math symbols

/// Base direction of [text] by its first strong (letter) character: true =
/// right-to-left, false = left-to-right, null = no letter at all (digits,
/// punctuation, spaces only — neutral, so a document-level decision can fall
/// through to the next line).
bool? strongDirection(String text) {
  for (final r in text.runes) {
    if (_isRtlRune(r)) return true;
    if (r < 0x80) {
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) return false;
      continue; // ASCII digits, punctuation, space: neutral
    }
    if (_letter.hasMatch(String.fromCharCode(r))) return false;
  }
  return null;
}

/// True when the first strong (letter) character of [text] is right-to-left.
/// A line with no letters at all is LTR.
bool isRtlText(String text) => strongDirection(text) ?? false;

/// Document-level layout direction from the head of a file: the first line
/// (in reading order) that has a strong character decides; a head with no
/// letters at all takes [fallback] (false = LTR for files; an untitled
/// document passes the UI's own direction so an Arabic / Hebrew / Persian UI
/// starts its new documents right-to-left).
bool detectRtlLayout(Iterable<String> headLines, {bool fallback = false}) {
  for (final line in headLines) {
    final d = strongDirection(line);
    if (d != null) return d;
  }
  return fallback;
}
