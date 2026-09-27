// Linux file associations (Settings → File Associations…), freedesktop style, per user:
//   - ~/.local/share/applications/madedit2.desktop — the launcher entry
//     (Exec = this executable with %F), listing every MIME type we claim;
//     this alone puts madedit2 in the file manager's "Open With" list.
//   - known extensions map to their standard MIME type (table below);
//     unknown ones get a custom `application/x-madedit2-<ext>` type in
//     ~/.local/share/mime/packages/madedit2.xml (glob *.ext) — like the
//     Windows dialog's free-form extensions.
//   - `xdg-mime default madedit2.desktop <mime>` makes us the default for
//     each chosen type (that IS allowed on Linux, unlike Windows).
//   - the icon goes to ~/.local/share/icons/hicolor/256x256/apps/.
// The chosen extensions are remembered in ~/.local/share/madedit2/assoc.json
// so the dialog reopens with them checked.
//
// Pure Dart; the external commands run through an injectable runner so the
// file output is headless-testable (tool/file_assoc_linux_test.dart).

import 'dart:convert';
import 'dart:io';

/// Runs a command; returns (exit code, stdout). Injected for tests.
typedef CommandRunner =
    Future<(int, String)> Function(String exe, List<String> args);

Future<(int, String)> runProcess(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    return (r.exitCode, '${r.stdout}');
  } catch (e) {
    return (-1, '$e');
  }
}

/// Standard MIME types for common text extensions; anything else becomes
/// a custom type.
const Map<String, String> linuxMimeByExt = {
  'txt': 'text/plain',
  'log': 'text/x-log',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'json': 'application/json',
  'xml': 'application/xml',
  'yml': 'application/yaml',
  'yaml': 'application/yaml',
  'ini': 'text/plain',
  'cfg': 'text/plain',
  'conf': 'text/plain',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'sql': 'application/sql',
  'sh': 'application/x-shellscript',
  'bash': 'application/x-shellscript',
  'py': 'text/x-python',
  'js': 'text/javascript',
  'ts': 'text/x-typescript',
  'c': 'text/x-csrc',
  'h': 'text/x-chdr',
  'cpp': 'text/x-c++src',
  'cc': 'text/x-c++src',
  'hpp': 'text/x-c++hdr',
  'cs': 'text/x-csharp',
  'java': 'text/x-java',
  'rs': 'text/rust',
  'go': 'text/x-go',
  'lua': 'text/x-lua',
  'dart': 'application/vnd.dart',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'php': 'application/x-php',
  'rb': 'application/x-ruby',
  'toml': 'application/toml',
  'bat': 'application/x-bat',
  'cmd': 'application/x-bat',
  'ps1': 'application/x-powershell',
};

/// Running inside a Flatpak sandbox? Flatpak drops `/.flatpak-info` into
/// every app's root. Inside, the per-user .desktop/MIME writes below land in
/// the sandbox's private home and never reach the host, and `xdg-mime` is
/// not there — file types come from the manifest's exported .desktop
/// instead, so the dialog disables the OS part. [infoPath] is injectable
/// for tests.
bool isFlatpakSandbox({String infoPath = '/.flatpak-info'}) {
  try {
    return File(infoPath).existsSync();
  } catch (_) {
    return false;
  }
}

String linuxMimeFor(String ext) =>
    linuxMimeByExt[ext] ?? 'application/x-madedit2-$ext';

bool linuxIsCustomMime(String ext) => !linuxMimeByExt.containsKey(ext);

class LinuxAssoc {
  LinuxAssoc({String? dataHome, CommandRunner? run})
    : dataHome = dataHome ?? _defaultDataHome(),
      _run = run ?? runProcess;

  final String dataHome;
  final CommandRunner _run;

