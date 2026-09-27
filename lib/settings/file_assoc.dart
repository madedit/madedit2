// Windows file associations (Settings → File Associations…).
//
// Per-user registration under HKCU\Software\Classes — no admin rights:
//   - ProgID `madedit2.file` with shell\open\command = "<exe>" "%1" + icon
//   - each chosen extension gets a `.ext\OpenWithProgids\madedit2.file` value,
//     which puts madedit2 in the right-click "Open with" list.
//   - optional `*\shell\madedit2` verb = "Edit in madedit2" on EVERY file's
//     right-click menu (Windows 11: inside the legacy "Show more options").
// Windows 10/11 deliberately blocks setting the DEFAULT handler from code
// (UserChoice hash), so becoming the default stays a user action in Explorer;
// the dialog says so.
//
// Registry access is direct dart:ffi (util/win_registry.dart) — the original
// PowerShell -EncodedCommand route worked but made opening the dialog take
// seconds (powershell.exe cold start + per-key Get-ItemProperty over hundreds
// of `.ext` keys); the same query is milliseconds through advapi32.
//
// This file stays flutter-free (log goes through the [assocLog] hook), so
// normalizeExt & friends are headless-testable (tool/file_assoc_test.dart).

import 'dart:convert';
import 'dart:io';

import '../util/win_registry.dart';
import 'file_assoc_linux.dart';
import 'file_assoc_mac.dart';
import 'settings_paths.dart';

// macOS: the extensions the dialog registered (LaunchServices cannot list
// "everything we handle" cheaply), kept beside the settings.
String get _macStatePath => settingsPath('assoc.json');

Future<Set<String>> _macRememberedExts() async {
  try {
    final f = File(_macStatePath);
    if (!await f.exists()) return {};
    final j = jsonDecode(await f.readAsString());
    if (j is Map && j['exts'] is List) {
      return {
        for (final e in j['exts'] as List)
          if (e is String) e,
      };
    }
  } catch (_) {}
  return {};
}

Future<void> _macRememberExts(Set<String> exts) async {
  try {
    final f = File(_macStatePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'exts': exts.toList()..sort()}));
  } catch (_) {}
}

/// Log hook (this file cannot import util/log.dart — the dialog wires this
/// to [Log] before use).
void Function(String message, {bool warn})? assocLog;

void _log(String m, {bool warn = false}) => assocLog?.call(m, warn: warn);

/// Our ProgID under HKCU\Software\Classes.
const String assocProgId = 'madedit2.file';

/// Context-menu verb key under `HKCU\Software\Classes\*\shell` (right-click
/// on ANY file → "Edit in madedit2"; on Windows 11 it sits in the legacy
/// "Show more options" menu — the new top-level menu needs a packaged app).
const String assocShellKey = 'madedit2';

/// The context-menu label (a registry value, deliberately not localized).
const String assocShellLabel = 'Edit in madedit2';

const String _classes = r'Software\Classes';
const String _ctxKeyPath = '$_classes\\*\\shell\\$assocShellKey';

/// Curated common text extensions offered as checkboxes in the dialog.
const List<String> commonAssocExts = [
  'txt',
  'log',
  'md',
  'json',
  'xml',
  'yml',
  'yaml',
  'ini',
  'cfg',
  'conf',
  'csv',
  'tsv',
  'sql',
  'sh',
  'bat',
  'cmd',
  'ps1',
  'py',
  'js',
  'ts',
  'c',
  'h',
  'cpp',
  'hpp',
  'cs',
  'java',
  'rs',
  'go',
  'lua',
  'dart',
  'html',
  'css',
  'php',
  'rb',
  'toml',
];

/// Lowercase, strip one leading dot, validate. Null = not a usable extension
/// (empty, spaces, path characters, …).
String? normalizeExt(String raw) {
  var e = raw.trim().toLowerCase();
  if (e.startsWith('.')) e = e.substring(1);
  return RegExp(r'^[a-z0-9][a-z0-9_+~-]{0,15}$').hasMatch(e) ? e : null;
}

/// What a query found: associated extensions + whether the context-menu verb
/// is installed.
class AssocState {
  const AssocState(this.exts, this.contextMenu);
  final Set<String> exts;
  final bool contextMenu;
}

