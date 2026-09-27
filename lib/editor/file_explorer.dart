// File explorer sidebar model (View → File Explorer): a lazily loaded directory
// tree flattened into the visible rows the panel paints.
//
// Pure Dart, no flutter imports (headless-testable:
// tool/file_explorer_test.dart). Directories load their children on first
// expansion; [refresh] reloads every expanded directory while keeping the
// expansion state; [reveal] expands the ancestors of a path.

import 'dart:io';

class ExplorerNode {
  ExplorerNode(this.path, this.name, this.isDir, {required this.depth});

  final String path;
  final String name;
  final bool isDir;

  /// 0 for the root's direct children (the root itself is -1, never shown).
  final int depth;

  /// null = not loaded yet.
  List<ExplorerNode>? children;
  bool expanded = false;
  bool loading = false;
  String? error;
}

/// Directories first, then case-insensitive by name.
int compareEntries(ExplorerNode a, ExplorerNode b) {
  if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
  final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return c != 0 ? c : a.name.compareTo(b.name);
}

class ExplorerTree {
  ExplorerTree(String rootPath)
    : root = ExplorerNode(
        _normalize(rootPath),
        rootPath.split(_sep).where((s) => s.isNotEmpty).lastOrNull ?? rootPath,
        true,
        depth: -1,
      )..expanded = true;

  final ExplorerNode root;

  /// Show entries whose name starts with `.` (off by default).
  bool showHidden = false;

  static String get _sep => Platform.pathSeparator;

