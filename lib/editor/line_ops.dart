// Line operations (Edit → Lines): pure text transforms over a block of whole
// lines — sort, dedupe, join, reverse, remove empty, trim trailing — plus
// case conversion of an arbitrary range. The editor hands in the decoded
// text of the affected range and splices the result back as one edit; the
// functions here know nothing about documents. Headless-tested in
// tool/line_ops_test.dart.

/// Operations [applyLineOp] understands (the `edit.*` command suffixes).
const Set<String> lineOps = {
  'joinLines',
  'sortAsc',
  'sortDesc',
  'dedupeLines',
  'removeEmptyLines',
  'trimTrailing',
  'reverseLines',
};

/// Case conversions [applyCaseOp] understands.
const Set<String> caseOps = {'upper', 'lower'};

/// Split into lines on `\n` (a trailing `\r` is stripped per line so CRLF
/// text works too). A trailing newline yields no empty last element; the
/// flag says whether one was there so the caller can put it back.
(List<String>, bool) splitLines(String text) {
  if (text.isEmpty) return (const [], false);
  final parts = text.split('\n');
  final trailing = parts.last.isEmpty;
  if (trailing) parts.removeLast();
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p.endsWith('\r')) parts[i] = p.substring(0, p.length - 1);
  }
  return (parts, trailing);
}

/// Apply [op] (one of [lineOps]) to [text], a block of whole lines; lines
/// come back joined with [newline] (and a trailing one if the input had it).
/// Returns null for an unknown op.
String? applyLineOp(String op, String text, String newline) {
  if (!lineOps.contains(op)) return null;
  final (lines, trailing) = splitLines(text);
  List<String> out;
  switch (op) {
    case 'joinLines':
      // Whitespace at the seams collapses to one space; blank lines vanish.
      final kept = [for (final l in lines) l.trim()]
        ..removeWhere((l) => l.isEmpty);
      out = kept.isEmpty ? [''] : [kept.join(' ')];
    case 'sortAsc':
      out = List.of(lines)..sort();
    case 'sortDesc':
      out = List.of(lines)..sort((a, b) => b.compareTo(a));
    case 'dedupeLines':
      final seen = <String>{};
      out = [
        for (final l in lines)
          if (seen.add(l)) l,
      ];
    case 'removeEmptyLines':
      out = [
        for (final l in lines)
          if (l.trim().isNotEmpty) l,
      ];
    case 'trimTrailing':
      out = [for (final l in lines) l.replaceFirst(RegExp(r'[ \t]+$'), '')];
    case 'reverseLines':
      out = lines.reversed.toList();
    default:
      return null;
  }
  final joined = out.join(newline);
  return trailing && out.isNotEmpty ? '$joined$newline' : joined;
}

/// Upper/lower-case [text] (Unicode-aware, via Dart's String methods).
String? applyCaseOp(String op, String text) => switch (op) {
  'upper' => text.toUpperCase(),
  'lower' => text.toLowerCase(),
  _ => null,
};
