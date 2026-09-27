// File dialogs and sandbox-scoped file access.
//
// Windows / Linux keep using package:file_picker. macOS runs under App Sandbox, where the app may
// only touch files the user pointed at, so it goes through the native `madedit2/mac_files` channel
// (macos/Runner/MacFilesPlugin.swift) instead:
//
//   * the panels hand back a *security-scoped bookmark* next to the path — the only thing that
//     makes a grant survive a relaunch, which is what session restore needs;
//   * [startAccess] re-opens a stored bookmark, [stopAccess] releases it;
//   * [replaceItem] does the atomic save swap, because the grant covers the file and not its
//     directory, so the usual "sibling temp file + rename" is denied.
//
// Off macOS every sandbox entry point is a no-op and callers just use the bare path.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:flutter/services.dart';

/// A file the user chose, plus the macOS bookmark that re-grants access to it later (null on
/// other platforms, and whenever macOS declined to make one).
class PickedFile {
  const PickedFile(this.path, [this.bookmark]);

  final String path;
  final String? bookmark;
}

/// Native open/save panels and security-scoped access. Static-only.
class MacFiles {
  MacFiles._();

  static const _channel = MethodChannel('madedit2/mac_files');

  /// Whether the sandbox-scoped path is in play at all.
  static bool get isActive => Platform.isMacOS;

  /// Bookmarks for files currently open, keyed by path — filled in as files are opened so that
  /// the session save can persist them. Not a cache: a path with no entry simply has no bookmark.
  static final Map<String, String> _bookmarks = {};

  /// Where this module reports failures. main() points it at [Log].
  static void Function(String message, {bool warn}) log =
      (String message, {bool warn = false}) {};

