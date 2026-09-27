// Quick open (ctrl+p) core — pure Dart, tool/quick_open_test.dart.
//
// Fuzzy matching in the VS Code style: every query character must appear
// in order; matches at the start, after a separator, or right after the
// previous match score higher; a match on the file name beats one deep in
// the directory part. Plus a bounded, cancellable directory walk that feeds
// the candidate list in batches so a huge tree never blocks the dialog.

import 'dart:io';

/// Score of [query] against [text], higher = better; null = no match.
/// Case-insensitive; an empty query matches everything with score 0.
int? fuzzyScore(String query, String text) {
  if (query.isEmpty) return 0;
  final q = query.toLowerCase(), t = text.toLowerCase();
  var score = 0, qi = 0, prevMatch = -2;
  for (var ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t.codeUnitAt(ti) != q.codeUnitAt(qi)) continue;
    var s = 1;
    if (ti == 0 || _isSeparator(t.codeUnitAt(ti - 1))) s += 8; // word start
    if (ti == prevMatch + 1) s += 4; // consecutive
    if (t.codeUnitAt(ti) == query.codeUnitAt(qi)) s += 1; // same case
    score += s;
    prevMatch = ti;
    qi++;
  }
  if (qi < q.length) return null;
  // Shorter targets are better matches for the same characters.
  return score * 100 - t.length.clamp(0, 99);
}

bool _isSeparator(int u) =>
    u == 0x2F || u == 0x5C || u == 0x2E || u == 0x5F || u == 0x2D || u == 0x20;

/// One candidate: [label] is what the user matches against first (file
/// name), [detail] the secondary text (directory); [value] is returned.
class QuickItem {
  const QuickItem(this.label, this.detail, this.value, {this.group = 0});
  final String label;
  final String detail;
  final String value;

  /// Lower groups list first when scores tie (0 = open tabs, 1 = recent,
  /// 2 = folder scan).
  final int group;
}

/// Filter + rank [items] for [query]: file-name score counts double, the
/// path score breaks ties; unmatched items drop out.
List<QuickItem> rankQuickItems(String query, List<QuickItem> items) {
  if (query.trim().isEmpty) {
    return List.of(items)..sort((a, b) => a.group.compareTo(b.group));
  }
  final q = query.trim();
  final scored = <(int, QuickItem)>[];
  for (final it in items) {
    final ls = fuzzyScore(q, it.label);
    final ds = fuzzyScore(q, it.detail.isEmpty ? it.label : '${it.detail}/${it.label}');
    if (ls == null && ds == null) continue;
    scored.add(((ls ?? 0) * 2 + (ds ?? 0), it));
  }
  scored.sort((a, b) {
    final c = b.$1.compareTo(a.$1);
    if (c != 0) return c;
    final g = a.$2.group.compareTo(b.$2.group);
    return g != 0 ? g : a.$2.label.compareTo(b.$2.label);
  });
  return [for (final s in scored) s.$2];
}

/// Walk [root] breadth-first and yield file paths in batches. Skips
/// dot-entries and the usual build/dependency folders, stops at [maxFiles]
/// or [maxDepth], and after each batch checks [cancelled] so a closed
/// dialog stops the walk promptly.
Stream<List<String>> scanFilesUnder(
  String root, {
  int maxFiles = 5000,
  int maxDepth = 8,
  int batch = 200,
  bool Function()? cancelled,
  Set<String> skipDirs = const {
    'node_modules', 'build', '.git', 'target', '.dart_tool', '__pycache__',
    'dist', 'out', 'bin', 'obj', '.idea', '.vscode',
  },
}) async* {
  final queue = <(Directory, int)>[(Directory(root), 0)];
  var count = 0;
  var pending = <String>[];
  while (queue.isNotEmpty && count < maxFiles) {
    if (cancelled?.call() ?? false) return;
    final (dir, depth) = queue.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      continue; // unreadable: skip silently
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        if (depth + 1 <= maxDepth && !skipDirs.contains(name)) {
          queue.add((e, depth + 1));
        }
      } else if (e is File) {
        pending.add(e.path);
        count++;
        if (pending.length >= batch) {
          yield pending;
          pending = <String>[];
          if (cancelled?.call() ?? false) return;
        }
        if (count >= maxFiles) break;
      }
    }
  }
  if (pending.isNotEmpty) yield pending;
}
