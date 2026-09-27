// Where the external, user-editable `settings/` directory lives.
//
// Split out from config_loader.dart (which pulls in package:flutter for rootBundle) so that
// pure-Dart modules — and the headless tools in tool/ — can resolve settings paths.
//
// Resolution (see [resolveSettingsDir]):
//   1. Portable mode: a `settings/` directory next to the executable wins on
//      every platform (Windows' default; also what `flutter run` / a bare
//      `dart run tool/...` get, since the build dir is writable).
//   2. macOS app bundle: the OS forbids writing into a (code-signed) bundle
//      ("Operation not permitted", errno 1) → `~/Library/Application Support/madedit2/settings`.
//   3. Linux: XDG → `$XDG_CONFIG_HOME/madedit2/settings`, else `~/.config/madedit2/settings`
//      (an AppImage / Flatpak / `/opt` install has a read-only executable dir).
//   4. Otherwise (Windows first run, or no HOME): next to the executable.
//
// In dev (`flutter run`) the exe dir is `build\...\runner\Debug\`, which `flutter clean` wipes.

import 'dart:io';

/// Bundle-relative suffix of a macOS app executable directory.
const _macBundleExeSuffix = '.app/Contents/MacOS';

String? _cachedSettingsDir;

/// Pure resolution (testable): [exeDir] is the executable's directory,
/// [dirExists] answers whether a directory is present.
String resolveSettingsDir({
  required String exeDir,
  required bool isMacOS,
  required bool isLinux,
  required Map<String, String> env,
  required bool Function(String path) dirExists,
  String sep = '/',
}) {
  final beside = '$exeDir${sep}settings';
  if (dirExists(beside)) return beside; // portable mode
  final home = env['HOME'];
  final hasHome = home != null && home.isNotEmpty;
  if (isMacOS && exeDir.endsWith(_macBundleExeSuffix) && hasHome) {
    return '$home/Library/Application Support/madedit2/settings';
  }
  if (isLinux) {
    final xdg = env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return '$xdg/madedit2/settings';
    if (hasHome) return '$home/.config/madedit2/settings';
  }
  return beside;
}

String _resolveSettingsDir() => resolveSettingsDir(
  exeDir: File(Platform.resolvedExecutable).parent.path,
  isMacOS: Platform.isMacOS,
  isLinux: Platform.isLinux,
  env: Platform.environment,
  dirExists: (p) => Directory(p).existsSync(),
  sep: Platform.pathSeparator,
);

/// Absolute path of the external `settings` directory.
String get settingsDir => _cachedSettingsDir ??= _resolveSettingsDir();

/// Override the settings directory (tests only).
set settingsDirOverride(String? dir) => _cachedSettingsDir = dir;

/// Absolute path of a file under the external `settings/` directory ([rel] uses `/` separators).
String settingsPath(String rel) =>
    '$settingsDir${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}';