  /// Files handed over by LaunchServices while running (Finder "Open With",
  /// file associations). The shell sets this; [pendingOpenFiles] collects
  /// the ones that arrived before it was set (launch by double-click).
  static void Function(List<String> paths)? onOpenFiles;
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled || !isActive) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFiles') {
        final raw = call.arguments;
        final paths = raw is List
            ? [
                for (final p in raw)
                  if (p is String) p,
              ]
            : <String>[];
        if (paths.isNotEmpty) onOpenFiles?.call(paths);
        return true;
      }
      throw MissingPluginException();
    });
  }

  /// Paths opened through LaunchServices before the shell listened
  /// (empty off macOS). Also installs the live handler.
  static Future<List<String>> pendingOpenFiles() async {
    if (!isActive) return const [];
    _installHandler();
    final r = await _invoke<List<Object?>>('pendingOpenFiles');
    return [
      for (final p in r ?? const <Object?>[])
        if (p is String) p,
    ];
  }

  /// Remember [file]'s bookmark (if any) so [bookmarkOf] can find it at session-save time.
  static void remember(PickedFile file) {
    final b = file.bookmark;
    if (b != null && b.isNotEmpty) _bookmarks[file.path] = b;
  }

  /// The stored bookmark for [path], minting a fresh one if access is live but none was kept
  /// (a file opened before this ran, or one whose bookmark went stale). Null off macOS.
  static Future<String?> bookmarkOf(String path) async {
    if (!isActive) return null;
    final held = _bookmarks[path];
    if (held != null) return held;
    final made = await _invoke<String>('bookmark', {'path': path});
    if (made != null) _bookmarks[path] = made;
    return made;
  }

  static void forget(String path) => _bookmarks.remove(path);

  /// Re-grant access to a bookmark stored in a previous session and return the path it resolves
  /// to (which may differ from the recorded one — the user can move a file between runs). Null
  /// when the bookmark is unusable, in which case the file can no longer be reopened silently.
  static Future<String?> startAccess(String bookmark) async {
    if (!isActive || bookmark.isEmpty) return null;
    final res = await _invoke<Map<Object?, Object?>>('startAccess', {
      'bookmark': bookmark,
    });
    final path = res?['path'];
    if (path is! String || path.isEmpty) return null;
    // A stale bookmark still resolves, but only this once — replace it while access is live.
    if (res?['stale'] == true) {
      final fresh = await _invoke<String>('bookmark', {'path': path});
      if (fresh != null) _bookmarks[path] = fresh;
    } else {
      _bookmarks[path] = bookmark;
    }
    return path;
  }

  /// Release access taken by [startAccess]. Safe to call for paths that never took any.
  static Future<void> stopAccess(String path) async {
    if (!isActive) return;
    await _invoke<void>('stopAccess', {'path': path});
  }

  /// Atomically replace [dst] with [src], returning the resulting path. Only used on macOS;
  /// the other platforms keep their own rename-based replacement.
  static Future<String> replaceItem(String src, String dst) async {
    final res = await _channel.invokeMethod<String>('replaceItem', {
      'src': src,
      'dst': dst,
    });
    return res ?? dst;
  }

  /// Ask the user for a file to open. [extensions] restricts the panel on non-macOS platforms
  /// (the native panel stays unfiltered — the editor opens anything).
  static Future<PickedFile?> openFile({List<String>? extensions}) async {
    if (isActive) {
      final res = await _invoke<List<Object?>>('openPanel', {
        'allowsMultiple': false,
      });
      final first = (res == null || res.isEmpty) ? null : res.first;
      final picked = _entry(first);
      if (picked != null) remember(picked);
      return picked;
    }
    final res = await FilePicker.pickFile(
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
    );
    final path = res?.path;
    return path == null ? null : PickedFile(path);
  }

  /// Ask the user where to save. [fileName] is the proposed name.
  /// Test seam: replaces the save dialog (there is no native panel under
  /// flutter_test). Null in production.
  static Future<PickedFile?> Function({String? dialogTitle, String? fileName})?
  saveFileHook;

  static Future<PickedFile?> saveFile({
    String? dialogTitle,
    String? fileName,
  }) async {
    final hook = saveFileHook;
    if (hook != null) return hook(dialogTitle: dialogTitle, fileName: fileName);
    if (isActive) {
      final picked = _entry(
        await _invoke<Map<Object?, Object?>>('savePanel', {
          'suggestedName': fileName,
        }),
      );
      if (picked != null) remember(picked);
      return picked;
    }
    // Path-only dialog (file_selector). file_picker >=12's saveFile has no
    // such mode: it writes its [bytes] to the chosen location the moment the
    // dialog closes, and the empty placeholder it was handed truncated the
    // very file the document was still lazily reading when the user chose
    // the file being edited — before the caller could even compare paths.
    // (No title parameter in file_selector's save dialog; the OS titles it.)
    final loc = await getSaveLocation(suggestedName: fileName ?? 'untitled');
    return loc == null ? null : PickedFile(loc.path);
  }

  static PickedFile? _entry(Object? v) {
    if (v is! Map) return null;
    final path = v['path'];
    if (path is! String || path.isEmpty) return null;
    final b = v['bookmark'];
    return PickedFile(path, b is String && b.isNotEmpty ? b : null);
  }

  /// Channel calls are best-effort: a missing plugin (widget tests, a stripped build) or a
  /// platform error must not take down an open/save the user asked for.
  /// Current default handler per extension, plus each extension's UTI under
  /// `<ext>.uti` (see MacFilesPlugin.assocQuery). Extensions nothing handles
  /// are absent from the map.
  static Future<Map<String, String>> assocQuery(List<String> exts) async {
    final res = await _invoke<Map<Object?, Object?>>('assocQuery', {
      'exts': exts,
    });
    return {
      for (final e in (res ?? const {}).entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  /// Make this app the default handler for [exts]; returns the failures as
  /// `{ext: message}` (empty = all applied).
  static Future<Map<String, String>> assocSet(List<String> exts) async {
    final res = await _invoke<Map<Object?, Object?>>('assocSet', {'exts': exts});
    return {
      for (final e in (res ?? const {}).entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      log('mac_files.$method failed: $e', warn: true);
      return null;
    }
  }
}