  static String _defaultDataHome() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/.local/share';
  }

  String get desktopDir => '$dataHome/applications';
  String get desktopPath => '$desktopDir/madedit2.desktop';
  String get mimeDir => '$dataHome/mime';
  String get mimeXmlPath => '$mimeDir/packages/madedit2.xml';
  String get iconPath => '$dataHome/icons/hicolor/256x256/apps/madedit2.png';
  String get statePath => '$dataHome/madedit2/assoc.json';

  /// Extensions registered by an earlier apply.
  Future<Set<String>> query() async {
    try {
      final f = File(statePath);
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

  /// Register [exts] (the complete new set), writing the desktop entry,
  /// custom MIME types, icon and defaults. Returns an error text or null.
  Future<String?> apply(
    Set<String> exts, {
    required String exe,
    List<int>? iconPng,
  }) async {
    final failed = <String>[];
    try {
      final sorted = exts.toList()..sort();
      final mimes = <String>{for (final e in sorted) linuxMimeFor(e)};
      // Custom MIME types for extensions without a standard one.
      final custom = [
        for (final e in sorted)
          if (linuxIsCustomMime(e)) e,
      ];
      final xml = File(mimeXmlPath);
      if (custom.isNotEmpty) {
        await xml.parent.create(recursive: true);
        await xml.writeAsString(customMimeXml(custom));
      } else if (await xml.exists()) {
        await xml.delete();
      }
      // Icon (best effort).
      if (iconPng != null) {
        try {
          final f = File(iconPath);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(iconPng);
        } catch (_) {}
      }
      // Desktop entry.
      final d = File(desktopPath);
      await d.parent.create(recursive: true);
      await d.writeAsString(desktopEntry(exe: exe, mimes: mimes.toList()));
      // Databases + defaults.
      if (custom.isNotEmpty || await xml.exists()) {
        final (c, out) = await _run('update-mime-database', [mimeDir]);
        if (c != 0) failed.add('update-mime-database: $out');
      }
      final (c2, out2) = await _run('update-desktop-database', [desktopDir]);
      if (c2 != 0) failed.add('update-desktop-database: $out2');
      for (final m in mimes) {
        final (c3, out3) = await _run('xdg-mime', [
          'default',
          'madedit2.desktop',
          m,
        ]);
        if (c3 != 0) failed.add('xdg-mime $m: $out3');
      }
      // Remember.
      final s = File(statePath);
      await s.parent.create(recursive: true);
      await s.writeAsString(jsonEncode({'exts': sorted}));
    } catch (e) {
      return '$e';
    }
    return failed.isEmpty ? null : failed.join('; ');
  }

  /// The .desktop file body.
  static String desktopEntry({
    required String exe,
    required List<String> mimes,
  }) {
    final sorted = mimes.toList()..sort();
    final mimeLine = sorted.isEmpty ? '' : 'MimeType=${sorted.join(';')};\n';
    // Exec: quote the path (spaces), %F = the files to open. Inside the
    // quotes the spec wants backslash-escaped \ " $ ` and a literal % as %%
    // (a path with any of them otherwise broke the launcher's parsing).
    final q = exe
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`')
        .replaceAll('%', '%%');
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=madedit2\n'
        'Comment=Large file text editor\n'
        'Exec="$q" %F\n'
        'Icon=madedit2\n'
        'Terminal=false\n'
        'Categories=Utility;TextEditor;Development;\n'
        '$mimeLine'
        'StartupNotify=true\n';
  }

  /// shared-mime-info package declaring a type per custom extension.
  static String customMimeXml(List<String> exts) {
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">',
      );
    for (final e in exts) {
      sb
        ..writeln('  <mime-type type="${linuxMimeFor(e)}">')
        ..writeln('    <comment>madedit2 document (.$e)</comment>')
        ..writeln('    <sub-class-of type="text/plain"/>')
        ..writeln('    <glob pattern="*.$e"/>')
        ..writeln('  </mime-type>');
    }
    sb.writeln('</mime-info>');
    return sb.toString();
  }
}
