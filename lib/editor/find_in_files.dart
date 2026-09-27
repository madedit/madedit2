// Find in Files: walk a directory tree and run the chunked document search
// over every matching file (Search → Find in Files…).
//
// Reuses the editor's own machinery per file: Document.open (zero-scan),
// head-sample encoding detection, and the same 1MB-core + 64KB-overlap
// window walk as search.dart — so match positions are BYTE offsets obtained
// through the decode map (never re-encoded), ready to become the selection
// when a result is opened. Line numbers come free from counting newlines in
// the decoded windows the walk reads anyway.
//
// Cooperative and cancellable: everything is chunked awaits; the caller
// polls [FifCancel.cancelled] between chunks/files. Pure Dart, no flutter
// imports (headless-testable: tool/find_in_files_test.dart).

import 'dart:io';
import 'dart:math';

import 'document.dart';
import 'encoding/codecs.dart';
import 'encoding/detector.dart';
import '../util/atomic_file.dart';
import 'search.dart'
    show scanSearchWindow, searchOverlapFor, searchForward, expandReplacement;

/// One hit: where (for the jump + selection) and what it looks like.
class FifMatch {
  const FifMatch({
    required this.path,
    required this.byteStart,
    required this.byteEnd,
    required this.line,
    required this.preview,
    required this.hlStart,
    required this.hlEnd,
  });

  final String path;
  final int byteStart; // selection range in document bytes
  final int byteEnd;
  final int line; // 1-based line number

  /// The match's line (clipped to [maxPreviewChars]); [hlStart]..[hlEnd] is
  /// the match's range within it (UTF-16 code units, clipped too).
  final String preview;
  final int hlStart;
  final int hlEnd;
}

/// Cooperative cancellation token.
class FifCancel {
  bool cancelled = false;
}

/// Outcome counters (the matches themselves stream through `onMatch`).
class FifSummary {
  const FifSummary({
    required this.filesScanned,
    required this.filesMatched,
    required this.matches,
    required this.truncated,
    required this.cancelled,
  });

  final int filesScanned;
  final int filesMatched;
  final int matches;

  /// True when a cap ended the search early (total or per-file match cap).
  final bool truncated;
  final bool cancelled;
}

const int maxPreviewChars = 250;