/// Current per-user state: every `.ext` under HKCU classes whose
/// OpenWithProgids carries our ProgID, plus the context-menu verb
/// (empty/false on failure or off Windows).
Future<AssocState> queryFileAssociations() async {
  if (Platform.isLinux) return AssocState(await LinuxAssoc().query(), false);
  if (Platform.isMacOS) {
    // What we are the default for, over the curated list plus whatever the
    // dialog remembered as custom (the state file, like Linux).
    if (!macAssocSupported) return const AssocState({}, false);
    final candidates = {...commonAssocExts, ...await _macRememberedExts()};
    return AssocState(await macOwnedExts(candidates), false);
  }
  if (!Platform.isWindows) return const AssocState({}, false);
  try {
    final exts = <String>{};
    for (final key in regEnumSubKeys(hkeyCurrentUser, _classes)) {
      if (!key.startsWith('.')) continue;
      final e = normalizeExt(key);
      if (e == null) continue;
      if (regValueExists(
        hkeyCurrentUser,
        '$_classes\\$key\\OpenWithProgids',
        assocProgId,
      )) {
        exts.add(e);
      }
    }
    final ctx = regKeyExists(hkeyCurrentUser, _ctxKeyPath);
    return AssocState(exts, ctx);
  } catch (e) {
    _log('file assoc query failed: $e', warn: true);
    return const AssocState({}, false);
  }
}

/// Apply the changes ([contextMenu] null = leave the verb as is); returns an
/// error message, or null on success.
Future<String?> applyFileAssociations({
  required Set<String> add,
  required Set<String> remove,
  bool? contextMenu,
  List<int>? iconPng, // Linux: the launcher icon to install
}) async {
  if (Platform.isLinux) {
    final a = LinuxAssoc();
    final current = await a.query();
    final next = {...current, ...add}..removeAll(remove);
    final err = await a.apply(
      next,
      exe: Platform.resolvedExecutable,
      iconPng: iconPng,
    );
    _log('file assoc (linux) applied: +$add -$remove → $next err=$err');
    return err;
  }
  if (Platform.isMacOS) {
    if (!macAssocSupported) return 'LaunchServices unavailable';
    final failed = await macSetDefaultHandlers(add);
    // LaunchServices has no "unset": a removed extension keeps its current
    // handler; the user picks another app in Finder if they want. Remember
    // the custom ones so the dialog can show them again.
    final remembered = await _macRememberedExts();
    await _macRememberExts({...remembered, ...add}..removeAll(remove));
    _log('file assoc (mac) applied: +$add -$remove failed=$failed');
    if (failed.isEmpty) return null;
    return [for (final e in failed.entries) '.${e.key} (${e.value})'].join(', ');
  }
  if (!Platform.isWindows) return 'unsupported platform';
  try {
    final exe = Platform.resolvedExecutable;
    final failed = <String>[];
    bool check(bool ok, String what) {
      if (!ok) failed.add(what);
      return ok;
    }

    // ProgID (rewritten every apply so a moved exe heals itself).
    const progIdPath = '$_classes\\$assocProgId';
    check(
      regSetString(hkeyCurrentUser, progIdPath, null, 'madedit2 document'),
      'progid',
    );
    check(
      regSetString(
        hkeyCurrentUser,
        '$progIdPath\\shell\\open\\command',
        null,
        '"$exe" "%1"',
      ),
      'command',
    );
    check(
      regSetString(hkeyCurrentUser, '$progIdPath\\DefaultIcon', null, '$exe,0'),
      'icon',
    );

    for (final e in add) {
      check(
        regSetString(
          hkeyCurrentUser,
          '$_classes\\.$e\\OpenWithProgids',
          assocProgId,
          '',
        ),
        '+.$e',
      );
    }
    for (final e in remove) {
      check(
        regDeleteValue(
          hkeyCurrentUser,
          '$_classes\\.$e\\OpenWithProgids',
          assocProgId,
        ),
        '-.$e',
      );
    }

    if (contextMenu == true) {
      check(
        regSetString(hkeyCurrentUser, _ctxKeyPath, null, assocShellLabel),
        'verb',
      );
      check(
        regSetString(hkeyCurrentUser, _ctxKeyPath, 'Icon', '"$exe",0'),
        'verb icon',
      );
      check(
        regSetString(
          hkeyCurrentUser,
          '$_ctxKeyPath\\command',
          null,
          '"$exe" "%1"',
        ),
        'verb command',
      );
    } else if (contextMenu == false) {
      check(regDeleteTree(hkeyCurrentUser, _ctxKeyPath), 'verb removal');
    }

    shChangeNotifyAssoc();
    if (failed.isNotEmpty) {
      _log('file assoc apply partly failed: $failed', warn: true);
      return failed.join(', ');
    }
    _log('file assoc applied: +$add -$remove ctx=$contextMenu');
    return null;
  } catch (e) {
    _log('file assoc apply failed: $e', warn: true);
    return '$e';
  }
}