  static String _normalize(String p) {
    var s = p;
    while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _nameOf(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.where((s) => s.isNotEmpty).lastOrNull ?? path;
  }

  /// (Re)load [dir]'s children. Existing children that are still present
  /// keep their node (and so their expansion + loaded subtree).
  Future<void> load(ExplorerNode dir) async {
    if (!dir.isDir) return;
    dir.loading = true;
    dir.error = null;
    try {
      final old = <String, ExplorerNode>{
        for (final c in dir.children ?? const <ExplorerNode>[]) c.path: c,
      };
      final fresh = <ExplorerNode>[];
      await for (final e in Directory(dir.path).list(followLinks: false)) {
        final name = _nameOf(e.path);
        if (!showHidden && name.startsWith('.')) continue;
        final isDir = e is Directory;
        if (!isDir && e is! File) continue; // links etc.
        final prev = old[e.path];
        fresh.add(
          prev != null && prev.isDir == isDir
              ? prev
              : ExplorerNode(e.path, name, isDir, depth: dir.depth + 1),
        );
      }
      fresh.sort(compareEntries);
      dir.children = fresh;
    } catch (e) {
      dir.children ??= [];
      dir.error = e.toString();
    } finally {
      dir.loading = false;
    }
  }

  /// Expand (loading if needed) or collapse [dir].
  Future<void> toggle(ExplorerNode dir) async {
    if (!dir.isDir) return;
    if (dir.expanded) {
      dir.expanded = false;
      return;
    }
    if (dir.children == null) await load(dir);
    dir.expanded = true;
  }

  /// Reload the root and every expanded directory beneath it.
  Future<void> refresh() => _refreshDir(root);

  Future<void> _refreshDir(ExplorerNode dir) async {
    await load(dir);
    for (final c in dir.children ?? const <ExplorerNode>[]) {
      if (c.isDir && c.expanded) await _refreshDir(c);
    }
  }

  /// Collapse every directory (children stay loaded).
  void collapseAll() {
    void walk(ExplorerNode n) {
      for (final c in n.children ?? const <ExplorerNode>[]) {
        if (c.isDir) {
          c.expanded = false;
          walk(c);
        }
      }
    }

    walk(root);
  }

  /// Expand the ancestors of [path] (loading as needed) and return its node,
  /// or null when [path] is not under the root / does not exist.
  Future<ExplorerNode?> reveal(String path) async {
    final rel = _relative(path);
    if (rel == null) return null;
    final segs = rel.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    var node = root;
    for (final seg in segs) {
      if (node.children == null) await load(node);
      final next = node.children!.where((c) => _same(c.name, seg)).firstOrNull;
      if (next == null) return null;
      node.expanded = true; // the parent must be open for [next] to show
      node = next;
    }
    // Revealing a directory shows it (parent expanded), not its content.
    return node;
  }

  bool _same(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

  /// [path] relative to the root, or null when outside it.
  String? _relative(String path) {
    final r = root.path;
    final p = _normalize(path);
    final rr = Platform.isWindows ? r.toLowerCase() : r;
    final pp = Platform.isWindows ? p.toLowerCase() : p;
    if (pp == rr) return '';
    final prefix = rr.endsWith(_sep) ? rr : '$rr$_sep';
    if (!pp.startsWith(prefix)) return null;
    return p.substring(prefix.length);
  }

  /// Whether [path] lies under the root.
  bool contains(String path) => _relative(path) != null;

  /// The rows to paint: expanded directories' children, depth-first. With a
  /// [filter] (case-insensitive substring) only matching names — and the
  /// loaded directories leading to them — are kept.
  List<ExplorerNode> visible({String filter = ''}) {
    final out = <ExplorerNode>[];
    final f = filter.trim().toLowerCase();
    bool walk(ExplorerNode n) {
      var any = false;
      for (final c in n.children ?? const <ExplorerNode>[]) {
        if (f.isEmpty) {
          out.add(c);
          if (c.isDir && c.expanded) walk(c);
          continue;
        }
        final selfMatch = c.name.toLowerCase().contains(f);
        if (c.isDir && c.children != null) {
          final at = out.length;
          out.add(c);
          final sub = walk(c); // filtered children, regardless of expansion
          if (!selfMatch && !sub) {
            out.removeRange(at, out.length);
          } else {
            any = true;
          }
        } else if (selfMatch) {
          out.add(c);
          any = true;
        }
      }
      return any;
    }

    walk(root);
    return out;
  }
}

// ── moves (drag & drop; pure path logic + one file-system helper) ──

String _sepOf(String p) => p.contains(r'\') && !p.contains('/') ? r'\' : '/';

/// [path] without a trailing separator (except a bare root).
String normalizePath(String path) {
  var s = path;
  while (s.length > 1 &&
      (s.endsWith('/') || s.endsWith(r'\')) &&
      !s.endsWith(r':\') &&
      !s.endsWith(':/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String _fold(String p) => Platform.isWindows ? p.toLowerCase() : p;

/// Same location (Windows: case-insensitive).
bool samePath(String a, String b) =>
    _fold(normalizePath(a)) == _fold(normalizePath(b));

/// [path] is [ancestor] itself or lies beneath it.
bool isInsidePath(String path, String ancestor) {
  final p = _fold(normalizePath(path));
  final a = _fold(normalizePath(ancestor));
  if (p == a) return true;
  final sep = _sepOf(ancestor);
  return p.startsWith(a.endsWith(sep) ? a : '$a$sep');
}

String baseName(String path) =>
    normalizePath(
      path,
    ).split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
    path;

String parentPath(String path) {
  final p = normalizePath(path);
  final i = p.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? p : p.substring(0, i);
}

String joinPath(String dir, String name) {
  final d = normalizePath(dir);
  final sep = _sepOf(d);
  return d.endsWith(sep) ? '$d$name' : '$d$sep$name';
}

/// Plan moving [sources] into [destDir]: `(src, dest)` pairs. Dropped:
/// sources already directly in [destDir] (no-op), sources nested under
/// another source (the ancestor's move carries them), and any source that
/// is [destDir] or one of its ancestors (a folder cannot move into itself).
List<(String, String)> planMoves(Iterable<String> sources, String destDir) {
  final srcs = <String>[];
  for (final s in sources) {
    final n = normalizePath(s);
    if (!srcs.any((x) => samePath(x, n))) srcs.add(n);
  }
  final out = <(String, String)>[];
  for (final s in srcs) {
    if (isInsidePath(destDir, s)) continue; // into itself / its own subtree
    if (samePath(parentPath(s), destDir)) continue; // already there
    if (srcs.any((o) => !samePath(o, s) && isInsidePath(s, o))) continue;
    out.add((s, joinPath(destDir, baseName(s))));
  }
  return out;
}

/// Move a file or directory: rename, and when that fails (another volume)
/// copy then delete. [dest] must not exist.
Future<void> moveEntity(String src, String dest) async {
  final isDir = await FileSystemEntity.isDirectory(src);
  try {
    if (isDir) {
      await Directory(src).rename(dest);
    } else {
      await File(src).rename(dest);
    }
    return;
  } on FileSystemException catch (e) {
    // Cross-device link: fall back to copy + delete. Any other error
    // (sharing violation, permission) is the caller's to retry / report.
    final code = e.osError?.errorCode;
    final crossDevice =
        code == 17 /* Windows ERROR_NOT_SAME_DEVICE */ ||
        code == 18 /* EXDEV */ ||
        (e.osError?.message.toLowerCase().contains('device') ?? false);
    if (!crossDevice) rethrow;
  }
  if (isDir) {
    await _copyDir(src, dest);
    await Directory(src).delete(recursive: true);
  } else {
    await File(src).copy(dest);
    await File(src).delete();
  }
}

Future<void> _copyDir(String src, String dest) async {
  await Directory(dest).create(recursive: true);
  await for (final e in Directory(src).list(followLinks: false)) {
    final target = joinPath(dest, baseName(e.path));
    if (e is Directory) {
      await _copyDir(e.path, target);
    } else if (e is File) {
      await e.copy(target);
    } else if (e is Link) {
      // Recreated as a link (same target string): a cross-volume move used
      // to skip links entirely and then delete the source tree, so every
      // symlink/junction in the folder silently vanished.
      await Link(target).create(await e.target());
    }
  }
}

// ── copy / paste ──

/// Plan copying [sources] into [destDir]: `(src, dest)` pairs. Dropped:
/// sources nested under another source, and a source that is [destDir] or
/// one of its ancestors (a folder cannot be copied into itself). Copying
/// into the source's own folder is allowed — [dest] gets a unique name via
/// [exists].
List<(String, String)> planCopies(
  Iterable<String> sources,
  String destDir,
  bool Function(String path) exists,
) {
  final srcs = <String>[];
  for (final s in sources) {
    final n = normalizePath(s);
    if (!srcs.any((x) => samePath(x, n))) srcs.add(n);
  }
  final out = <(String, String)>[];
  final taken = <String>{};
  for (final s in srcs) {
    if (isInsidePath(destDir, s)) continue;
    if (srcs.any((o) => !samePath(o, s) && isInsidePath(s, o))) continue;
    final name = uniqueChildName(
      baseName(s),
      (c) => taken.contains(_fold(c)) || exists(joinPath(destDir, c)),
    );
    taken.add(_fold(name));
    out.add((s, joinPath(destDir, name)));
  }
  return out;
}

/// [name] when [exists] says it is free, else `name (2)`, `name (3)`, …
/// (the counter goes before the extension: `a (2).txt`).
String uniqueChildName(String name, bool Function(String candidate) exists) {
  if (!exists(name)) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; ; i++) {
    final c = '$stem ($i)$ext';
    if (!exists(c)) return c;
  }
}

/// Copy a file or directory (recursively) to [dest], which must not exist.
Future<void> copyEntity(String src, String dest) async {
  if (await FileSystemEntity.isDirectory(src)) {
    await _copyDir(src, dest);
  } else {
    await File(src).copy(dest);
  }
}