/// Compile `*.txt;*.md`-style patterns into one filename matcher
/// (case-insensitive; empty/blank = match everything).
RegExp? compileFilePatterns(String patterns) {
  final parts = [
    for (final p in patterns.split(RegExp(r'[;,\s]+')))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (parts.isEmpty) return null;
  final alts = parts
      .map((p) {
        final sb = StringBuffer();
        for (final ch in p.split('')) {
          switch (ch) {
            case '*':
              sb.write('.*');
            case '?':
              sb.write('.');
            default:
              sb.write(RegExp.escape(ch));
          }
        }
        return sb.toString();
      })
      .join('|');
  return RegExp('^(?:$alts)\$', caseSensitive: false);
}

/// Search one file. Returns the matches found (bounded by [maxMatches]);
/// null when the file was skipped (unreadable, over [maxFileBytes], or
/// binary — NULs in the head sample with a single-byte-unit codec).
Future<List<FifMatch>?> findInFile(
  String path,
  RegExp re, {
  int maxMatches = 1000,
  int maxFileBytes = 256 << 20,
  int sampleBytes = 64 << 10,
  FifCancel? cancel,
}) async {
  Document doc;
  try {
    doc = await Document.open(path, scanOriginalLineFeeds: false);
  } catch (_) {
    return null;
  }
  try {
    final len = doc.length;
    if (len > maxFileBytes) return null;
    final sample = await doc.original.readBytes(0, min(sampleBytes, len));
    final guess = detectEncoding(sample);
    final codec = textCodecByName(guess.codecName);
    if (codec != null) doc.codec = codec;
    if (doc.codec.unitSize == 1 && sample.contains(0)) return null; // binary
    final out = <FifMatch>[];
    var lineBase = 0; // newlines fully counted before the current window
    var pos = 0;
    final overlap = searchOverlapFor(re);
    while (pos < len) {
      if (cancel?.cancelled ?? false) break;
      // Same windowing as the in-document search (line-aligned cut, grown
      // for long matches), so boundary matches are not lost here either.
      final w = await scanSearchWindow(doc, re, pos, overlap: overlap);
      final d = w.text;
      final text = d.text;
      final lastChunk = w.atEnd;
      // Matches starting at/past the cut belong to the next window.
      final coreEndCu = w.cutCu;
      var nlScan = 0, nlCount = 0; // incremental newline prefix counter
      int nlBefore(int cu) {
        while (nlScan < cu) {
          if (text.codeUnitAt(nlScan) == 0x0A) nlCount++;
          nlScan++;
        }
        return nlCount;
      }

      for (final m in w.matches) {
        if (!lastChunk && m.start >= coreEndCu) break;
        final sb = pos + d.byteForCodeUnit(m.start);
        final eb = pos + d.byteForCodeUnit(m.end);
        if (eb <= sb) continue;
        // Line preview: the match's line, clipped around the match.
        final ls = text.lastIndexOf('\n', max(0, m.start - 1)) + 1;
        var le = text.indexOf('\n', m.start);
        if (le < 0) le = text.length;
        if (le > 0 && text.codeUnitAt(le - 1) == 0x0D) le--;
        var ps = ls, pe = le;
        if (pe - ps > maxPreviewChars) {
          // Keep the match visible: start the clip shortly before it.
          ps = max(ls, m.start - 40);
          pe = min(le, ps + maxPreviewChars);
        }
        out.add(
          FifMatch(
            path: path,
            byteStart: sb,
            byteEnd: eb,
            line: lineBase + nlBefore(m.start) + 1,
            preview: text.substring(ps, pe),
            hlStart: (m.start - ps).clamp(0, pe - ps),
            hlEnd: (min(m.end, pe) - ps).clamp(0, pe - ps),
          ),
        );
        if (out.length >= maxMatches) return out;
      }
      if (lastChunk) break;
      lineBase += nlBefore(coreEndCu);
      pos += d.byteForCodeUnit(coreEndCu);
    }
    return out;
  } catch (_) {
    return null;
  } finally {
    try {
      await doc.close();
    } catch (_) {}
  }
}

/// Walk [root] (recursively unless told otherwise), search every file whose
/// NAME matches [patterns], and stream hits through [onMatch]. Entries whose
/// name starts with `.` are skipped (`.git` and friends). [onFile] fires
/// before each file is searched (progress display).
Future<FifSummary> findInFiles({
  required String root,
  required RegExp re,
  String patterns = '',
  bool recursive = true,
  int maxMatches = 2000,
  int maxFileBytes = 256 << 20,
  int sampleBytes = 64 << 10,
  FifCancel? cancel,
  void Function(FifMatch m)? onMatch,
  void Function(String path, int filesScanned)? onFile,
}) async {
  final nameRe = compileFilePatterns(patterns);
  var scanned = 0, matchedFiles = 0, total = 0, truncated = false;
  final dirs = <Directory>[Directory(root)];
  while (dirs.isNotEmpty) {
    if (cancel?.cancelled ?? false) break;
    final dir = dirs.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      continue; // unreadable directory
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (cancel?.cancelled ?? false) break;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        if (recursive) dirs.add(e);
        continue;
      }
      if (e is! File) continue;
      if (nameRe != null && !nameRe.hasMatch(name)) continue;
      scanned++;
      onFile?.call(e.path, scanned);
      final hits = await findInFile(
        e.path,
        re,
        maxMatches: maxMatches - total,
        maxFileBytes: maxFileBytes,
        sampleBytes: sampleBytes,
        cancel: cancel,
      );
      if (hits == null || hits.isEmpty) continue;
      matchedFiles++;
      for (final h in hits) {
        total++;
        onMatch?.call(h);
      }
      if (total >= maxMatches) {
        truncated = true;
        break;
      }
    }
    if (truncated) break;
  }
  return FifSummary(
    filesScanned: scanned,
    filesMatched: matchedFiles,
    matches: total,
    truncated: truncated,
    cancelled: cancel?.cancelled ?? false,
  );
}

// ── Replace in Files ─────────────────────────────────────────────────────

/// How a rewritten file gets swapped over the original (default: the pure
/// dart:io rename / backup swap; the shell passes a sandbox-aware one on
/// macOS).
typedef ReplaceFileFn = Future<void> Function(String tmp, String dest);

/// Outcome for one file: [count] replacements written (0 = untouched),
/// [skipped] when the file was not eligible (binary, too big, unreadable),
/// [error] when the rewrite failed (original left as it was).
class FifReplaceOutcome {
  const FifReplaceOutcome(this.count, {this.skipped = false, this.error});
  final int count;
  final bool skipped;
  final String? error;
}

/// Replace every match of [re] in the file at [path] on disk: same
/// eligibility rules as [findInFile], the same forward re-search walk as the
/// editor's replace-all (offsets never go stale), then the buffer is
/// streamed to a temp file beside the original and swapped in atomically.
/// A file with no matches is never rewritten; cancelling mid-file discards
/// the pending edits (nothing is written).
Future<FifReplaceOutcome> replaceInFile(
  String path,
  RegExp re,
  String replacement, {
  bool regex = true,
  int maxFileBytes = 256 << 20,
  int sampleBytes = 64 << 10,
  FifCancel? cancel,
  ReplaceFileFn replaceFile = atomicReplaceFile,
}) async {
  Document doc;
  try {
    doc = await Document.open(path, scanOriginalLineFeeds: false);
  } catch (_) {
    return const FifReplaceOutcome(0, skipped: true);
  }
  var closed = false;
  Future<void> closeDoc() async {
    if (closed) return;
    closed = true;
    try {
      await doc.close();
    } catch (_) {}
  }

  try {
    final len = doc.length;
    if (len > maxFileBytes) return const FifReplaceOutcome(0, skipped: true);
    final sample = await doc.original.readBytes(0, min(sampleBytes, len));
    final guess = detectEncoding(sample);
    final codec = textCodecByName(guess.codecName);
    if (codec != null) doc.codec = codec;
    if (doc.codec.unitSize == 1 && sample.contains(0)) {
      return const FifReplaceOutcome(0, skipped: true); // binary
    }
    var pos = 0, count = 0;
    while (true) {
      if (cancel?.cancelled ?? false) return const FifReplaceOutcome(0);
      final m = await searchForward(doc, re, pos);
      if (m == null) break;
      final text = expandReplacement(replacement, m.groups, regex: regex);
      final enc = doc.codec.encode(text);
      await doc.delete(m.start, m.end - m.start);
      if (enc.bytes.isNotEmpty) await doc.insertBytes(m.start, enc.bytes);
      pos = m.start + enc.bytes.length;
      count++;
    }
    if (count == 0) return const FifReplaceOutcome(0);
    // Write beside the original, then swap (the temp name is dot-prefixed so
    // a concurrent walk of the same tree skips it).
    final f = File(path);
    final sep = Platform.pathSeparator;
    final dir = f.parent.path;
    final name = path.split(sep).last;
    final tmp = '$dir$sep.$name.tmp~';
    try {
      final sink = File(tmp).openWrite();
      try {
        await doc.streamTo(sink);
        await sink.flush();
      } finally {
        await sink.close();
      }
      await closeDoc(); // release the original before swapping over it
      await replaceFile(tmp, path);
    } catch (e) {
      try {
        await File(tmp).delete();
      } catch (_) {}
      return FifReplaceOutcome(0, error: e.toString());
    }
    return FifReplaceOutcome(count);
  } catch (e) {
    return FifReplaceOutcome(0, error: e.toString());
  } finally {
    await closeDoc();
  }
}

/// Counters for a replace-in-files run; per-file detail streams through
/// `onFileDone`.
class FifReplaceSummary {
  const FifReplaceSummary({
    required this.filesScanned,
    required this.filesChanged,
    required this.replacements,
    required this.failed,
    required this.cancelled,
  });

  final int filesScanned;
  final int filesChanged;
  final int replacements;
  final int failed;
  final bool cancelled;
}

/// Walk [root] like [findInFiles] and replace in every eligible file. Files
/// the caller has open are routed through [inOpenFile] (given the path,
/// return the replacement count once done in the open buffer, or null to
/// have the file rewritten on disk instead); everything else is rewritten in
/// place via [replaceInFile]. [onFile] fires before each file, [onFileDone]
/// after — with the count (or the error) so the UI can list what changed.
Future<FifReplaceSummary> replaceInFiles({
  required String root,
  required RegExp re,
  required String replacement,
  bool regex = true,
  String patterns = '',
  bool recursive = true,
  int maxFileBytes = 256 << 20,
  int sampleBytes = 64 << 10,
  FifCancel? cancel,
  ReplaceFileFn replaceFile = atomicReplaceFile,
  Future<int?> Function(String path)? inOpenFile,
  void Function(String path, int filesScanned)? onFile,
  void Function(String path, FifReplaceOutcome outcome)? onFileDone,
}) async {
  final nameRe = compileFilePatterns(patterns);
  var scanned = 0, changed = 0, total = 0, failed = 0;
  final dirs = <Directory>[Directory(root)];
  while (dirs.isNotEmpty) {
    if (cancel?.cancelled ?? false) break;
    final dir = dirs.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      continue; // unreadable directory
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (cancel?.cancelled ?? false) break;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        if (recursive) dirs.add(e);
        continue;
      }
      if (e is! File) continue;
      if (nameRe != null && !nameRe.hasMatch(name)) continue;
      scanned++;
      onFile?.call(e.path, scanned);
      FifReplaceOutcome out;
      final open = inOpenFile == null ? null : await inOpenFile(e.path);
      if (open != null) {
        out = FifReplaceOutcome(open);
      } else {
        out = await replaceInFile(
          e.path,
          re,
          replacement,
          regex: regex,
          maxFileBytes: maxFileBytes,
          sampleBytes: sampleBytes,
          cancel: cancel,
          replaceFile: replaceFile,
        );
      }
      if (out.error != null) {
        failed++;
      } else if (out.count > 0) {
        changed++;
        total += out.count;
      }
      if (out.error != null || out.count > 0) onFileDone?.call(e.path, out);
    }
  }
  return FifReplaceSummary(
    filesScanned: scanned,
    filesChanged: changed,
    replacements: total,
    failed: failed,
    cancelled: cancel?.cancelled ?? false,
  );
}
